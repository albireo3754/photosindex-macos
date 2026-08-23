import Foundation
import PhotosIndexCore
import PhotosIndexExport
import PhotosIndexPhotos

enum ExportCommandServiceError: Error, Equatable {
    case destinationRootMismatch
    case unsafeLabel
    case planDoesNotMatchCurrentIndex
    case unissuedPlanDigest
}

final class ExportCommandService: @unchecked Sendable {
    private let allowedRoot: URL
    private let materializer: any PhotoAssetMaterializing
    private let fileWriter: any ExportWriting
    private let temporaryRoot: URL
    private let uploadVerifier: any DestinationUploadVerifying
    private let deleter: any PhotoAssetDeleting
    private let planner = ExportPlanner()
    private let applier = ExportApplier()
    private let moveApplier: MoveApplier
    private let lock = NSLock()
    private let moveLock = NSLock()
    private var issuedDigests: Set<String> = []
    private var issuedMoveDigests: Set<String> = []

    init(
        allowedRoot: URL,
        materializer: any PhotoAssetMaterializing = PhotoKitAssetMaterializer(),
        fileWriter: any ExportWriting = FileManagerExportWriter(),
        temporaryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndex", isDirectory: true),
        uploadVerifier: any DestinationUploadVerifying = ICloudDestinationUploadVerifier(),
        deleter: any PhotoAssetDeleting = PhotoKitAssetDeleter(),
        pendingMoveStore: (any PendingMoveStoring)? = nil
    ) {
        self.allowedRoot = allowedRoot.standardizedFileURL
        self.materializer = materializer
        self.fileWriter = fileWriter
        self.temporaryRoot = temporaryRoot.standardizedFileURL
        self.uploadVerifier = uploadVerifier
        self.deleter = deleter
        let store = pendingMoveStore ?? FilePendingMoveStore(
            root: temporaryRoot.appendingPathComponent("pending-moves", isDirectory: true)
        )
        moveApplier = MoveApplier(pendingMoveStore: store)
    }

    func validate(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset]
    ) throws -> DecisionValidationPayload {
        _ = try planner.makePlan(
            currentIndexRunID: currentIndexRunID,
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: allowedRoot.appendingPathComponent("validation", isDirectory: true),
            stagingRoot: temporaryRoot.appendingPathComponent("validation", isDirectory: true),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        return DecisionValidationPayload(
            indexRunID: decision.indexRunID,
            groupID: decision.groupID,
            includedAssetCount: decision.includedAssetIDs.count,
            excludedAssetCount: decision.excludedAssetIDs.count
        )
    }

    func makePlan(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset],
        requestedRoot: URL,
        generatedAt: Date = Date()
    ) throws -> ExportPlanEnvelope {
        guard samePath(requestedRoot, allowedRoot) else {
            throw ExportCommandServiceError.destinationRootMismatch
        }
        let label = try safeLabel(decision.label)
        let destination = allowedRoot.appendingPathComponent(
            "\(group.localDate)_\(label)",
            isDirectory: true
        )
        let staging = temporaryRoot
            .appendingPathComponent(safePathComponent(currentIndexRunID), isDirectory: true)
            .appendingPathComponent(safePathComponent(group.id), isDirectory: true)
        let plan = try planner.makePlan(
            currentIndexRunID: currentIndexRunID,
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: destination,
            stagingRoot: staging,
            generatedAt: generatedAt
        )
        let digest = try ExportPlanIntegrity.sha256(plan)
        lock.lock()
        issuedDigests.insert(digest)
        lock.unlock()
        return ExportPlanEnvelope(plan: plan, digest: digest)
    }

    func apply(
        _ plan: ExportPlan,
        digest: String,
        currentIndexRunID: String,
        group: CaptureGroup,
        assets: [PhotoAsset]
    ) throws -> ExportReceipt {
        try ExportPlanIntegrity.verify(plan, digest: digest)
        lock.lock()
        let wasIssued = issuedDigests.contains(digest)
        lock.unlock()
        guard wasIssued else { throw ExportCommandServiceError.unissuedPlanDigest }
        try validatePlan(
            plan,
            currentIndexRunID: currentIndexRunID,
            group: group,
            assets: assets,
            digestReference: digest
        )
        return try applier.apply(
            plan: plan,
            assets: assets,
            materializer: materializer,
            fileWriter: fileWriter
        )
    }

    func makeMovePlan(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset],
        requestedRoot: URL,
        generatedAt: Date = Date()
    ) throws -> MovePlanEnvelope {
        let exportEnvelope = try makePlan(
            currentIndexRunID: currentIndexRunID,
            decision: decision,
            group: group,
            assets: assets,
            requestedRoot: requestedRoot,
            generatedAt: generatedAt
        )
        let plan = MovePlan(
            exportPlan: exportEnvelope.plan,
            operation: .deleteSourceAfterVerifiedUpload
        )
        let digest = try MovePlanIntegrity.sha256(plan)
        lock.lock()
        issuedMoveDigests.insert(digest)
        lock.unlock()
        return MovePlanEnvelope(plan: plan, digest: digest)
    }

    func applyMove(
        _ plan: MovePlan,
        digest: String,
        currentIndexRunID: String,
        group: CaptureGroup,
        assets: [PhotoAsset],
        completedAt: Date = Date()
    ) throws -> MoveReceipt {
        moveLock.lock()
        defer { moveLock.unlock() }
        try MovePlanIntegrity.verify(plan, digest: digest)
        lock.lock()
        let wasIssued = issuedMoveDigests.contains(digest)
        lock.unlock()
        guard wasIssued else { throw ExportCommandServiceError.unissuedPlanDigest }
        try validatePlan(
            plan.exportPlan,
            currentIndexRunID: currentIndexRunID,
            group: group,
            assets: assets,
            digestReference: digest
        )
        return try moveApplier.apply(
            plan: plan,
            assets: assets,
            materializer: materializer,
            fileWriter: fileWriter,
            uploadVerifier: uploadVerifier,
            deleter: deleter,
            completedAt: completedAt
        )
    }

    func resumeMoveIfNeeded(
        _ plan: MovePlan,
        digest: String,
        completedAt: Date = Date()
    ) throws -> MoveReceipt? {
        moveLock.lock()
        defer { moveLock.unlock() }
        try MovePlanIntegrity.verify(plan, digest: digest)
        guard try moveApplier.canResume(
            plan: plan,
            digest: digest,
            fileWriter: fileWriter
        ) else {
            return nil
        }
        try validateRecoveryDestination(plan.exportPlan)
        return try moveApplier.apply(
            plan: plan,
            assets: [],
            materializer: materializer,
            fileWriter: fileWriter,
            uploadVerifier: uploadVerifier,
            deleter: deleter,
            completedAt: completedAt
        )
    }

    private func validatePlan(
        _ plan: ExportPlan,
        currentIndexRunID: String,
        group: CaptureGroup,
        assets: [PhotoAsset],
        digestReference: String
    ) throws {
        guard plan.indexRunID == currentIndexRunID,
              plan.groupID == group.id,
              plan.groupAssetIDs == group.assetIDs
        else {
            throw ExportCommandServiceError.planDoesNotMatchCurrentIndex
        }

        let expectedDestination = allowedRoot.appendingPathComponent(
            "\(group.localDate)_\(try safeLabel(plan.label))",
            isDirectory: true
        )
        let expectedStaging = temporaryRoot
            .appendingPathComponent(safePathComponent(currentIndexRunID), isDirectory: true)
            .appendingPathComponent(safePathComponent(group.id), isDirectory: true)
        guard samePath(URL(fileURLWithPath: plan.destinationRoot), expectedDestination),
              samePath(URL(fileURLWithPath: plan.stagingRoot), expectedStaging)
        else {
            throw ExportCommandServiceError.planDoesNotMatchCurrentIndex
        }

        let reconstructed = try ModelDecision(
            schemaVersion: 1,
            indexRunID: plan.indexRunID,
            groupID: plan.groupID,
            label: plan.label,
            confidence: plan.confidence,
            includedAssetIDs: plan.includedAssetIDs,
            excludedAssetIDs: plan.excludedAssetIDs,
            evidenceReferences: ["digest:\(digestReference)"],
            unknowns: []
        )
        let expectedPlan = try planner.makePlan(
            currentIndexRunID: currentIndexRunID,
            decision: reconstructed,
            group: group,
            assets: assets,
            destinationRoot: expectedDestination,
            stagingRoot: expectedStaging,
            generatedAt: plan.generatedAt
        )
        guard expectedPlan == plan else {
            throw ExportCommandServiceError.planDoesNotMatchCurrentIndex
        }
    }

    private func validateRecoveryDestination(_ plan: ExportPlan) throws {
        let destination = URL(
            fileURLWithPath: plan.destinationRoot,
            isDirectory: true
        ).standardizedFileURL
        guard samePath(destination.deletingLastPathComponent(), allowedRoot) else {
            throw ExportCommandServiceError.destinationRootMismatch
        }
        let label = try safeLabel(plan.label)
        let expectedSuffix = "_\(label)"
        let datePrefix = String(destination.lastPathComponent.prefix(10))
        guard destination.lastPathComponent.hasSuffix(expectedSuffix),
              datePrefix.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                options: .regularExpression
              ) != nil
        else {
            throw ExportCommandServiceError.planDoesNotMatchCurrentIndex
        }
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
            && lhs.resolvingSymlinksInPath().standardizedFileURL.path
                == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func safeLabel(_ label: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = label.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = mapped.replacingOccurrences(
            of: #"-+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-_. "))
        guard !collapsed.isEmpty, collapsed != ".", collapsed != ".." else {
            throw ExportCommandServiceError.unsafeLabel
        }
        return collapsed
    }

    private func safePathComponent(_ value: String) -> String {
        value.unicodeScalars.map {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
                .contains($0) ? String($0) : "_"
        }.joined()
    }
}
