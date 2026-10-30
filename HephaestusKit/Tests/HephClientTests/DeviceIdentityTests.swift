import Foundation
import XCTest
@testable import HephClient
@testable import HephCore

@MainActor
final class DeviceIdentityTests: XCTestCase {
    func testValidateName() throws {
        XCTAssertEqual(try DeviceIdentityStore.validateName(" Studio \n"), "Studio")
        XCTAssertEqual(try DeviceIdentityStore.validateName("Claude's Mac"), "Claude's Mac")
        for name in ["", "  "] {
            XCTAssertThrowsError(try DeviceIdentityStore.validateName(name)) { error in
                XCTAssertEqual(error as? DataError, .invalid("Enter a device name."))
            }
        }
        for name in ["Claude", "claude", " CLAUDE "] {
            XCTAssertThrowsError(try DeviceIdentityStore.validateName(name)) { error in
                XCTAssertEqual(error as? DataError, .invalid("Claude is a reserved name."))
            }
        }
    }
}
