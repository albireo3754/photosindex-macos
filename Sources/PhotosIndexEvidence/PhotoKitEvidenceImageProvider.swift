import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Photos

public enum PhotoKitEvidenceImageProviderError: Error, Equatable {
    case assetNotFound
    case imageUnavailable
    case videoUnavailable
    case jpegEncodingFailed
    case requestTimedOut
}

public final class PhotoKitEvidenceImageProvider: EvidenceImageProviding, @unchecked Sendable {
    private let maximumPixelDimension: Int
    private let jpegQuality: Double
    private let requestTimeout: TimeInterval

    public init(
        maximumPixelDimension: Int = 1024,
        jpegQuality: Double = 0.82,
        requestTimeout: TimeInterval = 120
    ) {
        self.maximumPixelDimension = max(1, maximumPixelDimension)
        self.jpegQuality = min(1, max(0, jpegQuality))
        self.requestTimeout = max(1, requestTimeout)
    }

    public func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data {
        guard let phAsset = PHAsset.fetchAssets(
            withLocalIdentifiers: [asset.sourceIdentifier],
            options: nil
        ).firstObject else {
            throw PhotoKitEvidenceImageProviderError.assetNotFound
        }
        let previewData = try await previewImageData(for: phAsset)
        return try thumbnailJPEG(from: previewData)
    }

    private func previewImageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PhotoContinuationGate(continuation)
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.version = .current
            let requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(
                    width: maximumPixelDimension,
                    height: maximumPixelDimension
                ),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    gate.complete(.failure(error))
                } else if (info?[PHImageCancelledKey] as? Bool) == true {
                    gate.complete(.failure(PhotoKitEvidenceImageProviderError.imageUnavailable))
                } else if let data = image?.tiffRepresentation {
                    gate.complete(.success(data))
                } else if (info?[PHImageResultIsDegradedKey] as? Bool) != true {
                    gate.complete(.failure(PhotoKitEvidenceImageProviderError.imageUnavailable))
                }
            }
            gate.setCancellation {
                PHImageManager.default().cancelImageRequest(requestID)
            }
            scheduleTimeout(for: gate)
        }
    }

    private func scheduleTimeout<Value: Sendable>(for gate: PhotoContinuationGate<Value>) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + requestTimeout) {
            gate.cancel(with: PhotoKitEvidenceImageProviderError.requestTimedOut)
        }
    }


    private func thumbnailJPEG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoKitEvidenceImageProviderError.imageUnavailable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoKitEvidenceImageProviderError.imageUnavailable
        }
        return try jpegData(from: image)
    }

    private func jpegData(from image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        ) else {
            throw PhotoKitEvidenceImageProviderError.jpegEncodingFailed
        }
        return data
    }
}

private final class PhotoContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func setCancellation(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if continuation != nil {
            cancellation = action
        }
        lock.unlock()
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        cancellation = nil
        lock.unlock()
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    func cancel(with error: Error) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        let cancellation = cancellation
        self.continuation = nil
        self.cancellation = nil
        lock.unlock()
        cancellation?()
        continuation.resume(throwing: error)
    }
}
