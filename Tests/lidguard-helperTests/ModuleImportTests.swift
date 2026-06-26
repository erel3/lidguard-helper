import XCTest
@testable import lidguard_helper

/// Verifies the helper's SwiftPM test target builds and can `@testable import` the
/// executable module. If this fails to compile/link, the test target is broken and must
/// be fixed before any helper feature tests are written.
final class ModuleImportTests: XCTestCase {
  func testModuleIsImportable() {
    XCTAssertTrue(true)
  }
}
