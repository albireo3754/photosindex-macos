import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import XCTest
@testable import PhotosIndexCLI

final class AppConnectionTests: XCTestCase {
    func testLongRunningOperationsUseFourHourReceiveTimeout() {
        XCTAssertEqual(AppConnection.longRunningReceiveTimeout, 4 * 60 * 60)
    }

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

    func testDoesNotResubmitAfterAConnectedRequestTimesOut() throws {
        let path = "/tmp/photosindex-no-resubmit-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        let requestCount = LockedCounter()
        try host.start { request in
            requestCount.increment()
            Thread.sleep(forTimeInterval: 0.2)
            return try! .success(id: request.id, payload: AuthorizationPayload(permission: "authorized"))
        }
        defer { host.stop() }

        XCTAssertThrowsError(
            try AppConnection(
                environment: ["PHOTOSINDEX_SOCKET_PATH": path],
                receiveTimeout: 0.05
            ).run(CommandRequest(method: "authorize"), as: AuthorizationPayload.self)
        )
        Thread.sleep(forTimeInterval: 0.25)
        XCTAssertEqual(requestCount.value, 1)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
