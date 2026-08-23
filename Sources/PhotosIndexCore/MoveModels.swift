import CryptoKit
import Foundation

public enum MoveOperation: String, Codable, Equatable, Sendable {
    case deleteSourceAfterVerifiedUpload = "delete-source-after-verified-upload"
}

public struct MovePlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let exportPlan: ExportPlan
    public let operation: MoveOperation

    public init(
        schemaVersion: Int = 1,
        exportPlan: ExportPlan,
        operation: MoveOperation
    ) {
        self.schemaVersion = schemaVersion
        self.exportPlan = exportPlan
        self.operation = operation
    }
}

public struct MovePlanEnvelope: Codable, Equatable, Sendable {
    public let plan: MovePlan
    public let digest: String

    public init(plan: MovePlan, digest: String) {
        self.plan = plan
        self.digest = digest
    }
}

public enum MovePlanIntegrityError: Error, Equatable, Sendable {
    case digestMismatch(expected: String, actual: String)
}

public enum MovePlanIntegrity {
    public static func sha256(_ plan: MovePlan) throws -> String {
        var data = Data("PhotosIndex.MovePlan.v1:".utf8)
        data.append(try CanonicalJSON.encode(plan))
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ plan: MovePlan, digest expected: String) throws {
        let actual = try sha256(plan)
        guard actual == expected else {
            throw MovePlanIntegrityError.digestMismatch(expected: expected, actual: actual)
        }
    }
}

public struct MoveReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let exportReceipt: ExportReceipt
    public let deletedAssetIDs: [String]
    public let completedAt: Date
    public let warnings: [String]

    public init(
        schemaVersion: Int = 1,
        exportReceipt: ExportReceipt,
        deletedAssetIDs: [String],
        completedAt: Date,
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.exportReceipt = exportReceipt
        self.deletedAssetIDs = deletedAssetIDs
        self.completedAt = completedAt
        self.warnings = warnings
    }
}
