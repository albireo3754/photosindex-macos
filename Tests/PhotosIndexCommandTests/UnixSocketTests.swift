import Foundation
import XCTest
@testable import PhotosIndexCommand

final class UnixSocketTests: XCTestCase {
    func testStatusRoundTripOverRealUnixSocket() throws {
        let path = "/tmp/photosindex-test-\(UUID().uuidString).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            XCTAssertEqual(request.method, "status")
            return try! CommandResponse.success(
                id: request.id,
                payload: StatusPayload(
                    appVersion: "0.1.0",
                    protocolVersion: CommandProtocol.currentVersion,
                    permission: "authorized"
                )
            )
        }
        defer { host.stop() }

        let response = try UnixCommandClient(path: path).send(
            CommandRequest(method: "status")
        )
        let status = try response.decodePayload(StatusPayload.self)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(status.appVersion, "0.1.0")
        XCTAssertEqual(status.permission, "authorized")
    }

    func testHostRefusesSymlinkAtSocketPath() throws {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("pi-link-\(UUID().uuidString.prefix(8))")
        let target = base.appendingPathComponent("target")
        let link = base.appendingPathComponent("socket")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: base) }

        let host = UnixCommandHost(path: link.path)

        XCTAssertThrowsError(try host.start { _ in
            try! CommandResponse.success(id: "unused", payload: StatusPayload(appVersion: "0", protocolVersion: 1, permission: "unknown"))
        }) { error in
            XCTAssertEqual(error as? UnixSocketError, .unsafeExistingPath)
        }
    }

    func testSocketPermissionsAreOwnerOnly() throws {
        let path = "/tmp/photosindex-test-\(UUID().uuidString).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            try! CommandResponse.success(id: request.id, payload: StatusPayload(appVersion: "0.1", protocolVersion: 1, permission: "unknown"))
        }
        defer { host.stop() }

        var info = stat()
        XCTAssertEqual(lstat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testSecondHostCannotStealActiveOwnerSocket() throws {
        let path = "/tmp/pi-active-\(UUID().uuidString.prefix(8)).sock"
        let first = UnixCommandHost(path: path)
        try first.start { request in
            try! .success(
                id: request.id,
                payload: StatusPayload(appVersion: "first", protocolVersion: 1, permission: "authorized")
            )
        }
        defer { first.stop() }

        let second = UnixCommandHost(path: path)
        XCTAssertThrowsError(
            try second.start { request in
                try! .success(
                    id: request.id,
                    payload: StatusPayload(appVersion: "second", protocolVersion: 1, permission: "authorized")
                )
            }
        ) { error in
            XCTAssertEqual(error as? UnixSocketError, .socketAlreadyActive)
        }

        let response = try UnixCommandClient(path: path).send(CommandRequest(method: "status"))
        XCTAssertEqual(try response.decodePayload(StatusPayload.self).appVersion, "first")
    }

    func testBlockedCommandDoesNotBlockIndependentStatusClient() throws {
        let path = "/tmp/pi-concurrent-\(UUID().uuidString.prefix(8)).sock"
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let host = UnixCommandHost(path: path)
        try host.start { request in
            if request.method == "block" {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            return try! .success(
                id: request.id,
                payload: StatusPayload(appVersion: request.method, protocolVersion: 1, permission: "authorized")
            )
        }
        defer {
            release.signal()
            host.stop()
        }

        let blockedFinished = expectation(description: "blocked request finishes")
        DispatchQueue.global().async {
            _ = try? UnixCommandClient(path: path).send(CommandRequest(method: "block"))
            blockedFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        let started = Date()
        let status = try UnixCommandClient(path: path).send(CommandRequest(method: "status"))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(try status.decodePayload(StatusPayload.self).appVersion, "status")
        XCTAssertLessThan(elapsed, 0.25)

        release.signal()
        wait(for: [blockedFinished], timeout: 1)
    }

    func testClientReceiveHasDeadline() throws {
        let path = "/tmp/pi-timeout-\(UUID().uuidString.prefix(8)).sock"
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let host = UnixCommandHost(path: path)
        try host.start { request in
            entered.signal()
            release.wait()
            return try! .success(
                id: request.id,
                payload: StatusPayload(appVersion: "late", protocolVersion: 1, permission: "authorized")
            )
        }
        defer {
            release.signal()
            host.stop()
        }

        let started = Date()
        XCTAssertThrowsError(
            try UnixCommandClient(
                path: path,
                receiveTimeout: 0.05,
                sendTimeout: 0.05
            ).send(CommandRequest(method: "status"))
        )
        XCTAssertEqual(entered.wait(timeout: .now()), .success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
