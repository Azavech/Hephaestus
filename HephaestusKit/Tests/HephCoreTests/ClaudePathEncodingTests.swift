import Foundation
import XCTest
@testable import HephCore

final class ClaudePathEncodingTests: XCTestCase {
    func testVectors() {
        // The table of docs/devices/migration.md, "Claude folder names".
        let longPath = "/Users/user/Developer/clients/acme-corporation/platform-modernization-initiative/backend-services/"
            + "payment-processing-gateway/integration-tests/fixtures/sandbox-environment/regional-deployments/europe-west"
        XCTAssertEqual(longPath.count, 204)
        let vectors: [(path: String, folderName: String)] = [
            ("/Users/user/Developer/Atlas/sample-service", "-Users-user-Developer-Atlas-sample-service"),
            ("/private/tmp/claude-501/-Users-user-Developer/x/cli1", "-private-tmp-claude-501--Users-user-Developer-x-cli1"),
            ("/Users/user/Developer/Caf\u{E9} Projet", "-Users-user-Developer-Caf--Projet"),
            ("/Users/user/Developer/\u{1F680} Rocket", "-Users-user-Developer----Rocket"),
            (longPath, "-Users-user-Developer-clients-acme-corporation-platform-modernization-initiative-backend-services-"
                + "payment-processing-gateway-integration-tests-fixtures-sandbox-environment-regional-deployments-europe--"
                + "q52z38"),
        ]
        for vector in vectors {
            XCTAssertEqual(ClaudePathEncoding.folderName(for: vector.path), vector.folderName, vector.path)
        }
    }
}
