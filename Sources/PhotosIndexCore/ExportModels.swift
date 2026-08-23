import CryptoKit
import Foundation

public struct DecisionValidationPayload: Codable, Equatable, Sendable {
    public let valid: Bool
    public let indexRunID: String
    public let groupID: String
    public let includedAssetCount: Int
    public let excludedAssetCount: Int

    public init(
        valid: Bool = true,
        indexRunID: String,
        groupID: String,
        includedAssetCount: Int,
        excludedAssetCount: Int
    ) {
        self.valid = valid
        self.indexRunID = indexRunID
        self.groupID = groupID
        self.includedAssetCount = includedAssetCount
        self.excludedAssetCount = excludedAssetCount
    }
}

public struct ExportPlanEnvelope: Codable, Equatable, Sendable {
    public let plan: ExportPlan
    public let digest: String

    public init(plan: ExportPlan, digest: String) {
        self.plan = plan
        self.digest = digest
    }
}

public enum ExportPlanIntegrityError: Error, Equatable, Sendable {
    case digestMismatch(expected: String, actual: String)
}

public enum ExportPlanIntegrity {
    public static func sha256(_ plan: ExportPlan) throws -> String {
        let digest = SHA256.hash(data: try CanonicalJSON.encode(plan))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ plan: ExportPlan, digest expected: String) throws {
        let actual = try sha256(plan)
        guard actual == expected else {
            throw ExportPlanIntegrityError.digestMismatch(expected: expected, actual: actual)
        }
    }
}

public struct ExportPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let groupID: String
    public let generatedAt: Date
    public let destinationRoot: String
    public let stagingRoot: String
    public let groupAssetIDs: [String]
    public let includedAssetIDs: [String]
    public let excludedAssetIDs: [String]
    public let label: String
    public let confidence: Double
    public let warnings: [String]

    public init(
        schemaVersion: Int = 1,
        indexRunID: String,
        groupID: String,
        generatedAt: Date,
        destinationRoot: String,
        stagingRoot: String,
        groupAssetIDs: [String],
        includedAssetIDs: [String],
        excludedAssetIDs: [String],
        label: String,
        confidence: Double,
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.groupID = groupID
        self.generatedAt = generatedAt
        self.destinationRoot = destinationRoot
        self.stagingRoot = stagingRoot
        self.groupAssetIDs = groupAssetIDs
        self.includedAssetIDs = includedAssetIDs
        self.excludedAssetIDs = excludedAssetIDs
        self.label = label
        self.confidence = confidence
        self.warnings = warnings
    }
}

public struct ExportReceiptEntry: Codable, Equatable, Sendable {
    public let assetID: String
    public let safeFilename: String
    public let mediaKind: MediaKind
    public let bytes: Int64
    public let sha256: String
    public let relativePath: String
    public let reused: Bool

    public init(
        assetID: String,
        safeFilename: String,
        mediaKind: MediaKind,
        bytes: Int64,
        sha256: String,
        relativePath: String,
        reused: Bool
    ) {
        self.assetID = assetID
        self.safeFilename = safeFilename
        self.mediaKind = mediaKind
        self.bytes = bytes
        self.sha256 = sha256
        self.relativePath = relativePath
        self.reused = reused
    }
}

public struct ExportReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let groupID: String
    public let generatedAt: Date
    public let destinationRoot: String
    public let stagingRoot: String
    public let entries: [ExportReceiptEntry]
    public let warnings: [String]

    public init(
        schemaVersion: Int = 1,
        indexRunID: String,
        groupID: String,
        generatedAt: Date,
        destinationRoot: String,
        stagingRoot: String,
        entries: [ExportReceiptEntry],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.groupID = groupID
        self.generatedAt = generatedAt
        self.destinationRoot = destinationRoot
        self.stagingRoot = stagingRoot
        self.entries = entries
        self.warnings = warnings
    }
}
