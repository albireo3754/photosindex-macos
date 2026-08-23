import Foundation
import XCTest
@testable import PhotosIndexExport

final class ExportApplierTests: XCTestCase {
    private let planner = ExportPlanner()
    private let applier = ExportApplier()

    func testApplierReusesIdenticalFileAndWritesManifestAndReceipt() throws {
        let root = try makeTemporaryDirectory(name: "export-applier-reuse")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)

        let asset = makeAsset(localIdentifier: "photo-a", filename: "IMG_1001.HEIC")
        let group = makeGroup(from: [asset], warnings: [])
        let decision = try makeDecision(groupID: group.id, included: [asset.id], excluded: [], confidence: 0.95)
        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: [asset],
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let materializer = StubMaterializer(payloads: [
            asset.id: Data("sample-media".utf8)
        ])

        let originalsRoot = destinationRoot.appendingPathComponent("originals", isDirectory: true)
        let existingURL = originalsRoot.appendingPathComponent("IMG_1001.HEIC")
        try FileManager.default.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
        try Data("sample-media".utf8).write(to: existingURL)

        let first = try applier.apply(
            plan: plan,
            assets: [asset],
            materializer: materializer,
            fileWriter: FileManagerExportWriter()
        )
        XCTAssertEqual(first.entries.count, 1)
        XCTAssertTrue(first.entries[0].reused)

        let manifestURL = destinationRoot.appendingPathComponent("manifest.json")
        let receiptURL = destinationRoot.appendingPathComponent("receipt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))

        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try CanonicalJSON.decode(ExportReceipt.self, from: receiptData)
        XCTAssertEqual(receipt.entries.count, 1)
        XCTAssertEqual(receipt.entries[0].assetID, asset.id)
        XCTAssertEqual(receipt.entries[0].relativePath, "originals/IMG_1001.HEIC")

        let second = try applier.apply(
            plan: plan,
            assets: [asset],
            materializer: materializer,
            fileWriter: FileManagerExportWriter()
        )
        XCTAssertEqual(second, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testApplierRejectsCollisionForDifferentBytesAtSamePath() throws {
        let root = try makeTemporaryDirectory(name: "export-applier-collision")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)

        let asset = makeAsset(localIdentifier: "photo-b", filename: "IMG_1002.HEIC")
        let group = makeGroup(from: [asset], warnings: [])
        let decision = try makeDecision(groupID: group.id, included: [asset.id], excluded: [], confidence: 0.95)
        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: [asset],
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let originalsRoot = destinationRoot.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
        let existingURL = originalsRoot.appendingPathComponent("IMG_1002.HEIC")
        try Data("old-bytes".utf8).write(to: existingURL)

        let materializer = StubMaterializer(payloads: [
            asset.id: Data("new-bytes".utf8)
        ])

        XCTAssertThrowsError(
            try applier.apply(
                plan: plan,
                assets: [asset],
                materializer: materializer,
                fileWriter: FileManagerExportWriter()
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .collision(path: existingURL.path))
        }
    }

    func testApplierRejectsSymlinkDestinationRoot() throws {
        let root = try makeTemporaryDirectory(name: "export-applier-symlink")
        let realDestination = root.appendingPathComponent("real-destination", isDirectory: true)
        let symlinkDestination = root.appendingPathComponent("linked-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: realDestination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkDestination, withDestinationURL: realDestination)

        let asset = makeAsset(localIdentifier: "photo-c", filename: "IMG_1003.HEIC")
        let group = makeGroup(from: [asset], warnings: [])
        let decision = try makeDecision(groupID: group.id, included: [asset.id], excluded: [], confidence: 0.95)
        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: [asset],
            destinationRoot: symlinkDestination,
            stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let materializer = StubMaterializer(payloads: [
            asset.id: Data("bytes".utf8)
        ])

        XCTAssertThrowsError(
            try applier.apply(
                plan: plan,
                assets: [asset],
                materializer: materializer,
                fileWriter: FileManagerExportWriter()
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .symlinkPath(symlinkDestination.path))
        }
    }

    func testApplierRejectsSymlinkManifestEvenWhenTargetStaysInsideDestination() throws {
        let root = try makeTemporaryDirectory(name: "export-applier-manifest-symlink")
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let manifestTarget = destinationRoot.appendingPathComponent("manifest-target.json")
        try Data("placeholder".utf8).write(to: manifestTarget)
        let manifestLink = destinationRoot.appendingPathComponent("manifest.json")
        try FileManager.default.createSymbolicLink(at: manifestLink, withDestinationURL: manifestTarget)

        let asset = makeAsset(localIdentifier: "photo-d", filename: "IMG_1004.HEIC")
        let group = makeGroup(from: [asset], warnings: [])
        let decision = try makeDecision(groupID: group.id, included: [asset.id], excluded: [], confidence: 0.95)
        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: [asset],
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertThrowsError(
            try applier.apply(
                plan: plan,
                assets: [asset],
                materializer: StubMaterializer(payloads: [asset.id: Data("bytes".utf8)]),
                fileWriter: FileManagerExportWriter()
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .symlinkPath(manifestLink.path))
        }
    }

    private func makeDecision(
        groupID: String,
        included: [String],
        excluded: [String],
        confidence: Double
    ) throws -> ModelDecision {
        try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_20260816",
            groupID: groupID,
            label: "sample-restaurant",
            confidence: confidence,
            includedAssetIDs: included,
            excludedAssetIDs: excluded,
            evidenceReferences: ["manifest.json"],
            unknowns: []
        )
    }

    private func makeGroup(from assets: [PhotoAsset], warnings: [String]) -> CaptureGroup {
        let capturedDates = assets.compactMap(\.capturedAt).sorted()
        return CaptureGroup(
            id: "grp_20260816_01",
            level: .fine,
            localDate: "2026-01-15",
            start: capturedDates.first,
            end: capturedDates.last,
            assetIDs: assets.map(\.id),
            warnings: warnings
        )
    }

    private func makeAsset(localIdentifier: String, filename: String?) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: localIdentifier,
                capturedAt: Date(timeIntervalSince1970: 1_000),
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 4_032,
                pixelHeight: 3_024,
                coordinate: nil,
                originalFilename: filename
            )
        )
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosIndexExportTests", isDirectory: true)
        let directory = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct StubMaterializer: PhotoAssetMaterializing {
    let payloads: [String: Data]

    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        let safeFilename = ExportSupport.safeFilename(for: asset)
        let stageURL = try ExportSupport.validatedChildURL(root: stagingRoot, childName: safeFilename)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let data = payloads[asset.id] ?? Data()
        try data.write(to: stageURL)
        return StagedExportAsset(
            assetID: asset.id,
            mediaKind: asset.mediaKind,
            safeFilename: safeFilename,
            stagedURL: stageURL,
            bytes: Int64(data.count),
            sha256: ExportSupport.sha256Hex(of: data)
        )
    }
}
