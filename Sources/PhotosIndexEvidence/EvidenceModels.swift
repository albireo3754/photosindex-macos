import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

/// An evidence input that keeps the PhotoKit lookup key in memory but never encodes it.
public struct EvidenceSourceAsset: Sendable {
    public let id: String
    public let sourceIdentifier: String
    public let capturedAt: Date?
    public let mediaKind: MediaKind
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let hasLocation: Bool
    public let publicFilename: String?

    public init(
        id: String,
        sourceIdentifier: String,
        capturedAt: Date?,
        mediaKind: MediaKind,
        durationSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        hasLocation: Bool,
        publicFilename: String?
    ) {
        self.id = id
        self.sourceIdentifier = sourceIdentifier
        self.capturedAt = capturedAt
        self.mediaKind = mediaKind
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasLocation = hasLocation
        self.publicFilename = Self.safeFilename(publicFilename)
    }

    public init(photoAsset: PhotoAsset) {
        self.init(
            id: photoAsset.id,
            sourceIdentifier: photoAsset.localIdentifier,
            capturedAt: photoAsset.capturedAt,
            mediaKind: photoAsset.mediaKind,
            durationSeconds: photoAsset.durationSeconds,
            pixelWidth: photoAsset.pixelWidth,
            pixelHeight: photoAsset.pixelHeight,
            hasLocation: photoAsset.coordinate != nil,
            publicFilename: photoAsset.publicFilename
        )
    }

    var publicMetadata: EvidenceAsset {
        EvidenceAsset(
            id: id,
            capturedAt: capturedAt,
            mediaKind: mediaKind,
            durationSeconds: durationSeconds,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            hasLocation: hasLocation,
            publicFilename: publicFilename
        )
    }

    private static func safeFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let pattern = #"^(IMG|DSC|VID|PXL)_[0-9A-Za-z_-]+\.[A-Za-z0-9]+$"#
        return filename.range(of: pattern, options: .regularExpression) == nil ? nil : filename
    }
}

public struct EvidenceGenerationRequest: Sendable {
    public static let maximumSampleCount = 12

    public let indexRunID: String
    public let timezone: String
    public let group: CaptureGroup
    public let assets: [EvidenceSourceAsset]
    public let outputDirectory: URL
    public let generatedAt: Date
    public let maxSamples: Int
    public let expectedAssetIDs: [String]

    public init(
        indexRunID: String,
        timezone: String,
        group: CaptureGroup,
        assets: [EvidenceSourceAsset],
        outputDirectory: URL,
        generatedAt: Date = Date(),
        maxSamples: Int = EvidenceGenerationRequest.maximumSampleCount,
        expectedAssetIDs: [String]? = nil
    ) {
        self.indexRunID = indexRunID
        self.timezone = timezone
        self.group = group
        self.assets = assets
        self.outputDirectory = outputDirectory
        self.generatedAt = generatedAt
        self.maxSamples = min(Self.maximumSampleCount, max(0, maxSamples))
        self.expectedAssetIDs = expectedAssetIDs ?? group.assetIDs
    }
}

public struct EvidenceGenerationResult: Sendable {
    public let packet: GroupEvidencePacket
    public let evidenceJSONURL: URL
    public let summaryURL: URL
    public let sampleURLs: [URL]

    public init(
        packet: GroupEvidencePacket,
        evidenceJSONURL: URL,
        summaryURL: URL,
        sampleURLs: [URL]
    ) {
        self.packet = packet
        self.evidenceJSONURL = evidenceJSONURL
        self.summaryURL = summaryURL
        self.sampleURLs = sampleURLs
    }
}

public struct EvidenceAnalysis: Equatable, Sendable {
    public let ocr: [OCRObservation]
    public let faceCount: Int

    public init(ocr: [OCRObservation], faceCount: Int) {
        self.ocr = ocr
        self.faceCount = max(0, faceCount)
    }

    var privacyFlags: [String] {
        switch faceCount {
        case 0: []
        case 1: ["face-detected"]
        default: ["faces-detected:\(faceCount)"]
        }
    }
}

public protocol EvidenceImageProviding: Sendable {
    func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data
}

public protocol EvidenceAnalyzing: Sendable {
    func analyze(jpegData: Data) async throws -> EvidenceAnalysis
}
