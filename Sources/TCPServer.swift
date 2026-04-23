import ApplicationServices
import Darwin
import Foundation

final class TCPServer: @unchecked Sendable {
  // All `nonisolated(unsafe)` fields below are only touched on `queue`.
  nonisolated(unsafe) private var listenSource: DispatchSourceRead?
  nonisolated(unsafe) private var connections: [Int32: ClientConnection] = [:]
  private let queue = DispatchQueue(label: "com.lidguard.helper.tcp")

  private let authManager: AuthManager
  private let pmsetManager: PmsetManager
  private let lockScreenManager: LockScreenManager
  private let powerButtonMonitor: PowerButtonMonitor
  private let motionMonitor: MotionMonitor
  private let version: String

  /// Max bytes buffered per connection before we disconnect a misbehaving peer.
  private static let maxBufferBytes = 256 * 1024

  var activeConnections: Int {
    queue.sync { connections.count }
  }

  init(
    authManager: AuthManager,
    pmsetManager: PmsetManager,
    lockScreenManager: LockScreenManager,
    powerButtonMonitor: PowerButtonMonitor,
    motionMonitor: MotionMonitor,
    version: String
  ) {
    self.authManager = authManager
    self.pmsetManager = pmsetManager
    self.lockScreenManager = lockScreenManager
    self.powerButtonMonitor = powerButtonMonitor
    self.motionMonitor = motionMonitor
    self.version = version
  }

  func start(existingFD: Int32?) -> Bool {
    let listenFD: Int32
    if let existing = existingFD {
      listenFD = existing
      print("[TCPServer] Using launchd socket FD \(existing)")
    } else {
      guard let boundFD = bindSocket(port: 51423) else { return false }
      listenFD = boundFD
      print("[TCPServer] Bound to port 51423")
    }

    let flags = fcntl(listenFD, F_GETFL)
    _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)
    listen(listenFD, 5)

    let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
    source.setEventHandler { [weak self] in
      self?.acceptConnection(listenFD: listenFD)
    }
    source.setCancelHandler {
      close(listenFD)
    }
    source.resume()
    listenSource = source
    return true
  }

  func broadcast(_ message: IPCMessage) {
    queue.async { [self] in
      for (clientFD, conn) in connections where conn.authenticated {
        send(message, to: clientFD)
      }
    }
  }

  // MARK: - Socket Setup

  private func bindSocket(port: UInt16) -> Int32? {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      print("[TCPServer] Failed to create socket: \(String(cString: strerror(errno)))")
      return nil
    }

    var yes: Int32 = 1
    setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      print("[TCPServer] Failed to bind port \(port): \(String(cString: strerror(errno)))")
      close(socketFD)
      return nil
    }
    return socketFD
  }

  // MARK: - Connection Management

  private func acceptConnection(listenFD: Int32) {
    var addr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        accept(listenFD, sockPtr, &len)
      }
    }
    guard clientFD >= 0 else { return }

    let flags = fcntl(clientFD, F_GETFL)
    _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

    let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
    let conn = ClientConnection(fileDescriptor: clientFD, readSource: source)
    connections[clientFD] = conn

    source.setEventHandler { [weak self] in
      self?.readData(fileDescriptor: clientFD)
    }
    source.setCancelHandler { [weak self] in
      close(clientFD)
      self?.connections.removeValue(forKey: clientFD)
      print("[TCPServer] Client disconnected (fd=\(clientFD)), active=\(self?.connections.count ?? 0)")
    }
    source.resume()
    print("[TCPServer] Client connected (fd=\(clientFD)), active=\(connections.count)")
  }

  private func removeConnection(_ fileDescriptor: Int32) {
    connections[fileDescriptor]?.readSource.cancel()
  }

  // MARK: - Reading

  private func readData(fileDescriptor: Int32) {
    var buf = [UInt8](repeating: 0, count: 4096)
    let bytesRead = read(fileDescriptor, &buf, buf.count)
    if bytesRead > 0 {
      guard var conn = connections[fileDescriptor] else { return }
      conn.buffer.append(contentsOf: buf[0..<bytesRead])
      if conn.buffer.count > Self.maxBufferBytes {
        print("[TCPServer] Peer fd=\(fileDescriptor) exceeded buffer limit — disconnecting")
        connections[fileDescriptor] = conn
        removeConnection(fileDescriptor)
        return
      }
      connections[fileDescriptor] = conn
      processLines(fileDescriptor: fileDescriptor)
      return
    }
    if bytesRead == 0 {
      // Peer closed cleanly.
      removeConnection(fileDescriptor)
      return
    }
    // bytesRead < 0: transient errors keep the connection, hard errors drop it.
    switch errno {
    case EAGAIN, EINTR:
      return
    default:
      removeConnection(fileDescriptor)
    }
  }

  private func processLines(fileDescriptor: Int32) {
    guard var conn = connections[fileDescriptor] else { return }
    let newline = UInt8(ascii: "\n")

    while let nlIndex = conn.buffer.firstIndex(of: newline) {
      let lineData = conn.buffer[conn.buffer.startIndex..<nlIndex]
      conn.buffer.removeSubrange(conn.buffer.startIndex...nlIndex)
      connections[fileDescriptor] = conn

      if let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty {
        handleMessage(line, fileDescriptor: fileDescriptor)
      }

      guard let updated = connections[fileDescriptor] else { return }
      conn = updated
    }
    connections[fileDescriptor] = conn
  }

  // MARK: - Sending

  private func send(_ message: IPCMessage, to fileDescriptor: Int32) {
    guard let data = try? JSONEncoder().encode(message),
          var json = String(data: data, encoding: .utf8) else { return }
    json += "\n"
    let bytes = Array(json.utf8)
    writeAll(fileDescriptor: fileDescriptor, bytes: bytes)
  }

  /// Blocking-ish write loop that handles short writes and EAGAIN/EINTR.
  /// On hard failure, cancels the connection.
  private func writeAll(fileDescriptor: Int32, bytes: [UInt8]) {
    var offset = 0
    let total = bytes.count
    while offset < total {
      let remaining = total - offset
      let wrote = bytes.withUnsafeBufferPointer { ptr -> Int in
        guard let base = ptr.baseAddress else { return -1 }
        return Darwin.write(fileDescriptor, base.advanced(by: offset), remaining)
      }
      if wrote > 0 { offset += wrote; continue }
      if wrote < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN {
          var delay = timespec(tv_sec: 0, tv_nsec: 1_000_000)
          _ = nanosleep(&delay, nil)
          continue
        }
        print("[TCPServer] write fd=\(fileDescriptor) failed: \(String(cString: strerror(errno)))")
        removeConnection(fileDescriptor)
        return
      }
      removeConnection(fileDescriptor)
      return
    }
  }

}

// MARK: - Command Dispatch

extension TCPServer {
  fileprivate func handleMessage(_ json: String, fileDescriptor: Int32) {
    guard let data = json.data(using: .utf8),
          let cmd = try? JSONDecoder().decode(IPCCommand.self, from: data) else {
      send(.error("Invalid JSON"), to: fileDescriptor)
      return
    }

    if cmd.type != "auth" && connections[fileDescriptor]?.authenticated != true {
      send(.error("Not authenticated"), to: fileDescriptor)
      return
    }

    switch cmd.type {
    case "auth":
      let success = authManager.verifyPeer(fileDescriptor: fileDescriptor)
      connections[fileDescriptor]?.authenticated = success
      send(.authResult(success, version: success ? version : nil), to: fileDescriptor)
    case "enable_pmset":
      pmsetManager.enable()
      sendStatus(to: fileDescriptor)
    case "disable_pmset":
      pmsetManager.disable()
      sendStatus(to: fileDescriptor)
    case "get_status":
      sendStatus(to: fileDescriptor)
    default:
      dispatchMainThreadCommand(cmd, fileDescriptor: fileDescriptor)
    }
  }

  fileprivate func dispatchMainThreadCommand(_ cmd: IPCCommand, fileDescriptor: Int32) {
    let lockScreenManager = self.lockScreenManager
    let powerButtonMonitor = self.powerButtonMonitor
    let motionMonitor = self.motionMonitor

    // Runs on main, then replies from tcp queue so status reflects post-command state.
    let replyAfter: @MainActor () -> Void
    switch cmd.type {
    case "lock_screen":
      replyAfter = { [weak self] in
        self?.lockSystemScreen()
      }
    case "show_lock_screen":
      let name = cmd.contactName ?? ""
      let phone = cmd.contactPhone ?? ""
      let msg = cmd.message ?? "STOLEN DEVICE"
      replyAfter = { lockScreenManager.show(contactName: name, contactPhone: phone, message: msg) }
    case "hide_lock_screen":
      replyAfter = { lockScreenManager.hide() }
    case "enable_power_button":
      replyAfter = { powerButtonMonitor.start() }
    case "disable_power_button":
      replyAfter = { powerButtonMonitor.stop() }
    case "start_motion_monitoring":
      replyAfter = { _ = motionMonitor.start() }
    case "stop_motion_monitoring":
      replyAfter = { motionMonitor.stop() }
    default:
      send(.error("Unknown command: \(cmd.type)"), to: fileDescriptor)
      return
    }

    runOnMain { [weak self] in
      replyAfter()
      self?.queue.async { [weak self] in
        self?.sendStatus(to: fileDescriptor)
      }
    }
  }

  fileprivate func runOnMain(_ block: @escaping @MainActor () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
      MainActor.assumeIsolated { block() }
    }
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  fileprivate func lockSystemScreen() {
    let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
    guard libHandle != nil else { return }
    guard let sym = dlsym(libHandle, "SACLockScreenImmediate") else { return }
    typealias LockFunction = @convention(c) () -> Void
    let lock = unsafeBitCast(sym, to: LockFunction.self)
    lock()
  }

  fileprivate func sendStatus(to fileDescriptor: Int32) {
    let status = IPCMessage.status(
      pmset: pmsetManager.isEnabled,
      lockScreen: lockScreenManager.isShowing,
      powerButton: powerButtonMonitor.isMonitoring,
      accessibilityGranted: AXIsProcessTrusted(),
      motion: motionMonitor.isMonitoring,
      motionSupported: motionMonitor.isHardwareSupported,
      motionSession: motionMonitor.currentSession
    )
    send(status, to: fileDescriptor)
  }
}

// MARK: - Client Connection

private struct ClientConnection {
  let fileDescriptor: Int32
  let readSource: DispatchSourceRead
  var buffer: Data = Data()
  var authenticated: Bool = false
}
