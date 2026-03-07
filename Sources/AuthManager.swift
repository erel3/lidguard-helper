import Foundation

final class AuthManager {
  private let secretPath: String
  private(set) var secret: String

  init() {
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LidGuard")
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

    let path = support.appendingPathComponent(".ipc-secret").path
    self.secretPath = path

    if let existing = try? String(contentsOfFile: path, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !existing.isEmpty {
      self.secret = existing
    } else {
      let newSecret = UUID().uuidString
      try? newSecret.write(toFile: path, atomically: true, encoding: .utf8)
      chmod(path, 0o600)
      self.secret = newSecret
      print("[AuthManager] Generated new shared secret")
    }
  }

  func verify(_ candidate: String) -> Bool {
    candidate == secret
  }
}
