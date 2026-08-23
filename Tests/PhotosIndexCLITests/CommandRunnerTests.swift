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
}
