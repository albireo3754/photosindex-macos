import Darwin
import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import XCTest
@testable import PhotosIndexCLI

final class CommandRunnerTests: XCTestCase {
    func testSyncSendsDateAndReturnsCanonicalPayload() throws {
        let path = "/tmp/photosindex-sync-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            XCTAssertEqual(request.method, "sync")
            XCTAssertEqual(request.arguments["date"], "2026-01-15")
            return try! .success(
                id: request.id,
                payload: IndexSyncPayload(
                    indexRunID: "run_test",
                    localDate: "2026-01-15",
                    assetCount: 60,
                    coarseSessionCount: 4,
                    fineGroupCount: 9
                )
            )
        }
        defer { host.stop() }

        let data = try CommandRunner(client: UnixCommandClient(path: path)).run(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"]),
            as: IndexSyncPayload.self
        )
        let payload = try JSONDecoder().decode(IndexSyncPayload.self, from: data)

        XCTAssertEqual(payload.assetCount, 60)
        XCTAssertEqual(payload.fineGroupCount, 9)
    }

    func testGroupsListSendsLevelAndReturnsGroups() throws {
        let path = "/tmp/photosindex-groups-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            XCTAssertEqual(request.method, "groups.list")
            XCTAssertEqual(request.arguments["level"], "fine")
            return try! .success(
                id: request.id,
                payload: GroupsPayload(indexRunID: "run_test", level: .fine, groups: [])
            )
        }
        defer { host.stop() }

        let data = try CommandRunner(client: UnixCommandClient(path: path)).run(
            CommandRequest(method: "groups.list", arguments: ["level": "fine"]),
            as: GroupsPayload.self
        )
        let payload = try JSONDecoder().decode(GroupsPayload.self, from: data)

        XCTAssertEqual(payload.level, .fine)
        XCTAssertEqual(payload.indexRunID, "run_test")
    }

    func testGroupsListCommandRejectsDowngradedResponse() throws {
        let path = "/tmp/photosindex-groups-mismatch-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        try host.start { request in
            XCTAssertEqual(request.arguments["level"], "media-kind")
            return try! .success(
                id: request.id,
                payload: GroupsPayload(indexRunID: "run_test", level: .fine, groups: [])
            )
        }
        defer { host.stop() }
        let command = try XCTUnwrap(
            try PhotosIndexCommandLine.parseAsRoot([
                "groups", "list", "--level", "media-kind", "--format", "json",
            ]) as? GroupsListCommand
        )

        XCTAssertThrowsError(try withSocketPath(path) {
            var parsedCommand = command
            try parsedCommand.run()
        }) { error in
            XCTAssertTrue(String(describing: error).contains("returned fine groups"))
        }
    }

    func testGroupsListCommandRejectsUnsupportedLevelBeforeSending() throws {
        var command = try XCTUnwrap(
            try PhotosIndexCommandLine.parseAsRoot([
                "groups", "list", "--level", "unsupported",
            ]) as? GroupsListCommand
        )

        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(String(describing: error).contains("Unsupported grouping level"))
        }
    }

    func testGroupsListCommandRejectsMismatchedGroupEntries() throws {
        let path = "/tmp/photosindex-group-entry-mismatch-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: path)
        let mismatchedGroup = CaptureGroup(
            id: "segment_synthetic",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: nil,
            end: nil,
            assetIDs: ["ast_synthetic"],
            warnings: []
        )
        try host.start { request in
            XCTAssertEqual(request.arguments["level"], "media-kind")
            return try! .success(
                id: request.id,
                payload: GroupsPayload(
                    indexRunID: "run_synthetic",
                    level: .mediaKind,
                    groups: [mismatchedGroup]
                )
            )
        }
        defer { host.stop() }
        let command = try XCTUnwrap(
            try PhotosIndexCommandLine.parseAsRoot([
                "groups", "list", "--level", "media-kind", "--format", "json",
            ]) as? GroupsListCommand
        )

        XCTAssertThrowsError(try withSocketPath(path) {
            var parsedCommand = command
            try parsedCommand.run()
        }) { error in
            XCTAssertTrue(String(describing: error).contains("group entries"))
        }
    }

    private func withSocketPath(_ socketPath: String, operation: () throws -> Void) throws {
        let oldSocket = getenv("PHOTOSINDEX_SOCKET_PATH").map { String(cString: $0) }
        setenv("PHOTOSINDEX_SOCKET_PATH", socketPath, 1)
        defer {
            if let oldSocket {
                setenv("PHOTOSINDEX_SOCKET_PATH", oldSocket, 1)
            } else {
                unsetenv("PHOTOSINDEX_SOCKET_PATH")
            }
        }
        try operation()
    }
}
