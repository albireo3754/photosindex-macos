import Foundation
import XCTest
import PhotosIndexCommand
@testable import PhotosIndexCLI

final class StatusRunnerTests: XCTestCase {
    func testRunnerReturnsCanonicalStatusPayload() throws {
        let path = "/tmp/photosindex-cli-test-\(UUID().uuidString).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            try! CommandResponse.success(
                id: request.id,
                payload: StatusPayload(appVersion: "0.1.0", protocolVersion: 1, permission: "authorized")
            )
        }
        defer { host.stop() }

        let data = try StatusRunner(client: UnixCommandClient(path: path)).run()
        let status = try JSONDecoder().decode(StatusPayload.self, from: data)

        XCTAssertEqual(status.permission, "authorized")
        XCTAssertEqual(status.protocolVersion, 1)
    }
}
