import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

public struct ExportPlanner: ExportPlanning, Sendable {
    public init() {}

    public func makePlan(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset],
        destinationRoot: URL,
        stagingRoot: URL,
        generatedAt: Date = Date(),
        policy: ExportPolicy = ExportPolicy()
    ) throws -> ExportPlan {
        try validate(
            currentIndexRunID: currentIndexRunID,
            decision: decision,
            group: group,
            assets: assets,
            policy: policy
        )

        let assetLookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        let orderedIncluded = group.assetIDs.filter { decision.includedAssetIDs.contains($0) }
        let orderedExcluded = group.assetIDs.filter { decision.excludedAssetIDs.contains($0) }

        guard !orderedIncluded.isEmpty else {
            throw ExportError.emptySelection
        }

        guard orderedIncluded.count == decision.includedAssetIDs.count else {
            throw ExportError.missingAssetIDs(
                Array(Set(decision.includedAssetIDs).subtracting(Set(orderedIncluded))).sorted()
            )
        }

        guard orderedExcluded.count == decision.excludedAssetIDs.count else {
            throw ExportError.outsideGroupAssetIDs(
                Array(Set(decision.excludedAssetIDs).subtracting(Set(orderedExcluded))).sorted()
            )
        }

        let missingSelected = orderedIncluded.filter { assetLookup[$0] == nil }
        guard missingSelected.isEmpty else {
            throw ExportError.missingAssetIDs(missingSelected)
        }

        return ExportPlan(
            indexRunID: decision.indexRunID,
            groupID: group.id,
            generatedAt: generatedAt,
            destinationRoot: destinationRoot.path,
            stagingRoot: stagingRoot.path,
            groupAssetIDs: group.assetIDs,
            includedAssetIDs: orderedIncluded,
            excludedAssetIDs: orderedExcluded,
            label: decision.label,
            confidence: decision.confidence,
            warnings: group.warnings
        )
    }

    private func validate(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset],
        policy: ExportPolicy
    ) throws {
        guard decision.indexRunID == currentIndexRunID else {
            throw ExportError.indexRunMismatch(expected: currentIndexRunID, actual: decision.indexRunID)
        }
        guard decision.groupID == group.id else {
            throw ExportError.groupMismatch(expected: group.id, actual: decision.groupID)
        }
        guard decision.confidence >= policy.minimumConfidence else {
            throw ExportError.lowConfidence(actual: decision.confidence, minimum: policy.minimumConfidence)
        }
        guard policy.allowUnknowns || decision.unknowns.isEmpty else {
            throw ExportError.unknownsNotAllowed(decision.unknowns)
        }

        let groupIDs = group.assetIDs
        let groupSet = Set(groupIDs)
        let included = decision.includedAssetIDs
        let excluded = decision.excludedAssetIDs
        let includedSet = Set(included)
        let excludedSet = Set(excluded)

        guard included.count <= policy.maxSelectedAssets else {
            throw ExportError.selectionLimitExceeded(
                actual: included.count,
                maximum: policy.maxSelectedAssets
            )
        }

        guard included.count == includedSet.count else {
            throw ExportError.duplicateAssetIDs(duplicateIDs(included))
        }
        guard excluded.count == excludedSet.count else {
            throw ExportError.duplicateAssetIDs(duplicateIDs(excluded))
        }
        guard includedSet.isDisjoint(with: excludedSet) else {
            throw ExportError.duplicateAssetIDs(Array(includedSet.intersection(excludedSet)).sorted())
        }

        let partition = includedSet.union(excludedSet)
        if partition != groupSet {
            let missing = Array(groupSet.subtracting(partition)).sorted()
            if !missing.isEmpty {
                throw ExportError.missingAssetIDs(missing)
            }
            let outside = Array(partition.subtracting(groupSet)).sorted()
            if !outside.isEmpty {
                throw ExportError.outsideGroupAssetIDs(outside)
            }
        }

        let knownIDs = Set(assets.map(\.id))
        let unknownSelected = included.filter { !knownIDs.contains($0) }
        guard unknownSelected.isEmpty else {
            throw ExportError.missingAssetIDs(unknownSelected)
        }
    }

    private func duplicateIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var duplicates: [String] = []
        for id in ids {
            if !seen.insert(id).inserted {
                duplicates.append(id)
            }
        }
        return Array(Set(duplicates)).sorted()
    }
}
