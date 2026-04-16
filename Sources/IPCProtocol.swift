import Foundation

// MARK: - Incoming Commands (App → Daemon)

struct IPCCommand: Codable {
  let type: String
  var contactName: String?
  var contactPhone: String?
  var message: String?
}

// MARK: - Outgoing Messages (Daemon → App)

struct IPCMessage: Codable {
  let type: String
  var success: Bool?
  var version: String?
  var pmset: Bool?
  var lockScreen: Bool?
  var powerButton: Bool?
  var accessibilityGranted: Bool?
  var motion: Bool?
  var motionSupported: Bool?
  var motionDetail: String?
  var motionSession: UInt64?
  var message: String?

  static func authResult(_ success: Bool, version: String? = nil) -> IPCMessage {
    IPCMessage(type: "auth_result", success: success, version: version)
  }

  // swiftlint:disable:next function_parameter_count
  static func status(
    pmset: Bool, lockScreen: Bool, powerButton: Bool, accessibilityGranted: Bool,
    motion: Bool, motionSupported: Bool, motionSession: UInt64
  ) -> IPCMessage {
    IPCMessage(
      type: "status", pmset: pmset, lockScreen: lockScreen,
      powerButton: powerButton, accessibilityGranted: accessibilityGranted,
      motion: motion, motionSupported: motionSupported, motionSession: motionSession
    )
  }

  static func powerButtonPressed() -> IPCMessage {
    IPCMessage(type: "power_button_pressed")
  }

  static func motionDetected(detail: String, session: UInt64) -> IPCMessage {
    IPCMessage(type: "motion_detected", motionDetail: detail, motionSession: session)
  }

  static func error(_ msg: String) -> IPCMessage {
    IPCMessage(type: "error", message: msg)
  }
}
