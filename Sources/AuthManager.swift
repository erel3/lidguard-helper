import Foundation
import Security

final class AuthManager: Sendable {
  private let teamID = "73R36N2A46"
  private let appIdentifier = "com.akim.lidguard"

  func verifyPeer(fileDescriptor: Int32) -> Bool {
    guard let pid = findPeerPID(fileDescriptor: fileDescriptor) else {
      print("[AuthManager] Failed to find peer PID")
      return false
    }

    let attrs = [kSecGuestAttributePid: pid] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
          let guestCode = code else {
      print("[AuthManager] Failed to get SecCode for PID \(pid)")
      return false
    }

    // Accept Developer ID, TestFlight, or Mac App Store signed builds
    // All require our bundle identifier — no other app can connect
    let requirements = [
      // Developer ID (direct distribution)
      """
      anchor apple generic \
      and certificate leaf[subject.OU] = "\(teamID)" \
      and identifier "\(appIdentifier)"
      """,
      // TestFlight (OID 1.2.840.113635.100.6.1.25.1)
      """
      anchor apple generic \
      and certificate leaf[field.1.2.840.113635.100.6.1.25.1] \
      and identifier "\(appIdentifier)"
      """,
      // Mac App Store (OID 1.2.840.113635.100.6.1.13)
      """
      anchor apple generic \
      and certificate leaf[field.1.2.840.113635.100.6.1.13] \
      and identifier "\(appIdentifier)"
      """
    ]

    for reqString in requirements {
      var requirement: SecRequirement?
      guard SecRequirementCreateWithString(
        reqString as CFString, [], &requirement
      ) == errSecSuccess, let req = requirement else {
        continue
      }
      if SecCodeCheckValidity(guestCode, [], req) == errSecSuccess {
        print("[AuthManager] Peer PID \(pid) verified")
        return true
      }
    }

    print("[AuthManager] Peer PID \(pid) rejected")
    return false
  }

  // MARK: - TCP Peer PID via libproc

  private func findPeerPID(fileDescriptor: Int32) -> pid_t? {
    guard let remotePort = getRemotePort(fileDescriptor: fileDescriptor) else {
      return nil
    }
    return findPIDByLocalPort(remotePort)
  }

  private func getRemotePort(fileDescriptor: Int32) -> UInt16? {
    var peer = sockaddr_in()
    var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &peer) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        getpeername(fileDescriptor, sockPtr, &plen)
      }
    }
    guard result == 0 else { return nil }
    return UInt16(bigEndian: peer.sin_port)
  }

  private func findPIDByLocalPort(_ targetPort: UInt16) -> pid_t? {
    var count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(count))
    count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return nil }

    // Clamp to buffer size: more processes can spawn between the sizing call and
    // the fill call, so the second `count` may exceed the buffer we allocated.
    // Iterating past `pids.count` would be an out-of-bounds read.
    for idx in 0..<min(Int(count), pids.count) {
      let pid = pids[idx]
      guard pid > 0 else { continue }
      if checkProcessOwnsPort(pid: pid, port: targetPort) {
        return pid
      }
    }
    return nil
  }

  private func checkProcessOwnsPort(pid: pid_t, port: UInt16) -> Bool {
    let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bufSize > 0 else { return false }

    let fdCount = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
    var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
    let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, bufSize)
    let realCount = Int(actual) / MemoryLayout<proc_fdinfo>.size

    for idx in 0..<realCount {
      guard fdInfos[idx].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
      if socketMatchesPort(pid: pid, fdNum: fdInfos[idx].proc_fd, port: port) {
        return true
      }
    }
    return false
  }

  private func socketMatchesPort(pid: pid_t, fdNum: Int32, port: UInt16) -> Bool {
    var sinfo = socket_fdinfo()
    let result = proc_pidfdinfo(
      pid, fdNum, PROC_PIDFDSOCKETINFO,
      &sinfo, Int32(MemoryLayout<socket_fdinfo>.size)
    )
    guard result == MemoryLayout<socket_fdinfo>.size,
          sinfo.psi.soi_family == AF_INET,
          sinfo.psi.soi_kind == SOCKINFO_TCP else {
      return false
    }
    let rawPort = sinfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
    let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: rawPort))
    return localPort == port
  }
}
