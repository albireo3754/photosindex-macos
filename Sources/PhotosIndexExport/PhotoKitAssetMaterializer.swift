import CryptoKit
import Foundation
import Photos
import PhotosIndexCore
import PhotosIndexPhotos

public enum PhotoKitAssetMaterializerError: Error, Equatable {
    case requestTimedOut
    case outputCreationFailed
}

public final class PhotoKitAssetMaterializer: PhotoAssetMaterializing, @unchecked Sendable {
    private let fileWriter: any ExportWriting
    private let requestTimeout: TimeInterval

    public init(
        fileWriter: any ExportWriting = FileManagerExportWriter(),
        requestTimeout: TimeInterval = 300
    ) {
        self.fileWriter = fileWriter
        self.requestTimeout = max(1, requestTimeout)
    }

    public func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset {
        try ExportSupport.validateRoot(stagingRoot)
        try fileWriter.createDirectory(at: stagingRoot)

        let safeFilename = ExportSupport.safeFilename(for: asset)
        let stageURL = try ExportSupport.validatedChildURL(root: stagingRoot, childName: safeFilename)
        if fileWriter.fileExists(at: stageURL) {
            try fileWriter.removeItem(at: stageURL)
        }

        let phAsset = try fetchAsset(identifier: asset.localIdentifier)
        let resource = try resolvePrimaryResource(for: phAsset, mediaKind: asset.mediaKind)
        try write(resource: resource, to: stageURL)

        let bytes = try ExportSupport.byteCount(of: stageURL, fileWriter: fileWriter)
        let sha256 = try ExportSupport.sha256Hex(ofFile: stageURL, fileWriter: fileWriter)
        return StagedExportAsset(
            assetID: asset.id,
            mediaKind: asset.mediaKind,
            safeFilename: safeFilename,
            stagedURL: stageURL,
            bytes: bytes,
            sha256: sha256
        )
    }

    private func fetchAsset(identifier: String) throws -> PHAsset {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else {
            throw CocoaError(.fileNoSuchFile)
        }
        return asset
    }

    private func resolvePrimaryResource(for asset: PHAsset, mediaKind: MediaKind) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType]
        switch mediaKind {
        case .video:
            preferredTypes = [.video, .pairedVideo, .fullSizeVideo]
        case .photo:
            preferredTypes = [.photo, .fullSizePhoto]
        }
        if let selected = preferredTypes.lazy.compactMap({ kind in
            resources.first { $0.type == kind }
        }).first {
            return selected
        }
        guard let fallback = resources.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return fallback
    }

    private func write(resource: PHAssetResource, to destination: URL) throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let semaphore = DispatchSemaphore(value: 0)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw PhotoKitAssetMaterializerError.outputCreationFailed
        }
        let fileHandle = try FileHandle(forWritingTo: destination)
        let state = ResourceWriteState(fileHandle: fileHandle, semaphore: semaphore)
        let manager = PHAssetResourceManager.default()
        let requestID = manager.requestData(
            for: resource,
            options: options
        ) { data in
            state.append(data)
        } completionHandler: { error in
            state.finish(error: error)
        }
        if semaphore.wait(timeout: .now() + requestTimeout) == .timedOut {
            manager.cancelDataRequest(requestID)
            state.finish(error: PhotoKitAssetMaterializerError.requestTimedOut)
        }
        if let error = state.error {
            throw error
        }
    }
}

private final class ResourceWriteState: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let semaphore: DispatchSemaphore
    private var finished = false
    private var storedError: Error?

    init(fileHandle: FileHandle, semaphore: DispatchSemaphore) {
        self.fileHandle = fileHandle
        self.semaphore = semaphore
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, storedError == nil else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            storedError = error
        }
    }

    func finish(error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if storedError == nil {
            storedError = error
        }
        do {
            try fileHandle.close()
        } catch where storedError == nil {
            storedError = error
        } catch {}
        lock.unlock()
        semaphore.signal()
    }
}
