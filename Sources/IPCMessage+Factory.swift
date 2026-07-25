import Foundation

/// Helper-side conveniences for constructing outgoing `IPCMessage`s.
/// The wire shape itself lives in `IPCProtocol.swift` (kept in sync with the
/// app repo); these factories are helper-only and not part of the contract.
extension IPCMessage {
  static func authResult(_ success: Bool, version: String? = nil) -> IPCMessage {
    IPCMessage(type: "auth_result", success: success, version: version)
  }

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
