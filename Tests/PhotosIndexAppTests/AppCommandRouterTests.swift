import CryptoKit
import Foundation
import XCTest
import PhotosIndexCommand
import PhotosIndexCore
import PhotosIndexExport
import PhotosIndexPhotos
@testable import PhotosIndexApp

final class AppCommandRouterTests: XCTestCase {
    func testRoutesDecisionValidationFromDecisionFile() throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-validate-1",
                capturedAt: date,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_0001.HEIC"
            )
        )
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: [asset]),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" }
        )

        let syncResponse = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )
        let groupsResponse = router.handle(
            CommandRequest(
                method: "groups.list",
                arguments: ["level": "fine", "date": "2026-01-15"]
            )
        )
        let indexRunID = try syncResponse.decodePayload(IndexSyncPayload.self).indexRunID
        let group = try groupsResponse.decodePayload(GroupsPayload.self).groups[0]
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: indexRunID,
            groupID: group.id,
            label: "음식점-상호미확인",
            confidence: 0.95,
            includedAssetIDs: [asset.id],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
        let decisionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("photosindex-decision-\(UUID().uuidString).json")
        try CanonicalJSON.encode(decision).write(to: decisionURL)
        defer { try? FileManager.default.removeItem(at: decisionURL) }

        let response = router.handle(
            CommandRequest(method: "decisions.validate", arguments: ["file": decisionURL.path])
        )

        let payload = try response.decodePayload(DecisionValidationPayload.self)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(payload.valid)
        XCTAssertEqual(payload.indexRunID, indexRunID)
        XCTAssertEqual(payload.groupID, group.id)
        XCTAssertEqual(payload.includedAssetCount, 1)
        XCTAssertEqual(payload.excludedAssetCount, 0)
    }

    func testRoutesSyncAndFineGroupList() throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-1",
                capturedAt: date,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_0001.HEIC"
            )
        )
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: [asset]),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            inspectEvidence: { runID, group, assets, output, _, page in
                let packet = GroupEvidencePacket(
                    schemaVersion: 1,
                    indexRunID: runID,
                    generatedAt: date,
                    timezone: "Asia/Seoul",
                    group: group,
                    assets: assets.map(\.evidenceAsset),
                    samples: [],
                    warnings: []
                )
                return EvidenceInspectionPayload(
                    indexRunID: runID,
                    groupID: group.id,
                    outputDirectory: output.path,
                    evidenceJSON: output.appendingPathComponent("evidence.json").path,
                    summaryMarkdown: output.appendingPathComponent("summary.md").path,
                    sampleFiles: [],
                    packet: packet,
                    page: page
                )
            }
        )

        let syncResponse = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )
        let groupsResponse = router.handle(
            CommandRequest(
                method: "groups.list",
                arguments: ["level": "fine", "date": "2026-01-15"]
            )
        )
        let mediaGroupsResponse = router.handle(
            CommandRequest(
                method: "groups.list",
                arguments: ["level": "media-kind", "date": "2026-01-15"]
            )
        )
        let invalidLevelResponse = router.handle(
            CommandRequest(
                method: "groups.list",
                arguments: ["level": "unsupported", "date": "2026-01-15"]
            )
        )
        let wrongDateResponse = router.handle(
            CommandRequest(
                method: "groups.list",
                arguments: ["level": "fine", "date": "2026-01-16"]
            )
        )
        let indexRunID = try syncResponse.decodePayload(IndexSyncPayload.self).indexRunID
        let groupID = try groupsResponse.decodePayload(GroupsPayload.self).groups[0].id
        let mediaGroupID = try mediaGroupsResponse.decodePayload(GroupsPayload.self).groups[0].id
        let timeoutRouter = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            inspectEvidence: { _, _, _, _, _, _ in
                throw EvidenceInspectionServiceError.timedOut
            }
        )
        let showResponse = router.handle(
            CommandRequest(
                method: "groups.show",
                arguments: ["id": groupID, "index-run": indexRunID]
            )
        )
        let staleResponse = router.handle(
            CommandRequest(
                method: "groups.show",
                arguments: ["id": groupID, "index-run": "run_stale"]
            )
        )
        let inspectResponse = router.handle(
            CommandRequest(
                method: "groups.inspect",
                arguments: [
                    "id": groupID,
                    "index-run": indexRunID,
                    "output": "/tmp/photosindex-inspect-test",
                    "samples": "12",
                ]
            )
        )
        let mediaInspectResponse = router.handle(
            CommandRequest(
                method: "groups.inspect",
                arguments: [
                    "id": mediaGroupID,
                    "index-run": indexRunID,
                    "output": "/tmp/photosindex-media-inspect-test",
                    "samples": "12",
                ]
            )
        )
        let oversizedInspectResponse = router.handle(
            CommandRequest(
                method: "groups.inspect",
                arguments: [
                    "id": groupID,
                    "index-run": indexRunID,
                    "output": "/tmp/photosindex-inspect-test",
                    "samples": "13",
                ]
            )
        )
        let timedOutInspectResponse = timeoutRouter.handle(
            CommandRequest(
                method: "groups.inspect",
                arguments: [
                    "id": groupID,
                    "index-run": indexRunID,
                    "output": "/tmp/photosindex-inspect-timeout-test",
                    "samples": "1",
                ]
            )
        )

        XCTAssertEqual(try syncResponse.decodePayload(IndexSyncPayload.self).assetCount, 1)
        XCTAssertEqual(try groupsResponse.decodePayload(GroupsPayload.self).groups.count, 1)
        let mediaGroups = try mediaGroupsResponse.decodePayload(GroupsPayload.self)
        XCTAssertEqual(mediaGroups.level, .mediaKind)
        XCTAssertEqual(mediaGroups.groups.map(\.mediaKind), [.photo])
        XCTAssertEqual(invalidLevelResponse.error?.code, "invalid-arguments")
        XCTAssertFalse(wrongDateResponse.ok)
        XCTAssertEqual(wrongDateResponse.error?.code, "index-date-mismatch")
        XCTAssertEqual(try showResponse.decodePayload(GroupDetailPayload.self).assets.count, 1)
        XCTAssertFalse(staleResponse.ok)
        XCTAssertEqual(staleResponse.error?.code, "stale-index-run")
        XCTAssertEqual(
            try inspectResponse.decodePayload(EvidenceInspectionPayload.self).packet.group.id,
            groupID
        )
        XCTAssertEqual(
            try inspectResponse.decodePayload(EvidenceInspectionPayload.self).page.assetIDs,
            [asset.id]
        )
        XCTAssertEqual(
            try mediaInspectResponse.decodePayload(EvidenceInspectionPayload.self).packet.group.level,
            .mediaKind
        )
        XCTAssertEqual(oversizedInspectResponse.error?.code, "invalid-arguments")
        XCTAssertEqual(timedOutInspectResponse.error?.code, "evidence-timeout")
    }

    func testInspectRoutesTheRequestedAssetPage() throws {
        let capturedAt = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let assets = (0..<26).map { offset in
            PhotoAssetMapper.map(
                PhotoMetadataInput(
                    localIdentifier: "private-page-\(offset)",
                    capturedAt: capturedAt,
                    mediaKind: .photo,
                    durationSeconds: 0,
                    pixelWidth: 100,
                    pixelHeight: 100,
                    coordinate: nil,
                    originalFilename: String(format: "IMG_%04d.JPG", offset)
                )
            )
        }
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: assets),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            inspectEvidence: { runID, group, pageAssets, output, _, page in
                XCTAssertEqual(pageAssets.map(\.id), page.assetIDs)
                let packet = GroupEvidencePacket(
                    schemaVersion: 1,
                    indexRunID: runID,
                    generatedAt: capturedAt,
                    timezone: "Asia/Seoul",
                    group: group,
                    assets: pageAssets.map(\.evidenceAsset),
                    samples: [],
                    warnings: []
                )
                return EvidenceInspectionPayload(
                    indexRunID: runID,
                    groupID: group.id,
                    outputDirectory: output.path,
                    evidenceJSON: output.appendingPathComponent("evidence.json").path,
                    summaryMarkdown: output.appendingPathComponent("summary.md").path,
                    sampleFiles: [],
                    packet: packet,
                    page: page
                )
            }
        )
        let sync = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )
        let runID = try sync.decodePayload(IndexSyncPayload.self).indexRunID
        let group = runtime.groups(level: .fine).groups[0]

        let response = router.handle(
            CommandRequest(
                method: "groups.inspect",
                arguments: [
                    "id": group.id,
                    "index-run": runID,
                    "output": "/tmp/photosindex-page-test",
                    "samples": "12",
                    "page": "2",
                    "page-size": "12",
                ]
            )
        )
        let payload = try response.decodePayload(EvidenceInspectionPayload.self)

        XCTAssertEqual(payload.page.pageNumber, 2)
        XCTAssertEqual(payload.page.totalPages, 3)
        XCTAssertEqual(payload.page.assetIDs, Array(group.assetIDs[12..<24]))
        XCTAssertEqual(payload.page.remainingAssetIDs, Array(group.assetIDs[24..<26]))
    }

    func testAuthorizeReturnsUpdatedPermission() throws {
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: []),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "not-determined" },
            requestAuthorization: { "authorized" }
        )

        let response = router.handle(CommandRequest(method: "authorize"))

        XCTAssertEqual(
            try response.decodePayload(AuthorizationPayload.self).permission,
            "authorized"
        )
    }

    func testSyncRequiresPhotosPermission() {
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: []),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "not-determined" },
            requestAuthorization: { "not-determined" }
        )

        let response = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "photos-permission-required")
    }

    func testRoutesExportPlanAndApplyFromFiles() throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z")!
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-export-route",
                capturedAt: date,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_3001.HEIC"
            )
        )
        let root = temporaryDirectory("router-export")
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let exportService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("sample-media".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true)
        )
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: [asset]),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            exportService: exportService
        )
        let sync = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )
        let runID = try sync.decodePayload(IndexSyncPayload.self).indexRunID
        let groupID = runtime.groups(level: .fine).groups[0].id
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: runID,
            groupID: groupID,
            label: "음식점-상호미확인",
            confidence: 0.95,
            includedAssetIDs: [asset.id],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
        let decisionURL = root.appendingPathComponent("decision.json")
        let planURL = root.appendingPathComponent("plan.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try CanonicalJSON.encode(decision).write(to: decisionURL)
        let symlinkDecisionURL = root.appendingPathComponent("decision-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkDecisionURL,
            withDestinationURL: decisionURL
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let validation = router.handle(
            CommandRequest(
                method: "decisions.validate",
                arguments: ["file": decisionURL.path]
            )
        )
        let planned = router.handle(
            CommandRequest(
                method: "export.plan",
                arguments: [
                    "decision": decisionURL.path,
                    "to": allowedRoot.path,
                    "layout": "dated-group",
                ]
            )
        )
        let symlinkValidation = router.handle(
            CommandRequest(
                method: "decisions.validate",
                arguments: ["file": symlinkDecisionURL.path]
            )
        )
        let envelope = try planned.decodePayload(ExportPlanEnvelope.self)
        try CanonicalJSON.encode(envelope.plan).write(to: planURL)
        let applied = router.handle(
            CommandRequest(
                method: "export.apply",
                arguments: [
                    "plan": planURL.path,
                    "digest": envelope.digest,
                ]
            )
        )

        XCTAssertTrue(try validation.decodePayload(DecisionValidationPayload.self).valid)
        XCTAssertEqual(envelope.plan.groupID, groupID)
        XCTAssertEqual(envelope.digest.count, 64)
        XCTAssertFalse(symlinkValidation.ok)
        XCTAssertEqual(symlinkValidation.error?.code, "command-failed")
        XCTAssertEqual(try applied.decodePayload(ExportReceipt.self).entries.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: envelope.plan.destinationRoot)
                    .appendingPathComponent("manifest.json").path
            )
        )
    }

    func testRoutesMovePlanAndApplyFromFiles() throws {
        let capturedAt = ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z")!
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-move-route",
                capturedAt: capturedAt,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_4001.JPG"
            )
        )
        let root = temporaryDirectory("router-move")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let deleter = RouterRecordingDeleter()
        let exportService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("move".utf8)),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true),
            uploadVerifier: RouterAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(
                root: root.appendingPathComponent("pending-moves", isDirectory: true)
            )
        )
        let runtime = IndexRuntime(
            library: RouterFakePhotoLibrary(assets: [asset]),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let router = AppCommandRouter(
            runtime: runtime,
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            exportService: exportService
        )
        let sync = router.handle(
            CommandRequest(method: "sync", arguments: ["date": "2026-01-15"])
        )
        let runID = try sync.decodePayload(IndexSyncPayload.self).indexRunID
        let group = runtime.groups(level: .fine).groups[0]
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: runID,
            groupID: group.id,
            label: "move-test",
            confidence: 0.95,
            includedAssetIDs: [asset.id],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let decisionURL = root.appendingPathComponent("decision.json")
        let planURL = root.appendingPathComponent("move-plan.json")
        try CanonicalJSON.encode(decision).write(to: decisionURL)

        let planned = router.handle(
            CommandRequest(
                method: "move.plan",
                arguments: [
                    "decision": decisionURL.path,
                    "to": allowedRoot.path,
                    "layout": "dated-group",
                ]
            )
        )
        let envelope = try planned.decodePayload(MovePlanEnvelope.self)
        try CanonicalJSON.encode(envelope.plan).write(to: planURL)
        let applied = router.handle(
            CommandRequest(
                method: "move.apply",
                arguments: [
                    "plan": planURL.path,
                    "digest": envelope.digest,
                ]
            )
        )
        let receipt = try applied.decodePayload(MoveReceipt.self)

        XCTAssertEqual(receipt.deletedAssetIDs, [asset.id])
        XCTAssertEqual(deleter.deletedAssetIDs, [asset.id])
        XCTAssertEqual(envelope.plan.operation, .deleteSourceAfterVerifiedUpload)
    }

    func testRoutesPendingMoveRecoveryWithoutCurrentIndex() throws {
        let capturedAt = ISO8601DateFormatter().date(from: "2026-01-15T10:00:00Z")!
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "private-recovery-route",
                capturedAt: capturedAt,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_4002.JPG"
            )
        )
        let root = temporaryDirectory("router-move-recovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedRoot = root.appendingPathComponent("Naver Clip", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending-moves", isDirectory: true)
        let group = CaptureGroup(
            id: "segment_recovery",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: capturedAt,
            end: capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
        let decision = try ModelDecision(
            schemaVersion: 1,
            indexRunID: "run_recovery",
            groupID: group.id,
            label: "recovery-test",
            confidence: 0.95,
            includedAssetIDs: [asset.id],
            excludedAssetIDs: [],
            evidenceReferences: ["sample-001"],
            unknowns: []
        )
        let deleter = RouterStatefulDeleter(
            presentLocalIdentifiers: [asset.localIdentifier]
        )
        let firstService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: ServiceStubMaterializer(data: Data("move".utf8)),
            fileWriter: RouterReceiptFailingWriter(),
            temporaryRoot: root.appendingPathComponent("staging", isDirectory: true),
            uploadVerifier: RouterAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(root: pendingRoot)
        )
        let envelope = try firstService.makeMovePlan(
            currentIndexRunID: "run_recovery",
            decision: decision,
            group: group,
            assets: [asset],
            requestedRoot: allowedRoot
        )
        XCTAssertThrowsError(
            try firstService.applyMove(
                envelope.plan,
                digest: envelope.digest,
                currentIndexRunID: "run_recovery",
                group: group,
                assets: [asset]
            )
        )

        let restartedService = ExportCommandService(
            allowedRoot: allowedRoot,
            materializer: RouterFailingMaterializer(),
            fileWriter: FileManagerExportWriter(),
            temporaryRoot: root.appendingPathComponent("staging-restarted", isDirectory: true),
            uploadVerifier: RouterAcceptingUploadVerifier(),
            deleter: deleter,
            pendingMoveStore: FilePendingMoveStore(root: pendingRoot)
        )
        let router = AppCommandRouter(
            runtime: IndexRuntime(
                library: RouterFakePhotoLibrary(assets: []),
                timezone: TimeZone(identifier: "Asia/Seoul")!
            ),
            permission: { "authorized" },
            requestAuthorization: { "authorized" },
            exportService: restartedService
        )
        let planURL = root.appendingPathComponent("recovery-plan.json")
        try CanonicalJSON.encode(envelope.plan).write(to: planURL)

        let response = router.handle(
            CommandRequest(
                method: "move.apply",
                arguments: ["plan": planURL.path, "digest": envelope.digest]
            )
        )
        let receipt = try response.decodePayload(MoveReceipt.self)

        XCTAssertEqual(receipt.deletedAssetIDs, [asset.id])
        XCTAssertTrue(deleter.presentLocalIdentifiers.isEmpty)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexAppTests-\(name)-\(UUID().uuidString)")
    }
}

private final class RouterFakePhotoLibrary: PhotoLibraryReading, @unchecked Sendable {
    let assetsValue: [PhotoAsset]
    init(assets: [PhotoAsset]) { assetsValue = assets }
    func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }
    func assets(from start: Date, to end: Date) throws -> [PhotoAsset] { assetsValue }
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

private struct RouterAcceptingUploadVerifier: DestinationUploadVerifying {
    func verifyUploaded(urls: [URL]) throws {}
}

private final class RouterRecordingDeleter: PhotoAssetDeleting, @unchecked Sendable {
    private(set) var deletedAssetIDs: [String] = []

    func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        deletedAssetIDs = targets.map(\.id)
        return deletedAssetIDs
    }
}

private enum RouterRecoveryTestError: Error {
    case receiptWriteRejected
    case materializerMustNotRun
}

private struct RouterFailingMaterializer: PhotoAssetMaterializing {
    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        throw RouterRecoveryTestError.materializerMustNotRun
    }
}

private final class RouterStatefulDeleter: PhotoAssetDeleting, @unchecked Sendable {
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

private final class RouterReceiptFailingWriter: ExportWriting, @unchecked Sendable {
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
            throw RouterRecoveryTestError.receiptWriteRejected
        }
        try delegate.write(data, to: url)
    }
}
