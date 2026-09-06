import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

enum IndexRuntimeError: Error, Equatable {
    case invalidDate
    case notIndexed
    case indexDateMismatch
    case staleIndexRun
    case groupNotFound
}

struct IndexSyncCommit: Equatable, Sendable {
    let payload: IndexSyncPayload
    let generation: UInt64
}

final class IndexRuntime: @unchecked Sendable {
    private let library: any PhotoLibraryReading
    private let timezone: TimeZone
    private let syncGate = NSLock()
    private let snapshotLock = NSLock()
    private var snapshotGeneration: UInt64 = 0
    private var indexRunID = ""
    private var indexedLocalDate: String?
    private var indexedAssets: [String: PhotoAsset] = [:]
    private var sessions: [CaptureSession] = []
    private var mediaKindGroups: [CaptureGroup] = []

    init(library: any PhotoLibraryReading, timezone: TimeZone) {
        self.library = library
        self.timezone = timezone
    }

    func sync(localDate: String) throws -> IndexSyncPayload {
        try syncWithCommit(localDate: localDate).payload
    }

    func syncWithCommit(localDate: String) throws -> IndexSyncCommit {
        syncGate.lock()
        defer { syncGate.unlock() }

        let (start, end) = try dayRange(localDate)
        let assets = try library.assets(from: start, to: end)
        let grouped = AssetGrouper().group(
            assets.map(\.groupingAsset),
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )
        let groupedByMediaKind = MediaKindGrouper().group(
            assets.map(\.evidenceAsset),
            localDate: localDate
        )
        let runID = "run_\(UUID().uuidString.lowercased())"
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        snapshotGeneration &+= 1
        let generation = snapshotGeneration
        indexRunID = runID
        indexedLocalDate = localDate
        indexedAssets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        sessions = grouped
        mediaKindGroups = groupedByMediaKind
        return IndexSyncCommit(
            payload: IndexSyncPayload(
                indexRunID: runID,
                localDate: localDate,
                assetCount: assets.count,
                coarseSessionCount: grouped.count,
                fineGroupCount: grouped.reduce(0) { $0 + $1.segments.count }
            ),
            generation: generation
        )
    }

    func isIndexed(localDate: String) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return indexedLocalDate == localDate
    }

    func groups(level: GroupLevel) -> GroupsPayload {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return groupsLocked(level: level)
    }

    func groups(level: GroupLevel, localDate: String) throws -> GroupsPayload {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard indexedLocalDate == localDate else {
            throw IndexRuntimeError.indexDateMismatch
        }
        return groupsLocked(level: level)
    }

    func groups(level: GroupLevel, expectedRunID: String) throws -> GroupsPayload {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        try validateExpectedRunLocked(expectedRunID)
        return groupsLocked(level: level)
    }

    private func groupsLocked(level: GroupLevel) -> GroupsPayload {
        let groups: [CaptureGroup]
        switch level {
        case .coarse:
            groups = sessions.map { session in
                captureGroup(
                    id: session.id,
                    level: .coarse,
                    localDate: session.localDate,
                    assetIDs: session.assetIDs,
                    warnings: []
                )
            }
        case .fine:
            groups = sessions.flatMap { session in
                session.segments.map { segment in
                    captureGroup(
                        id: segment.id,
                        level: .fine,
                        localDate: session.localDate,
                        assetIDs: segment.assetIDs,
                        warnings: segment.warnings
                    )
                }
            }
        case .mediaKind:
            groups = mediaKindGroups
        }
        return GroupsPayload(indexRunID: indexRunID, level: level, groups: groups)
    }

    func group(id: String) throws -> (runID: String, group: CaptureGroup, assets: [PhotoAsset]) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return try groupLocked(id: id)
    }

    func group(
        id: String,
        expectedRunID: String
    ) throws -> (runID: String, group: CaptureGroup, assets: [PhotoAsset]) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        try validateExpectedRunLocked(expectedRunID)
        return try groupLocked(id: id)
    }

    func asset(id: String, groupID: String, expectedRunID: String) throws -> PhotoAsset? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        try validateExpectedRunLocked(expectedRunID)
        if let group = mediaKindGroups.first(where: { $0.id == groupID }) {
            return group.assetIDs.contains(id) ? indexedAssets[id] : nil
        }
        for session in sessions {
            if session.id == groupID {
                return session.assetIDs.contains(id) ? indexedAssets[id] : nil
            }
            if let segment = session.segments.first(where: { $0.id == groupID }) {
                return segment.assetIDs.contains(id) ? indexedAssets[id] : nil
            }
        }
        throw IndexRuntimeError.groupNotFound
    }

    private func groupLocked(
        id: String
    ) throws -> (runID: String, group: CaptureGroup, assets: [PhotoAsset]) {
        guard !indexRunID.isEmpty else { throw IndexRuntimeError.notIndexed }
        if let group = mediaKindGroups.first(where: { $0.id == id }) {
            return (indexRunID, group, group.assetIDs.compactMap { indexedAssets[$0] })
        }
        for session in sessions {
            if session.id == id {
                let group = captureGroup(
                    id: session.id,
                    level: .coarse,
                    localDate: session.localDate,
                    assetIDs: session.assetIDs,
                    warnings: []
                )
                return (indexRunID, group, session.assetIDs.compactMap { indexedAssets[$0] })
            }
            if let segment = session.segments.first(where: { $0.id == id }) {
                let group = captureGroup(
                    id: segment.id,
                    level: .fine,
                    localDate: session.localDate,
                    assetIDs: segment.assetIDs,
                    warnings: segment.warnings
                )
                return (indexRunID, group, segment.assetIDs.compactMap { indexedAssets[$0] })
            }
        }
        throw IndexRuntimeError.groupNotFound
    }

    private func validateExpectedRunLocked(_ expectedRunID: String) throws {
        guard !indexRunID.isEmpty else { throw IndexRuntimeError.notIndexed }
        guard indexRunID == expectedRunID else { throw IndexRuntimeError.staleIndexRun }
    }

    private func captureGroup(
        id: String,
        level: GroupLevel,
        localDate: String,
        assetIDs: [String],
        warnings: [String]
    ) -> CaptureGroup {
        let dates = assetIDs.compactMap { indexedAssets[$0]?.capturedAt }.sorted()
        return CaptureGroup(
            id: id,
            level: level,
            mediaKind: nil,
            localDate: localDate,
            start: dates.first,
            end: dates.last,
            assetIDs: assetIDs,
            warnings: warnings
        )
    }

    private func dayRange(_ value: String) throws -> (Date, Date) {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw IndexRuntimeError.invalidDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { throw IndexRuntimeError.invalidDate }
        return (start, end)
    }
}
