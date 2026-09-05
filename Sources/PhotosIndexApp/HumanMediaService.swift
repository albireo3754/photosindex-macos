import AppKit
import AVFoundation
import PhotosIndexPhotos

@MainActor
protocol HumanMediaServing {
    func image(assetID: String, groupID: String, expectedRunID: String, targetSize: CGSize) async throws -> NSImage
    func playerItem(assetID: String, groupID: String, expectedRunID: String) async throws -> AVPlayerItem
}

@MainActor
final class HumanMediaService: HumanMediaServing {
    private let runtime: IndexRuntime
    private let provider: any PhotoMediaProviding

    init(runtime: IndexRuntime, provider: any PhotoMediaProviding) {
        self.runtime = runtime
        self.provider = provider
    }

    func image(
        assetID: String, groupID: String, expectedRunID: String, targetSize: CGSize
    ) async throws -> NSImage {
        let asset = try resolve(assetID: assetID, groupID: groupID, expectedRunID: expectedRunID)
        let image = try await provider.image(localIdentifier: asset.localIdentifier, targetSize: targetSize)
        _ = try resolve(assetID: assetID, groupID: groupID, expectedRunID: expectedRunID)
        return image
    }

    func playerItem(assetID: String, groupID: String, expectedRunID: String) async throws -> AVPlayerItem {
        let asset = try resolve(assetID: assetID, groupID: groupID, expectedRunID: expectedRunID)
        guard asset.mediaKind == .video else { throw PhotoKitMediaError.unsupportedMediaType }
        let item = try await provider.playerItem(localIdentifier: asset.localIdentifier)
        _ = try resolve(assetID: assetID, groupID: groupID, expectedRunID: expectedRunID)
        return item
    }

    private func resolve(assetID: String, groupID: String, expectedRunID: String) throws -> PhotoAsset {
        try Task.checkCancellation()
        guard let asset = try runtime.asset(id: assetID, groupID: groupID, expectedRunID: expectedRunID) else {
            throw PhotoKitMediaError.assetUnavailable
        }
        return asset
    }
}
