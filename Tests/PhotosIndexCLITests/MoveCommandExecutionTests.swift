import Darwin
import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import XCTest
@testable import PhotosIndexCLI

final class MoveCommandExecutionTests: XCTestCase {
    func testMovePlanWritesCanonicalMovePlan() throws {
        let socketPath = "/tmp/photosindex-move-plan-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: socketPath)
        let root = temporaryDirectory("plan")
        defer { try? FileManager.default.removeItem(at: root) }
        let decisionURL = root.appendingPathComponent("decision.json")
        let outputURL = root.appendingPathComponent("move-plan.json")
        let decision = try makeDecision()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CanonicalJSON.encode(decision).write(to: decisionURL)
        let movePlan = makeMovePlan(root: root)
        let envelope = MovePlanEnvelope(
            plan: movePlan,
            digest: try MovePlanIntegrity.sha256(movePlan)
        )
        try host.start { request in
            XCTAssertEqual(request.method, "move.plan")
            XCTAssertEqual(request.arguments["decision"], decisionURL.standardizedFileURL.path)
            return try! .success(id: request.id, payload: envelope)
        }
        defer { host.stop() }
        try withSocketPath(socketPath) {
            var command = MovePlanCommand()
            command.decision = decisionURL.path
            command.to = root.appendingPathComponent("Naver Clip").path
            command.output = outputURL.path
            command.layout = "dated-group"
            command.format = "json"
            try command.run()
        }

        let written = try CanonicalJSON.decode(MovePlan.self, from: Data(contentsOf: outputURL))
        XCTAssertEqual(written, movePlan)
        XCTAssertEqual(try MovePlanIntegrity.sha256(written), envelope.digest)
    }

    func testMoveApplySendsCanonicalPlanPathAndLowercaseDigest() throws {
        let socketPath = "/tmp/photosindex-move-apply-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: socketPath)
        let root = temporaryDirectory("apply")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let movePlan = makeMovePlan(root: root)
        let planURL = root.appendingPathComponent("move-plan.json")
        try CanonicalJSON.encode(movePlan).write(to: planURL)
        let digest = try MovePlanIntegrity.sha256(movePlan)
        let exportReceipt = ExportReceipt(
            indexRunID: movePlan.exportPlan.indexRunID,
            groupID: movePlan.exportPlan.groupID,
            generatedAt: movePlan.exportPlan.generatedAt,
            destinationRoot: movePlan.exportPlan.destinationRoot,
            stagingRoot: movePlan.exportPlan.stagingRoot,
            entries: [
                ExportReceiptEntry(
                    assetID: "ast_cli_asset",
                    safeFilename: "IMG_2001.JPG",
                    mediaKind: .photo,
                    bytes: 5,
                    sha256: String(repeating: "a", count: 64),
                    relativePath: "originals/IMG_2001.JPG",
                    reused: false
                )
            ],
            warnings: []
        )
        let receipt = MoveReceipt(
            exportReceipt: exportReceipt,
            deletedAssetIDs: ["ast_cli_asset"],
            completedAt: Date(timeIntervalSince1970: 2),
            warnings: []
        )
        try host.start { request in
            XCTAssertEqual(request.method, "move.apply")
            XCTAssertEqual(request.arguments["plan"], planURL.standardizedFileURL.path)
            XCTAssertEqual(request.arguments["digest"], digest)
            return try! .success(id: request.id, payload: receipt)
        }
        defer { host.stop() }
        try withSocketPath(socketPath) {
            var command = MoveApplyCommand()
            command.plan = planURL.path
            command.digest = digest.uppercased()
            command.format = "json"
            try command.run()
        }
    }

    private func makeDecision() throws -> ModelDecision {
        try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_test",
            groupID: "segment_test",
            label: "move-test",
            confidence: 0.95,
            includedAssetIDs: ["ast_cli_asset"],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
    }

    private func makeMovePlan(root: URL) -> MovePlan {
        MovePlan(
            exportPlan: ExportPlan(
                indexRunID: "run_test",
                groupID: "segment_test",
                generatedAt: Date(timeIntervalSince1970: 1),
                destinationRoot: root.appendingPathComponent("Naver Clip/2026-01-15_move-test").path,
                stagingRoot: root.appendingPathComponent("staging").path,
                groupAssetIDs: ["ast_cli_asset"],
                includedAssetIDs: ["ast_cli_asset"],
                excludedAssetIDs: [],
                label: "move-test",
                confidence: 0.95,
                warnings: []
            ),
            operation: .deleteSourceAfterVerifiedUpload
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexMoveCLITests-\(name)-\(UUID().uuidString)")
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
