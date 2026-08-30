import CryptoKit
import Foundation
import PhotosIndexCore
import PhotosIndexExport
import PhotosIndexPhotos
import XCTest
@testable import PhotosIndexApp

final class ExportCommandServiceTests: XCTestCase {
    func testPlansAndAppliesMoveWithMoveSpecificIssuedDigest() throws {
        let root = temporaryDirectory("move")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let asset = makeAsset()
        let group = makeGroup(asset: asset)
        let decision = try makeDecision(asset: asset, group: group)
        let deleter = ServiceRecordingDeleter()
        let service = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true),
            uploadVerifier: ServiceAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(
                root: root.appendingPathComponent("pending-moves", isDirectory: true)
            )
        )

        let envelope = try service.makeMovePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: [asset],
            requestedRoot: allowedRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let receipt = try service.applyMove(
            envelope.plan,
            digest: envelope.digest,
            currentIndexRunID: "run_test",
            group: group,
            assets: [asset],
            completedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(receipt.deletedAssetIDs, [asset.id])
        XCTAssertEqual(deleter.deletedAssetIDs, [asset.id])
        XCTAssertNotEqual(
            envelope.digest,
            try ExportPlanIntegrity.sha256(envelope.plan.exportPlan)
        )
        XCTAssertThrowsError(
            try service.applyMove(
                envelope.plan,
                digest: try ExportPlanIntegrity.sha256(envelope.plan.exportPlan),
                currentIndexRunID: "run_test",
                group: group,
                assets: [asset]
            )
        ) { error in
            guard case MovePlanIntegrityError.digestMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testResumesPendingMoveAfterServiceRestartWithoutIssuedDigest() throws {
        let root = temporaryDirectory("move-restart-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending-moves", isDirectory: true)
        let asset = makeAsset()
        let group = makeGroup(asset: asset)
        let decision = try makeDecision(asset: asset, group: group)
        let deleter = ServiceStatefulDeleter(
            presentLocalIdentifiers: [asset.localIdentifier]
        )
        let firstService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: ServiceReceiptFailingWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true),
            uploadVerifier: ServiceAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(root: pendingRoot)
        )
        let envelope = try firstService.makeMovePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: [asset],
            requestedRoot: allowedRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertThrowsError(
            try firstService.applyMove(
                envelope.plan,
                digest: envelope.digest,
                currentIndexRunID: "run_test",
                group: group,
                assets: [asset]
            )
        )
        XCTAssertTrue(deleter.presentLocalIdentifiers.isEmpty)

        let restartedService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceFailingMaterializer(),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging-restarted", isDirectory: true),
            uploadVerifier: ServiceAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(root: pendingRoot)
        )
        let recovered = try restartedService.resumeMoveIfNeeded(
            envelope.plan,
            digest: envelope.digest,
            completedAt: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(recovered?.deletedAssetIDs, [asset.id])
        XCTAssertNil(
            try FilePendingMoveStore(root: pendingRoot).load(digest: envelope.digest)
        )
    }

    func testValidatesPlansAndAppliesDigestBoundCopy() throws {
        let root = temporaryDirectory("valid")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let asset = makeAsset()
        let group = makeGroup(asset: asset)
        let decision = try makeDecision(asset: asset, group: group)
        let service = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true)
        )

        let validation = try service.validate(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: [asset]
        )
        let envelope = try service.makePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: [asset],
            requestedRoot: allowedRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let receipt = try service.apply(
            envelope.plan,
            digest: envelope.digest,
            currentIndexRunID: "run_test",
            group: group,
            assets: [asset]
        )

        XCTAssertTrue(validation.valid)
        XCTAssertEqual(validation.includedAssetCount, 1)
        XCTAssertTrue(envelope.plan.destinationRoot.hasSuffix("2026-01-15_음식점-상호미확인"))
        XCTAssertEqual(try ExportPlanIntegrity.sha256(envelope.plan), envelope.digest)
        XCTAssertEqual(receipt.entries.map(\.relativePath), ["originals/IMG_2001.HEIC"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: envelope.plan.destinationRoot)
                    .appendingPathComponent("manifest.json").path
            )
        )
    }

    func testRejectsOutsideRootAndDigestMismatch() throws {
        let root = temporaryDirectory("reject")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let asset = makeAsset()
        let group = makeGroup(asset: asset)
        let decision = try makeDecision(asset: asset, group: group)
        let service = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true)
        )

        XCTAssertThrowsError(
            try service.makePlan(
                currentIndexRunID: "run_test",
                decision: decision,
                group: group,
                assets: [asset],
                requestedRoot: root.appendingPathComponent("elsewhere")
            )
        )

        let envelope = try service.makePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: [asset],
            requestedRoot: allowedRoot
        )
        XCTAssertThrowsError(
            try service.apply(
                envelope.plan,
                digest: String(repeating: "0", count: 64),
                currentIndexRunID: "run_test",
                group: group,
                assets: [asset]
            )
        ) { error in
            guard case ExportPlanIntegrityError.digestMismatch = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testMovePlanAcceptsLargeDateWideMediaKindGroup() throws {
        let root = temporaryDirectory("media-kind-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let assets = (0..<140).map(makeVideoAsset)
        let group = CaptureGroup(
            id: "media-video_20260115_synthetic",
            level: .mediaKind,
            mediaKind: .video,
            localDate: "2026-01-15",
            start: assets.first?.capturedAt,
            end: assets.last?.capturedAt,
            assetIDs: assets.map(\.id),
            warnings: []
        )
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_test",
            groupID: group.id,
            label: "videos",
            confidence: 1,
            includedAssetIDs: assets.map(\.id),
            excludedAssetIDs: [],
            evidenceReferences: ["all-pages-inspected"],
            unknowns: []
        )
        let service = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true)
        )

        let envelope = try service.makeMovePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: assets,
            requestedRoot: allowedRoot
        )

        XCTAssertEqual(envelope.plan.exportPlan.includedAssetIDs.count, 140)
        XCTAssertEqual(envelope.plan.exportPlan.groupID, group.id)
    }

    private func makeAsset() -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-service-asset",
                capturedAt: Date(timeIntervalSince1970: 1_768_446_000),
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_2001.HEIC"
            )
        )
    }

    private func makeVideoAsset(index: Int) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "synthetic-video-\(index)",
                capturedAt: Date(timeIntervalSince1970: 1_768_446_000 + Double(index)),
                mediaKind: .video,
                durationSeconds: 10,
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                coordinate: nil,
                originalFilename: String(format: "VID_%04d.MOV", index)
            )
        )
    }

    private func makeGroup(asset: PhotoAsset) -> CaptureGroup {
        CaptureGroup(
            id: "segment_test",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: asset.capturedAt,
            end: asset.capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
    }

    private func makeDecision(asset: PhotoAsset, group: CaptureGroup) throws -> ModelDecision {
        try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_test",
            groupID: group.id,
            label: "음식점-상호미확인",
            confidence: 0.95,
            includedAssetIDs: [asset.id],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexExportCommandServiceTests-\(name)-\(UUID().uuidString)")
    }
}

private struct ServiceStubMaterializer: PhotoAssetMaterializing {
    let data: Data

    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let filename = asset.publicFilename ?? "\(asset.id).jpg"
        let url = stagingRoot.appendingPathComponent(filename)
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return StagedExportAsset(
            assetID: asset.id,
            mediaKind: asset.mediaKind,
            safeFilename: filename,
            stagedURL: url,
            bytes: Int64(data.count),
            sha256: digest
        )
    }
}

private struct ServiceAcceptingUploadVerifier: DestinationUploadVerifying {
    func verifyUploaded(urls: [URL]) throws {}
}

private final class ServiceRecordingDeleter: PhotoAssetDeleting, @unchecked Sendable {
    private(set) var deletedAssetIDs: [String] = []

    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        deletedAssetIDs = targets.map(\.id)
        return deletedAssetIDs
    }
}

private struct ServiceFailingMaterializer: PhotoAssetMaterializing {
    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        throw ServiceRecoveryTestError.materializerMustNotRun
    }
}

private enum ServiceRecoveryTestError: Error {
    case receiptWriteRejected
    case materializerMustNotRun
}

private final class ServiceStatefulDeleter: PhotoAssetDeleting, @unchecked Sendable {
    private(set) var presentLocalIdentifiers: Set<String>

    init(presentLocalIdentifiers: Set<String>) {
        self.presentLocalIdentifiers = presentLocalIdentifiers
    }

    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        for target in targets {
            presentLocalIdentifiers.remove(target.localIdentifier)
        }
        return targets.map(\.id)
    }
}

private final class ServiceReceiptFailingWriter: ExportWriting, @unchecked Sendable {
    private let delegate = FileManagerExportWriter()
    private var shouldFailReceipt = true

    func createDirectory(at url: URL) throws { try delegate.createDirectory(at: url) }
    func fileExists(at url: URL) -> Bool { delegate.fileExists(at: url) }
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try delegate.attributesOfItem(at: url)
    }
    func contents(at url: URL) throws -> Data { try delegate.contents(at: url) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try delegate.copyItem(at: sourceURL, to: destinationURL)
    }
    func removeItem(at url: URL) throws { try delegate.removeItem(at: url) }

    func write(_ data: Data, to url: URL) throws {
        if shouldFailReceipt && url.lastPathComponent == "move-receipt.json" {
            shouldFailReceipt = false
            throw ServiceRecoveryTestError.receiptWriteRejected
        }
        try delegate.write(data, to: url)
    }
}
