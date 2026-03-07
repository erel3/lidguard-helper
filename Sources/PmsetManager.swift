import Foundation

final class PmsetManager {
  private let queue = DispatchQueue(label: "com.lidguard.helper.pmset")
  private(set) var isEnabled = false

  func enable() {
    queue.async { [self] in
      let success = runProcess("/usr/bin/sudo", arguments: ["pmset", "-a", "disablesleep", "1"])
      if success { isEnabled = true }
      print("[PmsetManager] Enable disablesleep: \(success ? "OK" : "FAILED")")
    }
  }

  func disable() {
    queue.async { [self] in
      let success = runProcess("/usr/bin/sudo", arguments: ["pmset", "-a", "disablesleep", "0"])
      if success { isEnabled = false }
      print("[PmsetManager] Disable disablesleep: \(success ? "OK" : "FAILED")")
    }
  }

  private func runProcess(_ path: String, arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
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
