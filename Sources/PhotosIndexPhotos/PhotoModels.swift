import CryptoKit
import Foundation
import PhotosIndexCore

public enum PhotoAuthorizationStatus: String, Codable, Sendable {
    case notDetermined = "not-determined"
    case restricted
    case denied
    case authorized
    case limited
    case unknown
}

public struct PhotoMetadataInput: Sendable {
    public let localIdentifier: String
    public let capturedAt: Date?
    public let mediaKind: MediaKind
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let coordinate: GeoPoint?
    public let originalFilename: String?

    public init(
        localIdentifier: String,
        capturedAt: Date?,
        mediaKind: MediaKind,
        durationSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        coordinate: GeoPoint?,
        originalFilename: String?
    ) {
        self.localIdentifier = localIdentifier
        self.capturedAt = capturedAt
        self.mediaKind = mediaKind
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.coordinate = coordinate
        self.originalFilename = originalFilename
    }
}

public struct PhotoDeletionTarget: Codable, Equatable, Sendable {
    public let id: String
    public let localIdentifier: String

    public init(id: String, localIdentifier: String) {
        self.id = id
        self.localIdentifier = localIdentifier
    }
}

public struct PhotoAsset: Sendable {
    public let id: String
    public let localIdentifier: String
    public let capturedAt: Date?
    public let mediaKind: MediaKind
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let coordinate: GeoPoint?
    public let publicFilename: String?
    public let exactBytes: Int64?

    public var groupingAsset: GroupingAsset {
        GroupingAsset(id: id, capturedAt: capturedAt, coordinate: coordinate)
    }

    public var evidenceAsset: EvidenceAsset {
        EvidenceAsset(
            id: id,
            capturedAt: capturedAt,
            mediaKind: mediaKind,
            durationSeconds: durationSeconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            hasLocation: coordinate != nil,
            publicFilename: publicFilename
        )
    }

    public var deletionTarget: PhotoDeletionTarget {
        PhotoDeletionTarget(id: id, localIdentifier: localIdentifier)
    }
}

public enum PhotoAssetMapper {
    public static func publicID(for localIdentifier: String) -> String {
        let digest = SHA256.hash(data: Data(localIdentifier.utf8))
        return "ast_" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func map(_ input: PhotoMetadataInput) -> PhotoAsset {
        PhotoAsset(
            id: publicID(for: input.localIdentifier),
            localIdentifier: input.localIdentifier,
            capturedAt: input.capturedAt,
            mediaKind: input.mediaKind,
            durationSeconds: input.durationSeconds,
            pixelWidth: input.pixelWidth,
            pixelHeight: input.pixelHeight,
            coordinate: input.coordinate,
            publicFilename: safeFilename(input.originalFilename),
            exactBytes: nil
        )
    }

    private static func safeFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let pattern = #"^(IMG|DSC|VID|PXL)_[0-9A-Za-z_-]+\.[A-Za-z0-9]+$"#
        guard filename.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return filename
    }
}

public protocol PhotoLibraryReading: Sendable {
    func authorizationStatus() -> PhotoAuthorizationStatus
    func requestAuthorization() async -> PhotoAuthorizationStatus
    func assets(from start: Date, to end: Date) throws -> [PhotoAsset]
}

public protocol PhotoAssetDeleting: Sendable {
    func delete(targets: [PhotoDeletionTarget]) throws -> [String]
}
