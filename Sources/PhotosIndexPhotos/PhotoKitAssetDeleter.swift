import Foundation
import Photos

public enum PhotoKitAssetDeletionError: Error, Equatable, Sendable {
    case sourceCountMismatch(expected: Int, actual: Int)
    case sourceDeletionNotObserved([String])
}

public struct PhotoKitAssetDeleter: PhotoAssetDeleting, Sendable {
    public init() {}

    public func delete(targets: [PhotoDeletionTarget]) throws -> [String] {
        let localIdentifiers = targets.map(\.localIdentifier)
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: localIdentifiers,
            options: nil
        )
        var fetchedLocalIdentifiers = Set<String>()
        fetchResult.enumerateObjects { asset, _, _ in
            fetchedLocalIdentifiers.insert(asset.localIdentifier)
        }
        let present = Self.presentTargets(
            from: targets,
            fetchedLocalIdentifiers: fetchedLocalIdentifiers
        )

        if !present.isEmpty {
            try PHPhotoLibrary.shared().performChangesAndWait {
                PHAssetChangeRequest.deleteAssets(fetchResult)
            }
        }

        let remaining = PHAsset.fetchAssets(
            withLocalIdentifiers: localIdentifiers,
            options: nil
        )
        guard remaining.count == 0 else {
            var remainingIdentifiers: [String] = []
            remaining.enumerateObjects { asset, _, _ in
                remainingIdentifiers.append(asset.localIdentifier)
            }
            let remainingPublicIDs = targets
                .filter { remainingIdentifiers.contains($0.localIdentifier) }
                .map(\.id)
            throw PhotoKitAssetDeletionError.sourceDeletionNotObserved(remainingPublicIDs)
        }
        return targets.map(\.id)
    }

    static func presentTargets(
        from targets: [PhotoDeletionTarget],
        fetchedLocalIdentifiers: Set<String>
    ) -> [PhotoDeletionTarget] {
        targets.filter { fetchedLocalIdentifiers.contains($0.localIdentifier) }
    }
}
