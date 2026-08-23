import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo
    case video
}

public enum GroupLevel: String, Codable, Sendable {
    case coarse
    case fine
}

public struct CaptureGroup: Codable, Equatable, Sendable {
    public let id: String
    public let level: GroupLevel
    public let localDate: String
    public let start: Date?
    public let end: Date?
    public let assetIDs: [String]
    public let warnings: [String]

    public init(
        id: String,
        level: GroupLevel,
        localDate: String,
        start: Date?,
        end: Date?,
        assetIDs: [String],
        warnings: [String]
    ) {
        self.id = id
        self.level = level
        self.localDate = localDate
        self.start = start
        self.end = end
        self.assetIDs = assetIDs
        self.warnings = warnings
    }
}

public struct EvidenceAsset: Codable, Equatable, Sendable {
    public let id: String
    public let capturedAt: Date?
    public let mediaKind: MediaKind
    public let durationSeconds: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let hasLocation: Bool
    public let publicFilename: String?

    public init(
        id: String,
        capturedAt: Date?,
        mediaKind: MediaKind,
        durationSeconds: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        hasLocation: Bool,
        publicFilename: String?
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.mediaKind = mediaKind
        self.durationSeconds = durationSeconds
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasLocation = hasLocation
        self.publicFilename = publicFilename
    }
}

public enum EvidenceSampleKind: String, Codable, Sendable {
    case photoThumbnail
    case videoFrame
}

public struct OCRObservation: Codable, Equatable, Sendable {
    public let text: String
    public let confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

public struct EvidenceSample: Codable, Equatable, Sendable {
    public let id: String
    public let assetID: String
    public let kind: EvidenceSampleKind
    public let relativePath: String
    public let position: Double?
    public let ocr: [OCRObservation]
    public let privacyFlags: [String]

    public init(
        id: String,
        assetID: String,
        kind: EvidenceSampleKind,
        relativePath: String,
        position: Double?,
        ocr: [OCRObservation],
        privacyFlags: [String]
    ) {
        self.id = id
        self.assetID = assetID
        self.kind = kind
        self.relativePath = relativePath
        self.position = position
        self.ocr = ocr
        self.privacyFlags = privacyFlags
    }
}

public struct GroupEvidencePacket: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let generatedAt: Date
    public let timezone: String
    public let group: CaptureGroup
    public let assets: [EvidenceAsset]
    public let samples: [EvidenceSample]
    public let warnings: [String]

    public init(
        schemaVersion: Int,
        indexRunID: String,
        generatedAt: Date,
        timezone: String,
        group: CaptureGroup,
        assets: [EvidenceAsset],
        samples: [EvidenceSample],
        warnings: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.generatedAt = generatedAt
        self.timezone = timezone
        self.group = group
        self.assets = assets
        self.samples = samples
        self.warnings = warnings
    }
}

public struct IndexSyncPayload: Codable, Equatable, Sendable {
    public let indexRunID: String
    public let localDate: String
    public let assetCount: Int
    public let coarseSessionCount: Int
    public let fineGroupCount: Int

    public init(
        indexRunID: String,
        localDate: String,
        assetCount: Int,
        coarseSessionCount: Int,
        fineGroupCount: Int
    ) {
        self.indexRunID = indexRunID
        self.localDate = localDate
        self.assetCount = assetCount
        self.coarseSessionCount = coarseSessionCount
        self.fineGroupCount = fineGroupCount
    }
}

public struct AuthorizationPayload: Codable, Equatable, Sendable {
    public let permission: String

    public init(permission: String) {
        self.permission = permission
    }
}

public struct GroupsPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let level: GroupLevel
    public let groups: [CaptureGroup]

    public init(schemaVersion: Int = 1, indexRunID: String, level: GroupLevel, groups: [CaptureGroup]) {
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.level = level
        self.groups = groups
    }
}

public struct GroupDetailPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let group: CaptureGroup
    public let assets: [EvidenceAsset]

    public init(
        schemaVersion: Int = 1,
        indexRunID: String,
        group: CaptureGroup,
        assets: [EvidenceAsset]
    ) {
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.group = group
        self.assets = assets
    }
}

public enum EvidencePageError: Error, Equatable, Sendable {
    case invalidPageNumber
    case invalidPageSize
    case pageOutOfRange
}

public struct EvidencePage: Codable, Equatable, Sendable {
    public let pageNumber: Int
    public let pageSize: Int
    public let totalPages: Int
    public let assetIDs: [String]
    public let remainingAssetIDs: [String]

    public static func make(
        groupAssetIDs: [String],
        pageNumber: Int,
        pageSize: Int
    ) throws -> EvidencePage {
        guard pageNumber >= 1 else { throw EvidencePageError.invalidPageNumber }
        guard (1...12).contains(pageSize) else { throw EvidencePageError.invalidPageSize }
        let totalPages = (groupAssetIDs.count + pageSize - 1) / pageSize
        guard pageNumber <= totalPages else { throw EvidencePageError.pageOutOfRange }

        let start = (pageNumber - 1) * pageSize
        let end = min(start + pageSize, groupAssetIDs.count)
        return EvidencePage(
            pageNumber: pageNumber,
            pageSize: pageSize,
            totalPages: totalPages,
            assetIDs: Array(groupAssetIDs[start..<end]),
            remainingAssetIDs: Array(groupAssetIDs[end...])
        )
    }

    public init(
        pageNumber: Int,
        pageSize: Int,
        totalPages: Int,
        assetIDs: [String],
        remainingAssetIDs: [String]
    ) {
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalPages = totalPages
        self.assetIDs = assetIDs
        self.remainingAssetIDs = remainingAssetIDs
    }
}

public struct EvidenceInspectionPayload: Codable, Equatable, Sendable {
    public let indexRunID: String
    public let groupID: String
    public let outputDirectory: String
    public let evidenceJSON: String
    public let summaryMarkdown: String
    public let sampleFiles: [String]
    public let packet: GroupEvidencePacket
    public let page: EvidencePage

    public init(
        indexRunID: String,
        groupID: String,
        outputDirectory: String,
        evidenceJSON: String,
        summaryMarkdown: String,
        sampleFiles: [String],
        packet: GroupEvidencePacket,
        page: EvidencePage
    ) {
        self.indexRunID = indexRunID
        self.groupID = groupID
        self.outputDirectory = outputDirectory
        self.evidenceJSON = evidenceJSON
        self.summaryMarkdown = summaryMarkdown
        self.sampleFiles = sampleFiles
        self.packet = packet
        self.page = page
    }
}

public enum ModelDecisionError: Error, Equatable {
    case confidenceOutOfRange
}

public struct ModelDecision: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let indexRunID: String
    public let groupID: String
    public let label: String
    public let confidence: Double
    public let includedAssetIDs: [String]
    public let excludedAssetIDs: [String]
    public let evidenceReferences: [String]
    public let unknowns: [String]

    public init(
        schemaVersion: Int,
        indexRunID: String,
        groupID: String,
        label: String,
        confidence: Double,
        includedAssetIDs: [String],
        excludedAssetIDs: [String],
        evidenceReferences: [String],
        unknowns: [String]
    ) throws {
        guard (0...1).contains(confidence) else {
            throw ModelDecisionError.confidenceOutOfRange
        }
        self.schemaVersion = schemaVersion
        self.indexRunID = indexRunID
        self.groupID = groupID
        self.label = label
        self.confidence = confidence
        self.includedAssetIDs = includedAssetIDs
        self.excludedAssetIDs = excludedAssetIDs
        self.evidenceReferences = evidenceReferences
        self.unknowns = unknowns
    }
}
