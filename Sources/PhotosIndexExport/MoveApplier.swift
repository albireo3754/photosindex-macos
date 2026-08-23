import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

public struct MoveApplier: Sendable {
    private let exporter: ExportApplier
    private let pendingMoveStore: any PendingMoveStoring

    public init(
        exporter: ExportApplier = ExportApplier(),
        pendingMoveStore: any PendingMoveStoring
    ) {
        self.exporter = exporter
        self.pendingMoveStore = pendingMoveStore
    }

    public func canResume(
        plan: MovePlan,
        digest: String,
        fileWriter: any ExportWriting
    ) throws -> Bool {
        try MovePlanIntegrity.verify(plan, digest: digest)
        guard plan.operation == .deleteSourceAfterVerifiedUpload else {
            throw MoveError.unsupportedOperation
        }
        let destinationRoot = URL(
            fileURLWithPath: plan.exportPlan.destinationRoot,
            isDirectory: true
        )
        guard try persistedPlanMatches(
            plan,
            digest: digest,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        ) else {
            if try pendingMoveStore.load(digest: digest) != nil {
                throw MoveError.pendingMoveMismatch
            }
            return false
        }
        if let journal = try pendingMoveStore.load(digest: digest) {
            try validateJournalBasics(journal, plan: plan, digest: digest)
            return true
        }
        let moveReceiptURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "move-receipt.json"
        )
        return fileWriter.fileExists(at: moveReceiptURL)
    }

    public func apply(
        plan: MovePlan,
        assets: [PhotoAsset],
        materializer: any PhotoAssetMaterializing,
        fileWriter: any ExportWriting,
        uploadVerifier: any DestinationUploadVerifying,
        deleter: any PhotoAssetDeleting,
        completedAt: Date = Date()
    ) throws -> MoveReceipt {
        guard plan.operation == .deleteSourceAfterVerifiedUpload else {
            throw MoveError.unsupportedOperation
        }
        let movePlanDigest = try MovePlanIntegrity.sha256(plan)

        let destinationRoot = URL(
            fileURLWithPath: plan.exportPlan.destinationRoot,
            isDirectory: true
        )
        let exportReceipt: ExportReceipt
        if let adopted = try compatibleExistingReceipt(
            for: plan.exportPlan,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        ) {
            exportReceipt = adopted
        } else {
            exportReceipt = try exporter.apply(
                plan: plan.exportPlan,
                assets: assets,
                materializer: materializer,
                fileWriter: fileWriter
            )
            try validateSelection(receipt: exportReceipt, plan: plan.exportPlan)
        }

        let moveReceiptURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "move-receipt.json"
        )
        if fileWriter.fileExists(at: moveReceiptURL) {
            let existing = try CanonicalJSON.decode(
                MoveReceipt.self,
                from: fileWriter.contents(at: moveReceiptURL)
            )
            guard existing.exportReceipt == exportReceipt,
                  sameIDs(existing.deletedAssetIDs, plan.exportPlan.includedAssetIDs)
            else {
                throw MoveError.existingReceiptMismatch
            }
            _ = try verifiedDestinationURLs(
                receipt: existing.exportReceipt,
                destinationRoot: destinationRoot,
                fileWriter: fileWriter
            )
            try pendingMoveStore.remove(digest: movePlanDigest)
            return existing
        }

        let destinationURLs = try verifiedDestinationURLs(
            receipt: exportReceipt,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        )
        try uploadVerifier.verifyUploaded(urls: destinationURLs)
        _ = try verifiedDestinationURLs(
            receipt: exportReceipt,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        )

        let movePlanURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "move-plan-\(movePlanDigest).json"
        )
        try ExportSupport.writeCanonicalJSON(plan, to: movePlanURL, fileWriter: fileWriter)

        let deletionTargets: [PhotoDeletionTarget]
        if let journal = try pendingMoveStore.load(digest: movePlanDigest) {
            try validateJournal(
                journal,
                plan: plan,
                digest: movePlanDigest,
                exportReceipt: exportReceipt
            )
            deletionTargets = journal.deletionTargets
        } else {
            let assetLookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
            let missing = plan.exportPlan.includedAssetIDs.filter { assetLookup[$0] == nil }
            guard missing.isEmpty else { throw MoveError.missingSourceAssets(missing) }
            deletionTargets = plan.exportPlan.includedAssetIDs.compactMap {
                assetLookup[$0]?.deletionTarget
            }
            let journal = PendingMoveJournal(
                digest: movePlanDigest,
                plan: plan,
                exportReceipt: exportReceipt,
                deletionTargets: deletionTargets
            )
            try pendingMoveStore.save(journal)
        }

        let deletedIDs = try deleter.delete(targets: deletionTargets)
        guard sameIDs(deletedIDs, plan.exportPlan.includedAssetIDs) else {
            throw MoveError.sourceDeletionMismatch
        }

        let moveReceipt = MoveReceipt(
            exportReceipt: exportReceipt,
            deletedAssetIDs: plan.exportPlan.includedAssetIDs,
            completedAt: completedAt,
            warnings: exportReceipt.warnings
        )
        try ExportSupport.writeCanonicalJSON(
            moveReceipt,
            to: moveReceiptURL,
            fileWriter: fileWriter
        )
        try pendingMoveStore.remove(digest: movePlanDigest)
        return moveReceipt
    }

    private func persistedPlanMatches(
        _ plan: MovePlan,
        digest: String,
        destinationRoot: URL,
        fileWriter: any ExportWriting
    ) throws -> Bool {
        let movePlanURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "move-plan-\(digest).json"
        )
        guard fileWriter.fileExists(at: movePlanURL) else { return false }
        let persisted = try CanonicalJSON.decode(
            MovePlan.self,
            from: fileWriter.contents(at: movePlanURL)
        )
        guard persisted == plan else { throw MoveError.pendingMoveMismatch }
        return true
    }

    private func validateJournal(
        _ journal: PendingMoveJournal,
        plan: MovePlan,
        digest: String,
        exportReceipt: ExportReceipt
    ) throws {
        try validateJournalBasics(journal, plan: plan, digest: digest)
        guard journal.exportReceipt == exportReceipt else {
            throw MoveError.pendingMoveMismatch
        }
    }

    private func validateJournalBasics(
        _ journal: PendingMoveJournal,
        plan: MovePlan,
        digest: String
    ) throws {
        let targetIDs = journal.deletionTargets.map(\.id)
        let localIdentifiers = journal.deletionTargets.map(\.localIdentifier)
        let targetsAreAuthentic = journal.deletionTargets.allSatisfy {
            PhotoAssetMapper.publicID(for: $0.localIdentifier) == $0.id
        }
        guard journal.schemaVersion == 1,
              journal.digest == digest,
              journal.plan == plan,
              sameIDs(targetIDs, plan.exportPlan.includedAssetIDs),
              Set(localIdentifiers).count == localIdentifiers.count,
              targetsAreAuthentic
        else {
            throw MoveError.pendingMoveMismatch
        }
    }

    private func compatibleExistingReceipt(
        for plan: ExportPlan,
        destinationRoot: URL,
        fileWriter: any ExportWriting
    ) throws -> ExportReceipt? {
        let manifestURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "manifest.json"
        )
        let receiptURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "receipt.json"
        )
        let hasManifest = fileWriter.fileExists(at: manifestURL)
        let hasReceipt = fileWriter.fileExists(at: receiptURL)
        guard hasManifest || hasReceipt else { return nil }
        guard hasManifest, hasReceipt else {
            throw MoveError.existingReceiptMismatch
        }

        let existingPlan = try CanonicalJSON.decode(
            ExportPlan.self,
            from: fileWriter.contents(at: manifestURL)
        )
        let receipt = try CanonicalJSON.decode(
            ExportReceipt.self,
            from: fileWriter.contents(at: receiptURL)
        )
        guard existingPlan.schemaVersion == plan.schemaVersion,
              existingPlan.groupID == plan.groupID,
              existingPlan.destinationRoot == plan.destinationRoot,
              existingPlan.label == plan.label,
              sameIDs(existingPlan.groupAssetIDs, plan.groupAssetIDs),
              sameIDs(existingPlan.includedAssetIDs, plan.includedAssetIDs),
              sameIDs(existingPlan.excludedAssetIDs, plan.excludedAssetIDs),
              receipt.indexRunID == existingPlan.indexRunID,
              receipt.groupID == existingPlan.groupID,
              receipt.generatedAt == existingPlan.generatedAt,
              receipt.destinationRoot == existingPlan.destinationRoot,
              receipt.stagingRoot == existingPlan.stagingRoot,
              sameIDs(receipt.entries.map(\.assetID), existingPlan.includedAssetIDs)
        else {
            throw MoveError.existingReceiptMismatch
        }
        _ = try verifiedDestinationURLs(
            receipt: receipt,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        )
        return receipt
    }

    private func validateSelection(receipt: ExportReceipt, plan: ExportPlan) throws {
        guard receipt.indexRunID == plan.indexRunID,
              receipt.groupID == plan.groupID,
              sameIDs(receipt.entries.map(\.assetID), plan.includedAssetIDs)
        else {
            throw MoveError.receiptSelectionMismatch
        }
    }

    private func verifiedDestinationURLs(
        receipt: ExportReceipt,
        destinationRoot: URL,
        fileWriter: any ExportWriting
    ) throws -> [URL] {
        let originalsRoot = destinationRoot.appendingPathComponent("originals", isDirectory: true)
        try ExportSupport.validateRoot(originalsRoot)
        return try receipt.entries.map { entry in
            guard entry.relativePath == "originals/\(entry.safeFilename)" else {
                throw MoveError.destinationMismatch
            }
            let url = try ExportSupport.validatedChildURL(
                root: originalsRoot,
                childName: entry.safeFilename
            )
            guard fileWriter.fileExists(at: url),
                  try ExportSupport.byteCount(of: url, fileWriter: fileWriter) == entry.bytes,
                  try ExportSupport.sha256Hex(ofFile: url, fileWriter: fileWriter) == entry.sha256
            else {
                throw MoveError.destinationMismatch
            }
            return url
        }
    }

    private func sameIDs(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && Set(lhs) == Set(rhs)
    }
}

public enum ICloudUploadVerificationError: Error, Equatable, Sendable {
    case notUbiquitous(String)
    case uploadFailed(String)
    case timedOut
}

struct ICloudItemUploadState: Equatable, Sendable {
    let path: String
    let isUbiquitous: Bool
    let isUploaded: Bool
    let isUploading: Bool
    let isCurrent: Bool
    let uploadErrorDescription: String?
}

enum ICloudUploadPollDecision: Equatable, Sendable {
    case complete
    case pending(lastUploadError: String?)
    case failed(ICloudUploadVerificationError)
}

public struct ICloudDestinationUploadVerifier: DestinationUploadVerifying, Sendable {
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(timeout: TimeInterval = 900, pollInterval: TimeInterval = 2) {
        self.timeout = max(1, timeout)
        self.pollInterval = max(0.1, pollInterval)
    }

    public func verifyUploaded(urls: [URL]) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let states = try urls.map { url in
                var refreshedURL = URL(fileURLWithPath: url.path)
                refreshedURL.removeAllCachedResourceValues()
                let values = try refreshedURL.resourceValues(forKeys: [
                    .isUbiquitousItemKey,
                    .ubiquitousItemIsUploadedKey,
                    .ubiquitousItemIsUploadingKey,
                    .ubiquitousItemUploadingErrorKey,
                    .ubiquitousItemDownloadingStatusKey,
                ])
                return ICloudItemUploadState(
                    path: url.path,
                    isUbiquitous: values.isUbiquitousItem == true,
                    isUploaded: values.ubiquitousItemIsUploaded == true,
                    isUploading: values.ubiquitousItemIsUploading == true,
                    isCurrent: values.ubiquitousItemDownloadingStatus == .current,
                    uploadErrorDescription: values.ubiquitousItemUploadingError?.localizedDescription
                )
            }
            switch Self.evaluate(states: states, deadlineReached: Date() >= deadline) {
            case .complete:
                return
            case .pending:
                Thread.sleep(forTimeInterval: pollInterval)
            case let .failed(error):
                throw error
            }
        }
    }

    static func evaluate(
        states: [ICloudItemUploadState],
        deadlineReached: Bool
    ) -> ICloudUploadPollDecision {
        if let nonUbiquitous = states.first(where: { !$0.isUbiquitous }) {
            return .failed(.notUbiquitous(nonUbiquitous.path))
        }
        let uploadError = states.compactMap(\.uploadErrorDescription).first
        let allUploaded = states.allSatisfy {
            $0.isUploaded && !$0.isUploading && $0.isCurrent
                && $0.uploadErrorDescription == nil
        }
        if allUploaded {
            return .complete
        }
        if deadlineReached {
            if let uploadError {
                return .failed(.uploadFailed(uploadError))
            }
            return .failed(.timedOut)
        }
        return .pending(lastUploadError: uploadError)
    }
}
