import Darwin
import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import XCTest
@testable import PhotosIndexCLI

final class ExportCommandExecutionTests: XCTestCase {
    func testExportPlanCommandWritesCanonicalPlanFile() throws {
        let socketPath = "/tmp/photosindex-export-plan-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: socketPath)
        let root = temporaryDirectory("plan")
        let decisionURL = root.appendingPathComponent("decision.json")
        let outputURL = root.appendingPathComponent("plan.json")
        let assetID = "ast_cli_asset"
        let group = makeGroup(assetID: assetID)
        let decision = try makeDecision(assetID: assetID, group: group)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CanonicalJSON.encode(decision).write(to: decisionURL)
        let plan = ExportPlan(
            indexRunID: "run_test",
            groupID: group.id,
            generatedAt: Date(timeIntervalSince1970: 1),
            destinationRoot: root.appendingPathComponent("Naver Clip").path,
            stagingRoot: root.appendingPathComponent("staging").path,
            groupAssetIDs: group.assetIDs,
            includedAssetIDs: [assetID],
            excludedAssetIDs: [],
            label: "음식점-상호미확인",
            confidence: 0.95,
            warnings: []
        )
        let envelope = ExportPlanEnvelope(
            plan: plan,
            digest: try ExportPlanIntegrity.sha256(plan)
        )

        try host.start { request in
            XCTAssertEqual(request.method, "export.plan")
            XCTAssertEqual(request.arguments["decision"], decisionURL.standardizedFileURL.path)
            XCTAssertEqual(request.arguments["to"], root.appendingPathComponent("Naver Clip").standardizedFileURL.path)
            XCTAssertEqual(request.arguments["layout"], "dated-group")
            return try! .success(id: request.id, payload: envelope)
        }
        defer { host.stop() }

        let oldSocket = getenv("PHOTOSINDEX_SOCKET_PATH").map { String(cString: $0) }
        setenv("PHOTOSINDEX_SOCKET_PATH", socketPath, 1)
        defer {
            if let oldSocket {
                setenv("PHOTOSINDEX_SOCKET_PATH", oldSocket, 1)
            } else {
                unsetenv("PHOTOSINDEX_SOCKET_PATH")
            }
        }

        var command = ExportPlanCommand()
        command.decision = decisionURL.path
        command.to = root.appendingPathComponent("Naver Clip").path
        command.output = outputURL.path
        command.layout = "dated-group"
        command.format = "json"

        try command.run()

        let writtenPlan = try CanonicalJSON.decode(ExportPlan.self, from: Data(contentsOf: outputURL))
        XCTAssertEqual(writtenPlan.destinationRoot, envelope.plan.destinationRoot)
        XCTAssertEqual(try ExportPlanIntegrity.sha256(writtenPlan), envelope.digest)
    }

    func testExportApplyCommandSendsPlanPathAndDigest() throws {
        let socketPath = "/tmp/photosindex-export-apply-\(UUID().uuidString.prefix(8)).sock"
        let host = UnixCommandHost(path: socketPath)
        let root = temporaryDirectory("apply")
        let assetID = "ast_cli_asset"
        let group = makeGroup(assetID: assetID)
        let plan = ExportPlan(
            indexRunID: "run_test",
            groupID: group.id,
            generatedAt: Date(timeIntervalSince1970: 1),
            destinationRoot: root.appendingPathComponent("Naver Clip").path,
            stagingRoot: root.appendingPathComponent("staging").path,
            groupAssetIDs: group.assetIDs,
            includedAssetIDs: [assetID],
            excludedAssetIDs: [],
            label: "음식점-상호미확인",
            confidence: 0.95,
            warnings: []
        )
        let planURL = root.appendingPathComponent("plan.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CanonicalJSON.encode(plan).write(to: planURL)
        let receipt = ExportReceipt(
            indexRunID: plan.indexRunID,
            groupID: plan.groupID,
            generatedAt: plan.generatedAt,
            destinationRoot: plan.destinationRoot,
            stagingRoot: plan.stagingRoot,
            entries: [
                ExportReceiptEntry(
                    assetID: assetID,
                    safeFilename: "IMG_2001.HEIC",
                    mediaKind: .photo,
                    bytes: 5,
                    sha256: "abc",
                    relativePath: "originals/IMG_2001.HEIC",
                    reused: false
                )
            ],
            warnings: []
        )
        let digest = try ExportPlanIntegrity.sha256(plan)

        try host.start { request in
            XCTAssertEqual(request.method, "export.apply")
            XCTAssertEqual(request.arguments["plan"], planURL.standardizedFileURL.path)
            XCTAssertEqual(request.arguments["digest"], digest)
            return try! .success(id: request.id, payload: receipt)
        }
        defer { host.stop() }

        let oldSocket = getenv("PHOTOSINDEX_SOCKET_PATH").map { String(cString: $0) }
        setenv("PHOTOSINDEX_SOCKET_PATH", socketPath, 1)
        defer {
            if let oldSocket {
                setenv("PHOTOSINDEX_SOCKET_PATH", oldSocket, 1)
            } else {
                unsetenv("PHOTOSINDEX_SOCKET_PATH")
            }
        }

        var command = ExportApplyCommand()
        command.plan = planURL.path
        command.digest = digest.uppercased()
        command.format = "json"

        try command.run()
    }

    private func makeGroup(assetID: String) -> CaptureGroup {
        let capturedAt = Date(timeIntervalSince1970: 1_768_446_000)
        return CaptureGroup(
            id: "segment_test",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: capturedAt,
            end: capturedAt,
            assetIDs: [assetID],
            warnings: []
        )
    }

    private func makeDecision(assetID: String, group: CaptureGroup) throws -> ModelDecision {
        try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_test",
            groupID: group.id,
            label: "음식점-상호미확인",
            confidence: 0.95,
            includedAssetIDs: [assetID],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexCLITests-\(name)-\(UUID().uuidString)")
    }
}
