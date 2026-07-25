import Foundation

final class PmsetManager: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.lidguard.helper.pmset")
  private let lock = NSLock()
  private var _isEnabled = false
  var isEnabled: Bool {
    lock.lock(); defer { lock.unlock() }
    return _isEnabled
  }

  func enable() {
    queue.async { [self] in
      let success = runProcess("/usr/bin/sudo", arguments: ["pmset", "-a", "disablesleep", "1"])
      if success {
        lock.lock(); _isEnabled = true; lock.unlock()
      }
      print("[PmsetManager] Enable disablesleep: \(success ? "OK" : "FAILED")")
    }
  }

  func disable() {
    queue.async { [self] in _ = performDisable() }
  }

  /// Synchronous variant for teardown paths that call `exit(0)` straight after.
  ///
  /// `disable()` only *enqueues* onto `queue`; `exit(0)` on main tears the process
  /// down long before that block can spawn `/usr/bin/sudo`, so `disablesleep`
  /// stays at 1 — and it is a persistent system setting, not process state. The
  /// Mac then never sleeps on lid close: the user shuts the laptop, puts it in a
  /// bag, and it runs hot until the battery is flat. Both the idle-timeout and
  /// SIGTERM paths in main.swift hit this.
  ///
  /// `queue.sync` also serialises correctly behind an in-flight `enable()`.
  @discardableResult
  func disableSync() -> Bool {
    queue.sync { performDisable() }
  }

  private func performDisable() -> Bool {
    let success = runProcess("/usr/bin/sudo", arguments: ["pmset", "-a", "disablesleep", "0"])
    if success {
      lock.lock(); _isEnabled = false; lock.unlock()
    }
    print("[PmsetManager] Disable disablesleep: \(success ? "OK" : "FAILED")")
    return success
  }

  private func runProcess(_ path: String, arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // Null stdin so a missing sudoers entry makes sudo fail fast instead of
    // blocking on a password prompt it can never satisfy. That matters most for
    // disableSync(), which runs on main during shutdown — a prompt there would
    // hang logout rather than just failing.
    process.standardInput = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      print("[PmsetManager] Process error: \(error)")
      return false
    }
  }
}
