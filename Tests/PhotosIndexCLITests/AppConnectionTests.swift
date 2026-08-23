import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import XCTest
@testable import PhotosIndexCLI

final class AppConnectionTests: XCTestCase {
    func testEnvironmentAppPathTakesPriority() {
        let connection = AppConnection(
            environment: ["PHOTOSINDEX_APP_PATH": "/tmp/TestPhotosIndex.app"]
        )

        XCTAssertEqual(connection.resolveAppPath(), "/tmp/TestPhotosIndex.app")
    }

    func testPreservesCommandFailureInsteadOfReportingLaunchFailure() throws {
        let path = "/tmp/photosindex-error-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            .failure(
                id: request.id,
                error: CommandFailure(
                    code: "photos-permission-required",
                    message: "Photos access is required before indexing."
                )
            )
        }
        defer { host.stop() }

        XCTAssertThrowsError(
            try AppConnection(environment: ["PHOTOSINDEX_SOCKET_PATH": path]).run(
                CommandRequest(method: "sync", arguments: ["date": "2026-01-15"]),
                as: AuthorizationPayload.self
            )
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "Photos access is required before indexing."
            )
        }
    }
}
