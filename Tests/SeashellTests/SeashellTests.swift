import XCTest
import MCP
@testable import Seashell

final class PermissionGuardTests: XCTestCase {
    func testApprovedWithoutReasonIsRejected() {
        let args: [String: MCP.Value] = ["approved": .bool(true)]
        XCTAssertTrue(PermissionGuard.isApproved(args))
        XCTAssertFalse(PermissionGuard.isApprovedWithReason(args))
    }

    func testEmptyReasonIsRejected() {
        let args: [String: MCP.Value] = [
            "approved": .bool(true),
            "reason": .string("   ")
        ]
        XCTAssertFalse(PermissionGuard.isApprovedWithReason(args))
        XCTAssertNil(PermissionGuard.reason(from: args))
    }

    func testApprovedWithReasonIsAccepted() {
        let args: [String: MCP.Value] = [
            "approved": .bool(true),
            "reason": .string("inspect a key")
        ]
        XCTAssertTrue(PermissionGuard.isApprovedWithReason(args))
        XCTAssertEqual(PermissionGuard.reason(from: args), "inspect a key")
    }

    func testSecretReadRequiresExactEnvFlag() {
        let previous = getenv("SEASHELL_ALLOW_SECRET_READ").map { String(cString: $0) }
        defer {
            if let previous {
                setenv("SEASHELL_ALLOW_SECRET_READ", previous, 1)
            } else {
                unsetenv("SEASHELL_ALLOW_SECRET_READ")
            }
        }

        unsetenv("SEASHELL_ALLOW_SECRET_READ")
        XCTAssertFalse(PermissionGuard.allowSecretRead)

        setenv("SEASHELL_ALLOW_SECRET_READ", "true", 1)
        XCTAssertFalse(PermissionGuard.allowSecretRead)

        setenv("SEASHELL_ALLOW_SECRET_READ", "1", 1)
        XCTAssertTrue(PermissionGuard.allowSecretRead)
    }
}
