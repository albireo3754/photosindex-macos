import AppKit
import AVFoundation
import Photos

@MainActor
public protocol PhotoMediaProviding {
    func image(localIdentifier: String, targetSize: CGSize) async throws -> NSImage
    func playerItem(localIdentifier: String) async throws -> AVPlayerItem
}

public enum PhotoKitMediaError: Error, Equatable, Sendable {
    case authorizationRequired
    case assetUnavailable
    case unsupportedMediaType
    case invalidTargetSize
    case imageUnavailable
    case videoUnavailable
    case requestFailed
    case cancelled
}

@MainActor
public final class PhotoKitMediaProvider: PhotoMediaProviding {
    public init() {}

    public func image(localIdentifier: String, targetSize: CGSize) async throws -> NSImage {
        let size = try Self.boundedTargetSize(targetSize)
        let asset = try fetchAsset(localIdentifier: localIdentifier)
        guard asset.mediaType == .image || asset.mediaType == .video else {
            throw PhotoKitMediaError.unsupportedMediaType
        }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let result = try await PhotoKitMediaRequest<PhotoKitImage>.value { request in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFit, options: options
            ) { @Sendable image, info in
                request.receive(image.map(PhotoKitImage.init), info: info, unavailable: .imageUnavailable)
            }
        } cancel: { requestID in
            PHImageManager.default().cancelImageRequest(requestID)
        }
        _ = try fetchAsset(localIdentifier: localIdentifier)
        return result.image
    }

    public func playerItem(localIdentifier: String) async throws -> AVPlayerItem {
        let asset = try fetchAsset(localIdentifier: localIdentifier)
        guard asset.mediaType == .video else {
            throw PhotoKitMediaError.unsupportedMediaType
        }
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let item = try await PhotoKitMediaRequest<AVPlayerItem>.value { request in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) {
                @Sendable item, info in
                request.receive(item, info: info, unavailable: .videoUnavailable)
            }
        } cancel: { requestID in
            PHImageManager.default().cancelImageRequest(requestID)
        }
        _ = try fetchAsset(localIdentifier: localIdentifier)
        return item
    }

    private func fetchAsset(localIdentifier: String) throws -> PHAsset {
        guard !Task.isCancelled else { throw PhotoKitMediaError.cancelled }
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoKitMediaError.authorizationRequired
        }
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: options)
        guard result.count == 1, let asset = result.firstObject,
              asset.localIdentifier == localIdentifier, !asset.isHidden else {
            throw PhotoKitMediaError.assetUnavailable
        }
        return asset
    }

    static func boundedTargetSize(_ size: CGSize) throws -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            throw PhotoKitMediaError.invalidTargetSize
        }
        let scale = min(1, 4096 / max(size.width, size.height))
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}

// PhotoKit's image is handed to the main actor without reading or mutating it
// on the callback queue. Only the main-actor consumer may use the image.
private struct PhotoKitImage: @unchecked Sendable {
    let image: NSImage
}

// The lock protects only request state. Never call PhotoKit or resume while locked:
// cancellation can synchronously reenter through a result callback.
final class PhotoKitMediaRequest<Value>: @unchecked Sendable {
    private enum State { case pending, completed, cancelled }
    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?

    @MainActor
    static func value(
        start: (PhotoKitMediaRequest<Value>) -> PHImageRequestID,
        cancel: @escaping @Sendable (PHImageRequestID) -> Void
    ) async throws -> Value {
        let request = PhotoKitMediaRequest<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = start(request)
                request.registerCancellation { cancel(requestID) }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if state == .cancelled {
            lock.unlock()
            continuation.resume(throwing: PhotoKitMediaError.cancelled)
            return false
        }
        precondition(state == .pending && self.continuation == nil)
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func registerCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        let mustCancel = state == .cancelled
        if state == .pending { cancellation = action }
        lock.unlock()
        if mustCancel { action() }
    }

    func receive(
        _ value: sending Value?, info: [AnyHashable: Any]?, unavailable: PhotoKitMediaError
    ) {
        if (info?[PHImageCancelledKey] as? Bool) == true {
            cancel()
        } else if info?[PHImageErrorKey] != nil {
            complete(.failure(PhotoKitMediaError.requestFailed))
        } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
            if let value {
                complete(.success(value))
            } else {
                complete(.failure(unavailable))
            }
        }
    }

    func complete(_ result: sending Result<Value, Error>) {
        lock.lock()
        guard state == .pending, let continuation else {
            lock.unlock()
            return
        }
        state = .completed
        self.continuation = nil
        cancellation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func cancel() {
        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return
        }
        state = .cancelled
        let continuation = continuation
        let cancellation = cancellation
        self.continuation = nil
        self.cancellation = nil
        lock.unlock()
        cancellation?()
        continuation?.resume(throwing: PhotoKitMediaError.cancelled)
    }
}
