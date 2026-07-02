import Foundation
import Security

final class AuthManager: Sendable {
  private let teamID = "73R36N2A46"
  private let appIdentifier = "com.akim.lidguard"
  /// Our listen port. A peer socket is only accepted if its *foreign* endpoint
  /// is exactly 127.0.0.1:<listenPort> — see `socketMatchesConnection`.
  private let listenPort: UInt16 = 51423
  private let loopbackAddr: in_addr_t = inet_addr("127.0.0.1")

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
    guard let peerPort = getRemotePort(fileDescriptor: fileDescriptor) else {
      return nil
    }
    return findPIDForPeer(peerPort: peerPort)
  }

  private func getRemotePort(fileDescriptor: Int32) -> UInt16? {
    var peer = sockaddr_in()
    var plen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &peer) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        getpeername(fileDescriptor, sockPtr, &plen)
      }
    }
    // Require the peer to actually be on loopback; getpeername gives us the
    // remote (ephemeral) port that identifies the client's side of *this*
    // connection.
    guard result == 0, peer.sin_addr.s_addr == loopbackAddr else { return nil }
    return UInt16(bigEndian: peer.sin_port)
  }

  /// Find the process that owns the peer end of our accepted connection.
  ///
  /// The peer socket is pinned by its full 4-tuple — local port == `peerPort`
  /// AND foreign endpoint == 127.0.0.1:`listenPort` — not by local port alone.
  /// The kernel guarantees 4-tuple uniqueness for established connections, so
  /// exactly one process matches: the real peer. This closes the prior bypass
  /// where a same-user process could `bind()` a colliding *local* port and be
  /// mis-attributed as the signed app.
  private func findPIDForPeer(peerPort: UInt16) -> pid_t? {
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
      if processOwnsConnection(pid: pid, peerPort: peerPort) {
        return pid
      }
    }
    return nil
  }

  private func processOwnsConnection(pid: pid_t, peerPort: UInt16) -> Bool {
    let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bufSize > 0 else { return false }

    let fdCount = Int(bufSize) / MemoryLayout<proc_fdinfo>.size
    var fdInfos = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
    let actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fdInfos, bufSize)
    let realCount = Int(actual) / MemoryLayout<proc_fdinfo>.size

    for idx in 0..<realCount {
      guard fdInfos[idx].proc_fdtype == PROX_FDTYPE_SOCKET else { continue }
      if socketMatchesConnection(pid: pid, fdNum: fdInfos[idx].proc_fd, peerPort: peerPort) {
        return true
      }
    }
    return false
  }

  /// True only if this fd is the peer's TCP socket for *our* connection:
  /// local port == `peerPort`, foreign endpoint == 127.0.0.1:`listenPort`.
  private func socketMatchesConnection(pid: pid_t, fdNum: Int32, peerPort: UInt16) -> Bool {
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
    let tcp = sinfo.psi.soi_proto.pri_tcp.tcpsi_ini
    let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_lport))
    let foreignPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.insi_fport))
    let localAddr = tcp.insi_laddr.ina_46.i46a_addr4.s_addr
    let foreignAddr = tcp.insi_faddr.ina_46.i46a_addr4.s_addr
    return localPort == peerPort
      && foreignPort == listenPort
      && localAddr == loopbackAddr
      && foreignAddr == loopbackAddr
  }
}
