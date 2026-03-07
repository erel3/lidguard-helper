import Foundation

// MARK: - Incoming Commands (App → Daemon)

struct IPCCommand: Codable {
  let type: String
  var secret: String?
  var contactName: String?
  var contactPhone: String?
  var message: String?
}

// MARK: - Outgoing Messages (Daemon → App)

struct IPCMessage: Codable {
  let type: String
  var success: Bool?
  var pmset: Bool?
  var lockScreen: Bool?
  var powerButton: Bool?
  var message: String?

  static func authResult(_ success: Bool) -> IPCMessage {
    IPCMessage(type: "auth_result", success: success)
  }

  static func status(pmset: Bool, lockScreen: Bool, powerButton: Bool) -> IPCMessage {
    IPCMessage(type: "status", pmset: pmset, lockScreen: lockScreen, powerButton: powerButton)
  }

  static func powerButtonPressed() -> IPCMessage {
    IPCMessage(type: "power_button_pressed")
  }

  static func error(_ msg: String) -> IPCMessage {
    IPCMessage(type: "error", message: msg)
  }
}
