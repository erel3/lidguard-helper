import XCTest
@testable import lidguard_helper

/// Tests Codable round-trips for IPCCommand / IPCMessage, and verifies that each
/// IPCMessage factory method produces the expected type and fields.
/// AuthManager is not tested here: all its logic requires live sockets and process
/// inspection via libproc, which is not unit-testable.
final class IPCProtocolTests: XCTestCase {
  // MARK: - IPCCommand Codable

  func testIPCCommandRoundTripMinimal() throws {
    let cmd = IPCCommand(type: "ping", contactName: nil, contactPhone: nil, message: nil)
    let decoded = try roundTrip(cmd)
    XCTAssertEqual(decoded.type, "ping")
    XCTAssertNil(decoded.contactName)
    XCTAssertNil(decoded.contactPhone)
    XCTAssertNil(decoded.message)
  }

  func testIPCCommandRoundTripFull() throws {
    let cmd = IPCCommand(type: "alert", contactName: "Alice",
                         contactPhone: "+1-555-0100", message: "SOS")
    let decoded = try roundTrip(cmd)
    XCTAssertEqual(decoded.type, "alert")
    XCTAssertEqual(decoded.contactName, "Alice")
    XCTAssertEqual(decoded.contactPhone, "+1-555-0100")
    XCTAssertEqual(decoded.message, "SOS")
  }

  func testIPCCommandTypeIsPreservedThroughJSON() throws {
    let types = ["enable_pmset", "disable_pmset", "lock_screen", "unlock_screen",
                 "status", "power_button_enable"]
    for type in types {
      let cmd = IPCCommand(type: type, contactName: nil, contactPhone: nil, message: nil)
      let decoded = try roundTrip(cmd)
      XCTAssertEqual(decoded.type, type, "Type '\(type)' not preserved through JSON")
    }
  }

  // MARK: - IPCMessage Codable

  func testIPCMessageRoundTripPowerButtonPressed() throws {
    let msg = IPCMessage.powerButtonPressed()
    let decoded = try roundTrip(msg)
    XCTAssertEqual(decoded.type, "power_button_pressed")
    XCTAssertNil(decoded.success)
    XCTAssertNil(decoded.version)
    XCTAssertNil(decoded.message)
  }

  func testIPCMessageRoundTripAuthResult() throws {
    let msg = IPCMessage.authResult(true, version: "1.2.3")
    let decoded = try roundTrip(msg)
    XCTAssertEqual(decoded.type, "auth_result")
    XCTAssertEqual(decoded.success, true)
    XCTAssertEqual(decoded.version, "1.2.3")
  }

  func testIPCMessageRoundTripStatus() throws {
    let msg = IPCMessage.status(
      pmset: true, lockScreen: false, powerButton: true,
      accessibilityGranted: true, motion: false, motionSupported: true,
      motionSession: 42
    )
    let decoded = try roundTrip(msg)
    XCTAssertEqual(decoded.type, "status")
    XCTAssertEqual(decoded.pmset, true)
    XCTAssertEqual(decoded.lockScreen, false)
    XCTAssertEqual(decoded.powerButton, true)
    XCTAssertEqual(decoded.accessibilityGranted, true)
    XCTAssertEqual(decoded.motion, false)
    XCTAssertEqual(decoded.motionSupported, true)
    XCTAssertEqual(decoded.motionSession, 42)
  }

  func testIPCMessageRoundTripMotionDetected() throws {
    let msg = IPCMessage.motionDetected(detail: "shake", session: 7)
    let decoded = try roundTrip(msg)
    XCTAssertEqual(decoded.type, "motion_detected")
    XCTAssertEqual(decoded.motionDetail, "shake")
    XCTAssertEqual(decoded.motionSession, 7)
  }

  func testIPCMessageRoundTripError() throws {
    let msg = IPCMessage.error("Connection timed out")
    let decoded = try roundTrip(msg)
    XCTAssertEqual(decoded.type, "error")
    XCTAssertEqual(decoded.message, "Connection timed out")
  }

  // MARK: - Factory methods: field correctness

  func testAuthResultSuccessTrue() {
    let msg = IPCMessage.authResult(true, version: "2.0.0")
    XCTAssertEqual(msg.type, "auth_result")
    XCTAssertEqual(msg.success, true)
    XCTAssertEqual(msg.version, "2.0.0")
  }

  func testAuthResultSuccessFalseVersionNil() {
    let msg = IPCMessage.authResult(false)
    XCTAssertEqual(msg.type, "auth_result")
    XCTAssertEqual(msg.success, false)
    XCTAssertNil(msg.version)
  }

  func testStatusFactoryAllFields() {
    let msg = IPCMessage.status(
      pmset: false, lockScreen: true, powerButton: false,
      accessibilityGranted: false, motion: true, motionSupported: false,
      motionSession: 99
    )
    XCTAssertEqual(msg.type, "status")
    XCTAssertEqual(msg.pmset, false)
    XCTAssertEqual(msg.lockScreen, true)
    XCTAssertEqual(msg.powerButton, false)
    XCTAssertEqual(msg.accessibilityGranted, false)
    XCTAssertEqual(msg.motion, true)
    XCTAssertEqual(msg.motionSupported, false)
    XCTAssertEqual(msg.motionSession, 99)
  }

  func testPowerButtonPressedType() {
    XCTAssertEqual(IPCMessage.powerButtonPressed().type, "power_button_pressed")
  }

  func testMotionDetectedFieldsSet() {
    let msg = IPCMessage.motionDetected(detail: "tilt", session: 123)
    XCTAssertEqual(msg.type, "motion_detected")
    XCTAssertEqual(msg.motionDetail, "tilt")
    XCTAssertEqual(msg.motionSession, 123)
  }

  func testErrorFactoryMessageField() {
    let msg = IPCMessage.error("auth failed")
    XCTAssertEqual(msg.type, "error")
    XCTAssertEqual(msg.message, "auth failed")
  }

  // MARK: - Helpers

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
  }
}
