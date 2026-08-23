import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

public struct ExportApplier: ExportApplying, Sendable {
    public let policy: ExportPolicy

    public init(policy: ExportPolicy = ExportPolicy()) {
        self.policy = policy
    }

    public func apply(
        plan: ExportPlan,
        assets: [PhotoAsset],
        materializer: any PhotoAssetMaterializing,
        fileWriter: any ExportWriting
    ) throws -> ExportReceipt {
        let stagingRoot = URL(fileURLWithPath: plan.stagingRoot, isDirectory: true)
        let destinationRoot = URL(fileURLWithPath: plan.destinationRoot, isDirectory: true)

        try ExportSupport.validateRoot(stagingRoot)
        try ExportSupport.validateRoot(destinationRoot)
        try fileWriter.createDirectory(at: destinationRoot)
        if let existing = try existingReceipt(
            for: plan,
            destinationRoot: destinationRoot,
            fileWriter: fileWriter
        ) {
            try removeStagingRootIfPresent(stagingRoot, fileWriter: fileWriter)
            return existing
        }
        try fileWriter.createDirectory(at: stagingRoot)
        let originalsRoot = destinationRoot.appendingPathComponent("originals", isDirectory: true)
        try ExportSupport.validateRoot(originalsRoot)
        try fileWriter.createDirectory(at: originalsRoot)

        let assetLookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var staged: [StagedExportAsset] = []
        staged.reserveCapacity(plan.includedAssetIDs.count)

        for assetID in plan.includedAssetIDs {
            guard let asset = assetLookup[assetID] else {
                throw ExportError.missingAssetIDs([assetID])
            }
            let stagedAsset = try materializer.stage(asset: asset, into: stagingRoot)
            try validateStage(stagedAsset, under: stagingRoot)
            staged.append(stagedAsset)
        }

        var entries: [ExportReceiptEntry] = []
        entries.reserveCapacity(staged.count)
        for stagedAsset in staged {
            let finalURL = try ExportSupport.validatedChildURL(
                root: originalsRoot,
                childName: stagedAsset.safeFilename
            )
            let reused: Bool
            if fileWriter.fileExists(at: finalURL) {
                let existingBytes = try ExportSupport.byteCount(of: finalURL, fileWriter: fileWriter)
                let existingHash = try ExportSupport.sha256Hex(ofFile: finalURL, fileWriter: fileWriter)
                guard existingBytes == stagedAsset.bytes, existingHash == stagedAsset.sha256 else {
                    throw ExportError.collision(path: finalURL.path)
                }
                reused = true
            } else {
                try fileWriter.copyItem(at: stagedAsset.stagedURL, to: finalURL)
                reused = false
            }

            let bytes = try ExportSupport.byteCount(of: finalURL, fileWriter: fileWriter)
            let sha256 = try ExportSupport.sha256Hex(ofFile: finalURL, fileWriter: fileWriter)
            guard bytes == stagedAsset.bytes, sha256 == stagedAsset.sha256 else {
                throw ExportError.collision(path: finalURL.path)
            }

            entries.append(
                ExportReceiptEntry(
                    assetID: stagedAsset.assetID,
                    safeFilename: stagedAsset.safeFilename,
                    mediaKind: stagedAsset.mediaKind,
                    bytes: bytes,
                    sha256: sha256,
                    relativePath: "originals/\(stagedAsset.safeFilename)",
                    reused: reused
                )
            )
        }

        let receipt = ExportReceipt(
            indexRunID: plan.indexRunID,
            groupID: plan.groupID,
            generatedAt: plan.generatedAt,
            destinationRoot: plan.destinationRoot,
            stagingRoot: plan.stagingRoot,
            entries: entries.sorted(by: { $0.relativePath < $1.relativePath }),
            warnings: plan.warnings
        )

        let manifestURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "manifest.json"
        )
        let receiptURL = try ExportSupport.validatedChildURL(
            root: destinationRoot,
            childName: "receipt.json"
        )
        try ExportSupport.writeCanonicalJSON(plan, to: manifestURL, fileWriter: fileWriter)
        try ExportSupport.writeCanonicalJSON(receipt, to: receiptURL, fileWriter: fileWriter)
        try removeStagingRootIfPresent(stagingRoot, fileWriter: fileWriter)

        return receipt
    }

    private func existingReceipt(
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
            throw ExportError.collision(path: hasManifest ? manifestURL.path : receiptURL.path)
        }

        let existingPlan = try CanonicalJSON.decode(
            ExportPlan.self,
            from: fileWriter.contents(at: manifestURL)
        )
        guard existingPlan == plan else {
            throw ExportError.collision(path: manifestURL.path)
        }
        let receipt = try CanonicalJSON.decode(
            ExportReceipt.self,
            from: fileWriter.contents(at: receiptURL)
        )
        guard receipt.indexRunID == plan.indexRunID,
              receipt.groupID == plan.groupID,
              Set(receipt.entries.map(\.assetID)) == Set(plan.includedAssetIDs),
              receipt.entries.count == plan.includedAssetIDs.count
        else {
            throw ExportError.collision(path: receiptURL.path)
        }
        for entry in receipt.entries {
            guard entry.relativePath == "originals/\(entry.safeFilename)" else {
                throw ExportError.unsafePath(entry.relativePath)
            }
            let originalsRoot = destinationRoot.appendingPathComponent("originals", isDirectory: true)
            try ExportSupport.validateRoot(originalsRoot)
            let fileURL = try ExportSupport.validatedChildURL(
                root: originalsRoot,
                childName: entry.safeFilename
            )
            guard fileWriter.fileExists(at: fileURL),
                  try ExportSupport.byteCount(of: fileURL, fileWriter: fileWriter) == entry.bytes,
                  try ExportSupport.sha256Hex(ofFile: fileURL, fileWriter: fileWriter) == entry.sha256
            else {
                throw ExportError.collision(path: fileURL.path)
            }
        }
        return receipt
    }

    private func removeStagingRootIfPresent(
        _ stagingRoot: URL,
        fileWriter: any ExportWriting
    ) throws {
        if fileWriter.fileExists(at: stagingRoot) {
            try fileWriter.removeItem(at: stagingRoot)
        }
    }

    private func validateStage(_ staged: StagedExportAsset, under root: URL) throws {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedStage = staged.stagedURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedStage.hasPrefix(resolvedRoot + "/") || resolvedStage == resolvedRoot else {
            throw ExportError.unsafePath(staged.stagedURL.path)
        }
    }
}
