import ApplicationServices
import Darwin
import Foundation

final class TCPServer {
  private var listenSource: DispatchSourceRead?
  private var connections: [Int32: ClientConnection] = [:]
  private let queue = DispatchQueue(label: "com.lidguard.helper.tcp")

  private let authManager: AuthManager
  private let pmsetManager: PmsetManager
  private let lockScreenManager: LockScreenManager
  private let powerButtonMonitor: PowerButtonMonitor
  private let version: String

  var activeConnections: Int { connections.count }

  init(
    authManager: AuthManager,
    pmsetManager: PmsetManager,
    lockScreenManager: LockScreenManager,
    powerButtonMonitor: PowerButtonMonitor,
    version: String
  ) {
    self.authManager = authManager
    self.pmsetManager = pmsetManager
    self.lockScreenManager = lockScreenManager
    self.powerButtonMonitor = powerButtonMonitor
    self.version = version
  }

  func start(existingFD: Int32?) {
    let listenFD: Int32
    if let existing = existingFD {
      listenFD = existing
      print("[TCPServer] Using launchd socket FD \(existing)")
    } else {
      listenFD = bindSocket(port: 51423)
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
  }

  func broadcast(_ message: IPCMessage) {
    queue.async { [self] in
      for (clientFD, conn) in connections where conn.authenticated {
        send(message, to: clientFD)
      }
    }
  }

  // MARK: - Socket Setup

  private func bindSocket(port: UInt16) -> Int32 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      fatalError("[TCPServer] Failed to create socket")
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
      fatalError("[TCPServer] Failed to bind port \(port): \(String(cString: strerror(errno)))")
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
    guard bytesRead > 0 else {
      removeConnection(fileDescriptor)
      return
    }

    connections[fileDescriptor]?.buffer.append(contentsOf: buf[0..<bytesRead])
    processLines(fileDescriptor: fileDescriptor)
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
    _ = Darwin.write(fileDescriptor, bytes, bytes.count)
  }

  // MARK: - Command Dispatch

  private func handleMessage(_ json: String, fileDescriptor: Int32) {
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

  private func dispatchMainThreadCommand(_ cmd: IPCCommand, fileDescriptor: Int32) {
    switch cmd.type {
    case "lock_screen":
      lockSystemScreen()
    case "show_lock_screen":
      let name = cmd.contactName ?? ""
      let phone = cmd.contactPhone ?? ""
      let msg = cmd.message ?? "STOLEN DEVICE"
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [self] in
        lockScreenManager.show(contactName: name, contactPhone: phone, message: msg)
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    case "hide_lock_screen":
      runOnMain { [self] in lockScreenManager.hide() }
    case "enable_power_button":
      runOnMain { [self] in powerButtonMonitor.start() }
    case "disable_power_button":
      runOnMain { [self] in powerButtonMonitor.stop() }
    default:
      send(.error("Unknown command: \(cmd.type)"), to: fileDescriptor)
      return
    }
    sendStatus(to: fileDescriptor)
  }

  private func runOnMain(_ block: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
    CFRunLoopWakeUp(CFRunLoopGetMain())
  }

  private func lockSystemScreen() {
    let libHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
    guard libHandle != nil else { return }
    guard let sym = dlsym(libHandle, "SACLockScreenImmediate") else { return }
    typealias LockFunction = @convention(c) () -> Void
    let lock = unsafeBitCast(sym, to: LockFunction.self)
    lock()
  }

  private func sendStatus(to fileDescriptor: Int32) {
    let status = IPCMessage.status(
      pmset: pmsetManager.isEnabled,
      lockScreen: lockScreenManager.isShowing,
      powerButton: powerButtonMonitor.isMonitoring,
      accessibilityGranted: AXIsProcessTrusted()
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
