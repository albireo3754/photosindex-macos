import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

public enum ExportError: Error, Equatable, Sendable {
    case indexRunMismatch(expected: String, actual: String)
    case groupMismatch(expected: String, actual: String)
    case lowConfidence(actual: Double, minimum: Double)
    case unknownsNotAllowed([String])
    case duplicateAssetIDs([String])
    case missingAssetIDs([String])
    case outsideGroupAssetIDs([String])
    case emptySelection
    case unsafePath(String)
    case symlinkPath(String)
    case collision(path: String)
}

public enum MoveError: Error, Equatable, Sendable {
    case unsupportedOperation
    case receiptSelectionMismatch
    case destinationMismatch
    case missingSourceAssets([String])
    case sourceDeletionMismatch
    case existingReceiptMismatch
    case pendingMoveMismatch
}

public protocol DestinationUploadVerifying: Sendable {
    func verifyUploaded(urls: [URL]) throws
}

public struct ExportPolicy: Equatable, Sendable {
    public let minimumConfidence: Double
    public let allowUnknowns: Bool

    public init(
        minimumConfidence: Double = 0.80,
        allowUnknowns: Bool = false
    ) {
        self.minimumConfidence = minimumConfidence
        self.allowUnknowns = allowUnknowns
    }
}

public struct StagedExportAsset: Equatable, Sendable {
    public let assetID: String
    public let mediaKind: MediaKind
    public let safeFilename: String
    public let stagedURL: URL
    public let bytes: Int64
    public let sha256: String

    public init(
        assetID: String,
        mediaKind: MediaKind,
        safeFilename: String,
        stagedURL: URL,
        bytes: Int64,
        sha256: String
    ) {
        self.assetID = assetID
        self.mediaKind = mediaKind
        self.safeFilename = safeFilename
        self.stagedURL = stagedURL
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public protocol PhotoAssetMaterializing: Sendable {
    func stage(asset: PhotoAsset, into stagingRoot: URL) throws -> StagedExportAsset
}

public protocol ExportWriting: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any]
    func contents(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
}

public struct FileManagerExportWriter: ExportWriting, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func attributesOfItem(at url: URL) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: url.path)
    }

    public func contents(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    public func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    public func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }
}

public protocol ExportPlanning: Sendable {
    func makePlan(
        currentIndexRunID: String,
        decision: ModelDecision,
        group: CaptureGroup,
        assets: [PhotoAsset],
        destinationRoot: URL,
        stagingRoot: URL,
        generatedAt: Date,
        policy: ExportPolicy
    ) throws -> ExportPlan
}

public protocol ExportApplying: Sendable {
    func apply(
        plan: ExportPlan,
        assets: [PhotoAsset],
        materializer: any PhotoAssetMaterializing,
        fileWriter: any ExportWriting
    ) throws -> ExportReceipt
}
