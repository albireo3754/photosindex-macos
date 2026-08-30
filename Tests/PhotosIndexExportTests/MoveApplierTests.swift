import Foundation
import PhotosIndexPhotos
import XCTest
@testable import PhotosIndexExport

final class MoveApplierTests: XCTestCase {
    private let planner = ExportPlanner()

    func testMoveDeletesOnlyIncludedAssetAfterVerifiedUpload() throws {
        let fixture = try makeFixture(name: "success")
        let deleter = RecordingPhotoAssetDeleter()
        let verifier = RecordingUploadVerifier()

        let receipt = try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
            plan: fixture.movePlan,
            assets: fixture.assets,
            materializer: DataMaterializer(payload: Data("verified-original".utf8)),
            fileWriter: FileManagerExportWriter(),
            uploadVerifier: verifier,
            deleter: deleter,
            completedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(deleter.deletedAssetIDs, fixture.movePlan.exportPlan.includedAssetIDs)
        XCTAssertEqual(receipt.deletedAssetIDs, fixture.movePlan.exportPlan.includedAssetIDs)
        XCTAssertEqual(verifier.verifiedURLs.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot.appendingPathComponent("move-receipt.json").path
            )
        )
    }

    func testMoveNeverDeletesWhenUploadVerificationFails() throws {
        let fixture = try makeFixture(name: "upload-failure")
        let deleter = RecordingPhotoAssetDeleter()

        XCTAssertThrowsError(
            try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
                plan: fixture.movePlan,
                assets: fixture.assets,
                materializer: DataMaterializer(payload: Data("verified-original".utf8)),
                fileWriter: FileManagerExportWriter(),
                uploadVerifier: RejectingUploadVerifier(),
                deleter: deleter,
                completedAt: Date(timeIntervalSince1970: 2_000)
            )
        ) { error in
            XCTAssertEqual(error as? MoveApplierTestError, .uploadRejected)
        }

        XCTAssertEqual(deleter.deletedAssetIDs, [])
    }

    func testMoveRechecksDestinationHashAfterUploadWaitBeforeDeleting() throws {
        let fixture = try makeFixture(name: "tampered-after-upload")
        let deleter = RecordingPhotoAssetDeleter()

        XCTAssertThrowsError(
            try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
                plan: fixture.movePlan,
                assets: fixture.assets,
                materializer: DataMaterializer(payload: Data("verified-original".utf8)),
                fileWriter: FileManagerExportWriter(),
                uploadVerifier: TamperingUploadVerifier(),
                deleter: deleter,
                completedAt: Date(timeIntervalSince1970: 2_000)
            )
        ) { error in
            guard case MoveError.destinationMismatch = error else {
                return XCTFail("Expected destination mismatch, got \(error)")
            }
        }

        XCTAssertEqual(deleter.deletedAssetIDs, [])
    }

    func testMoveAdoptsCompatibleVerifiedExportFromEarlierIndexRun() throws {
        let fixture = try makeFixture(name: "adopt-existing-export")
        let priorPlan = ExportPlan(
            schemaVersion: fixture.movePlan.exportPlan.schemaVersion,
            indexRunID: "run_previous",
            groupID: fixture.movePlan.exportPlan.groupID,
            generatedAt: Date(timeIntervalSince1970: 500),
            destinationRoot: fixture.movePlan.exportPlan.destinationRoot,
            stagingRoot: fixture.movePlan.exportPlan.stagingRoot + "-previous",
            groupAssetIDs: fixture.movePlan.exportPlan.groupAssetIDs,
            includedAssetIDs: fixture.movePlan.exportPlan.includedAssetIDs,
            excludedAssetIDs: fixture.movePlan.exportPlan.excludedAssetIDs,
            label: fixture.movePlan.exportPlan.label,
            confidence: fixture.movePlan.exportPlan.confidence,
            warnings: fixture.movePlan.exportPlan.warnings
        )
        let writer = FileManagerExportWriter()
        let priorReceipt = try ExportApplier().apply(
            plan: priorPlan,
            assets: fixture.assets,
            materializer: DataMaterializer(payload: Data("verified-original".utf8)),
            fileWriter: writer
        )
        let deleter = RecordingPhotoAssetDeleter()

        let receipt = try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
            plan: fixture.movePlan,
            assets: fixture.assets,
            materializer: FailingMaterializer(),
            fileWriter: writer,
            uploadVerifier: RecordingUploadVerifier(),
            deleter: deleter,
            completedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(receipt.exportReceipt, priorReceipt)
        XCTAssertEqual(deleter.deletedAssetIDs, fixture.movePlan.exportPlan.includedAssetIDs)
        let digest = try MovePlanIntegrity.sha256(fixture.movePlan)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("move-plan-\(digest).json").path
            )
        )
    }

    func testMoveRejectsExistingExportWithDifferentSelectionWithoutDeleting() throws {
        let fixture = try makeFixture(name: "reject-existing-selection")
        let priorPlan = ExportPlan(
            schemaVersion: fixture.movePlan.exportPlan.schemaVersion,
            indexRunID: "run_previous",
            groupID: fixture.movePlan.exportPlan.groupID,
            generatedAt: Date(timeIntervalSince1970: 500),
            destinationRoot: fixture.movePlan.exportPlan.destinationRoot,
            stagingRoot: fixture.movePlan.exportPlan.stagingRoot + "-previous",
            groupAssetIDs: fixture.movePlan.exportPlan.groupAssetIDs,
            includedAssetIDs: fixture.movePlan.exportPlan.excludedAssetIDs,
            excludedAssetIDs: fixture.movePlan.exportPlan.includedAssetIDs,
            label: fixture.movePlan.exportPlan.label,
            confidence: fixture.movePlan.exportPlan.confidence,
            warnings: fixture.movePlan.exportPlan.warnings
        )
        let writer = FileManagerExportWriter()
        _ = try ExportApplier().apply(
            plan: priorPlan,
            assets: fixture.assets,
            materializer: DataMaterializer(payload: Data("different-selection".utf8)),
            fileWriter: writer
        )
        let deleter = RecordingPhotoAssetDeleter()

        XCTAssertThrowsError(
            try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
                plan: fixture.movePlan,
                assets: fixture.assets,
                materializer: FailingMaterializer(),
                fileWriter: writer,
                uploadVerifier: RecordingUploadVerifier(),
                deleter: deleter
            )
        ) { error in
            XCTAssertEqual(error as? MoveError, .existingReceiptMismatch)
        }
        XCTAssertEqual(deleter.deletedAssetIDs, [])
    }

    func testMoveDoesNotWriteReceiptWhenDeletionResultDoesNotMatch() throws {
        let fixture = try makeFixture(name: "delete-mismatch")

        XCTAssertThrowsError(
            try MoveApplier(pendingMoveStore: MemoryPendingMoveStore()).apply(
                plan: fixture.movePlan,
                assets: fixture.assets,
                materializer: DataMaterializer(payload: Data("verified-original".utf8)),
                fileWriter: FileManagerExportWriter(),
                uploadVerifier: RecordingUploadVerifier(),
                deleter: MismatchingPhotoAssetDeleter()
            )
        ) { error in
            XCTAssertEqual(error as? MoveError, .sourceDeletionMismatch)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot.appendingPathComponent("move-receipt.json").path
            )
        )
    }

    func testMoveRecoversReceiptWhenFirstWriteFailsAfterDeletion() throws {
        let fixture = try makeFixture(name: "receipt-write-recovery")
        let store = MemoryPendingMoveStore()
        let deleter = StatefulPhotoAssetDeleter(
            presentLocalIdentifiers: Set(fixture.assets.map(\.localIdentifier))
        )
        let failingWriter = ReceiptFailingWriter()
        let applier = MoveApplier(pendingMoveStore: store)

        XCTAssertThrowsError(
            try applier.apply(
                plan: fixture.movePlan,
                assets: fixture.assets,
                materializer: DataMaterializer(payload: Data("verified-original".utf8)),
                fileWriter: failingWriter,
                uploadVerifier: RecordingUploadVerifier(),
                deleter: deleter,
                completedAt: Date(timeIntervalSince1970: 2_000)
            )
        ) { error in
            XCTAssertEqual(error as? MoveApplierTestError, .receiptWriteRejected)
        }

        let digest = try MovePlanIntegrity.sha256(fixture.movePlan)
        XCTAssertNotNil(try store.load(digest: digest))
        let excludedLocalIdentifiers = Set(
            fixture.assets
                .filter { fixture.movePlan.exportPlan.excludedAssetIDs.contains($0.id) }
                .map(\.localIdentifier)
        )
        XCTAssertEqual(deleter.presentLocalIdentifiers, excludedLocalIdentifiers)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot.appendingPathComponent("move-receipt.json").path
            )
        )

        let receipt = try applier.apply(
            plan: fixture.movePlan,
            assets: [],
            materializer: FailingMaterializer(),
            fileWriter: FileManagerExportWriter(),
            uploadVerifier: RecordingUploadVerifier(),
            deleter: deleter,
            completedAt: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(receipt.deletedAssetIDs, fixture.movePlan.exportPlan.includedAssetIDs)
        XCTAssertEqual(deleter.presentLocalIdentifiers, excludedLocalIdentifiers)
        XCTAssertNil(try store.load(digest: digest))
    }

    func testFilePendingMoveStoreRoundTripsWithOwnerOnlyPermissions() throws {
        let fixture = try makeFixture(name: "file-pending-store")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexPendingMoveStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = try MovePlanIntegrity.sha256(fixture.movePlan)
        let exportReceipt = try ExportApplier().apply(
            plan: fixture.movePlan.exportPlan,
            assets: fixture.assets,
            materializer: DataMaterializer(payload: Data("verified-original".utf8)),
            fileWriter: FileManagerExportWriter()
        )
        let journal = PendingMoveJournal(
            digest: digest,
            plan: fixture.movePlan,
            exportReceipt: exportReceipt,
            deletionTargets: fixture.assets
                .filter { fixture.movePlan.exportPlan.includedAssetIDs.contains($0.id) }
                .map(\.deletionTarget)
        )
        let store = FilePendingMoveStore(root: root)

        try store.save(journal)

        XCTAssertEqual(try store.load(digest: digest), journal)
        XCTAssertEqual(try permissions(at: root), 0o700)
        XCTAssertEqual(
            try permissions(at: root.appendingPathComponent("\(digest).json")),
            0o600
        )

        try store.remove(digest: digest)
        XCTAssertNil(try store.load(digest: digest))
    }

    func testMoveRecoveryDeletesOnlyTargetsThatRemainPresent() throws {
        let fixture = try makeFixture(name: "partial-recovery", includeAllAssets: true)
        let writer = FileManagerExportWriter()
        let exportReceipt = try ExportApplier().apply(
            plan: fixture.movePlan.exportPlan,
            assets: fixture.assets,
            materializer: DataMaterializer(payload: Data("verified-original".utf8)),
            fileWriter: writer
        )
        let digest = try MovePlanIntegrity.sha256(fixture.movePlan)
        let movePlanURL = fixture.destinationRoot
            .appendingPathComponent("move-plan-\(digest).json")
        try ExportSupport.writeCanonicalJSON(
            fixture.movePlan,
            to: movePlanURL,
            fileWriter: writer
        )
        let store = MemoryPendingMoveStore()
        let targets = fixture.assets.map(\.deletionTarget)
        try store.save(
            PendingMoveJournal(
                digest: digest,
                plan: fixture.movePlan,
                exportReceipt: exportReceipt,
                deletionTargets: targets
            )
        )
        let remainingTarget = targets[1]
        let deleter = StatefulPhotoAssetDeleter(
            presentLocalIdentifiers: [remainingTarget.localIdentifier]
        )

        let receipt = try MoveApplier(pendingMoveStore: store).apply(
            plan: fixture.movePlan,
            assets: [],
            materializer: FailingMaterializer(),
            fileWriter: writer,
            uploadVerifier: RecordingUploadVerifier(),
            deleter: deleter
        )

        XCTAssertEqual(deleter.actuallyDeletedAssetIDs, [remainingTarget.id])
        XCTAssertEqual(Set(receipt.deletedAssetIDs), Set(targets.map(\.id)))
        XCTAssertTrue(deleter.presentLocalIdentifiers.isEmpty)
        XCTAssertNil(try store.load(digest: digest))
    }

    func testUploadStateTreatsTransientErrorAsPendingThenAllowsSuccess() {
        let transient = ICloudItemUploadState(
            path: "/iCloud/file.mov",
            isUbiquitous: true,
            isUploaded: false,
            isUploading: false,
            isCurrent: false,
            uploadErrorDescription: "temporarily unreachable"
        )
        let uploaded = ICloudItemUploadState(
            path: "/iCloud/file.mov",
            isUbiquitous: true,
            isUploaded: true,
            isUploading: false,
            isCurrent: true,
            uploadErrorDescription: nil
        )

        XCTAssertEqual(
            ICloudDestinationUploadVerifier.evaluate(
                states: [transient],
                deadlineReached: false
            ),
            .pending(lastUploadError: "temporarily unreachable")
        )
        XCTAssertEqual(
            ICloudDestinationUploadVerifier.evaluate(
                states: [uploaded],
                deadlineReached: false
            ),
            .complete
        )
    }

    func testUploadStateFailsPersistentErrorOnlyAtDeadline() {
        let persistent = ICloudItemUploadState(
            path: "/iCloud/file.mov",
            isUbiquitous: true,
            isUploaded: false,
            isUploading: false,
            isCurrent: false,
            uploadErrorDescription: "account unavailable"
        )

        XCTAssertEqual(
            ICloudDestinationUploadVerifier.evaluate(
                states: [persistent],
                deadlineReached: true
            ),
            .failed(.uploadFailed("account unavailable"))
        )
    }

    private func makeFixture(name: String, includeAllAssets: Bool = false) throws -> MoveFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexMoveTests-\(name)-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("Naver Clip/2026-01-15_test")
        let staging = root.appendingPathComponent("staging")
        let included = makeAsset(identifier: "move-included", filename: "IMG_1001.JPG")
        let excluded = makeAsset(identifier: "move-excluded", filename: "IMG_1002.JPG")
        let assets = [included, excluded]
        let group = CaptureGroup(
            id: "segment_test",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: included.capturedAt,
            end: included.capturedAt,
            assetIDs: assets.map(\.id),
            warnings: []
        )
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_test",
            groupID: group.id,
            label: "test",
            confidence: 0.95,
            includedAssetIDs: includeAllAssets ? assets.map(\.id) : [included.id],
            excludedAssetIDs: includeAllAssets ? [] : [excluded.id],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
        let exportPlan = try planner.makePlan(
            currentIndexRunID: "run_test",
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: destination,
            stagingRoot: staging,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        return MoveFixture(
            movePlan: MovePlan(
                exportPlan: exportPlan,
                operation: .deleteSourceAfterVerifiedUpload
            ),
            assets: assets,
            destinationRoot: destination
        )
    }

    private func makeAsset(identifier: String, filename: String) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: identifier,
                capturedAt: Date(timeIntervalSince1970: 1_000),
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: filename
            )
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private struct MoveFixture {
    let movePlan: MovePlan
    let assets: [PhotoAsset]
    let destinationRoot: URL
}

private enum MoveApplierTestError: Error, Equatable {
    case uploadRejected
    case materializerMustNotRun
    case receiptWriteRejected
}

private struct DataMaterializer: PhotoAssetMaterializing {
    let payload: Data

    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let filename = asset.publicFilename ?? "\(asset.id).jpg"
        let url = stagingRoot.appendingPathComponent(filename)
        try payload.write(to: url)
        return StagedExportAsset(
            assetID: asset.id,
            mediaKind: asset.mediaKind,
            safeFilename: filename,
            stagedURL: url,
            bytes: Int64(payload.count),
            sha256: ExportSupport.sha256Hex(of: payload)
        )
    }
}

private struct FailingMaterializer: PhotoAssetMaterializing {
    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        throw MoveApplierTestError.materializerMustNotRun
    }
}

private final class RecordingPhotoAssetDeleter: PhotoAssetDeleting, @unchecked Sendable {
    private(set) var deletedAssetIDs: [String] = []

    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        deletedAssetIDs = targets.map(\.id)
        return deletedAssetIDs
    }
}

private struct MismatchingPhotoAssetDeleter: PhotoAssetDeleting {
    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        []
    }
}

private final class StatefulPhotoAssetDeleter: PhotoAssetDeleting, @unchecked Sendable {
    private(set) var presentLocalIdentifiers: Set<String>
    private(set) var actuallyDeletedAssetIDs: [String] = []

    init(presentLocalIdentifiers: Set<String>) {
        self.presentLocalIdentifiers = presentLocalIdentifiers
    }

    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        actuallyDeletedAssetIDs = targets.compactMap { target in
            presentLocalIdentifiers.remove(target.localIdentifier) == nil ? nil : target.id
        }
        return targets.map(\.id)
    }
}

private final class MemoryPendingMoveStore: PendingMoveStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var journals: [String: PendingMoveJournal] = [:]

    func save(_ journal: PendingMoveJournal) throws {
        lock.lock()
        defer { lock.unlock() }
        journals[journal.digest] = journal
    }

    func load(digest: String) throws -> PendingMoveJournal? {
        lock.lock()
        defer { lock.unlock() }
        return journals[digest]
    }

    func remove(digest: String) throws {
        lock.lock()
        defer { lock.unlock() }
        journals.removeValue(forKey: digest)
    }
}

private final class ReceiptFailingWriter: ExportWriting, @unchecked Sendable {
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
            throw MoveApplierTestError.receiptWriteRejected
        }
        try delegate.write(data, to: url)
    }
}

private final class RecordingUploadVerifier: DestinationUploadVerifying, @unchecked Sendable {
    private(set) var verifiedURLs: [URL] = []

    func verifyUploaded(urls: [URL]) throws {
        verifiedURLs = urls
    }
}

private struct RejectingUploadVerifier: DestinationUploadVerifying {
    func verifyUploaded(urls: [URL]) throws {
        throw MoveApplierTestError.uploadRejected
    }
}

private struct TamperingUploadVerifier: DestinationUploadVerifying {
    func verifyUploaded(urls: [URL]) throws {
        try Data("tampered".utf8).write(to: urls[0], options: .atomic)
    }
}
