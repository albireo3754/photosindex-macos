import Foundation
import XCTest
import PhotosIndexCore
import PhotosIndexPhotos
@testable import PhotosIndexApp

final class IndexRuntimeTests: XCTestCase {
    func testSyncBuildsCoarseSessionsAndFineSegments() throws {
        let timezone = TimeZone(identifier: "Asia/Seoul")!
        let calendar = Calendar(identifier: .gregorian)
        let start = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let assets = [
            asset(id: "a", date: start, latitude: 10.0, mediaKind: .photo),
            asset(id: "b", date: start.addingTimeInterval(10 * 60), latitude: 10.0, mediaKind: .photo),
            asset(id: "c", date: start.addingTimeInterval(45 * 60), latitude: 10.0, mediaKind: .photo),
        ]
        let runtime = IndexRuntime(library: FakePhotoLibrary(assets: assets), timezone: timezone)

        let result = try runtime.sync(localDate: "2026-01-15")
        let groups = runtime.groups(level: .fine)

        XCTAssertEqual(result.assetCount, 3)
        XCTAssertEqual(result.coarseSessionCount, 1)
        XCTAssertEqual(result.fineGroupCount, 1)
        XCTAssertEqual(groups.groups.map(\.assetIDs), [assets.map(\.id)])
        XCTAssertFalse(result.indexRunID.isEmpty)
        _ = calendar
    }

    func testMediaKindGroupsPartitionTheWholeDateAndRemainResolvable() throws {
        let start = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let assets = [
            asset(id: "photo-a", date: start, latitude: 10.0, mediaKind: .photo),
            asset(id: "video-a", date: start.addingTimeInterval(60), latitude: 10.0, mediaKind: .video),
            asset(id: "video-b", date: start.addingTimeInterval(120), latitude: 10.0, mediaKind: .video),
        ]
        let runtime = IndexRuntime(library: FakePhotoLibrary(assets: assets), timezone: timezone)

        let sync = try runtime.sync(localDate: "2026-01-15")
        let groups = runtime.groups(level: .mediaKind)
        let videoGroup = try XCTUnwrap(groups.groups.first { $0.mediaKind == .video })
        let detail = try runtime.group(id: videoGroup.id)

        XCTAssertEqual(groups.indexRunID, sync.indexRunID)
        XCTAssertEqual(groups.groups.map(\.mediaKind), [.photo, .video])
        XCTAssertEqual(videoGroup.assetIDs, Array(assets.dropFirst().map(\.id)))
        XCTAssertEqual(detail.group, videoGroup)
        XCTAssertEqual(detail.assets.map(\.id), videoGroup.assetIDs)
    }

    func testDatedGroupsReadStaysOnRequestedSnapshotDuringConcurrentDateSync() async throws {
        let firstDate = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let secondDate = ISO8601DateFormatter().date(from: "2026-01-16T03:00:00Z")!
        let firstAsset = asset(
            id: "dated-first",
            date: firstDate,
            latitude: 10,
            mediaKind: .photo
        )
        let secondAsset = asset(
            id: "dated-second",
            date: secondDate,
            latitude: 10,
            mediaKind: .photo
        )
        let library = ControllablyBlockedPhotoLibrary(
            assets: [firstAsset, secondAsset]
        )
        defer { library.releaseAll() }
        let runtime = IndexRuntime(library: library, timezone: timezone)

        let initialSync = Task.detached {
            try runtime.syncWithCommit(localDate: "2026-01-15")
        }
        XCTAssertTrue(library.waitForCallCount(1))
        library.releaseNextCall()
        let initialCommit = try await initialSync.value
        let expectedGroups = try runtime.groups(level: .fine, localDate: "2026-01-15")

        let nextSync = Task.detached {
            try runtime.syncWithCommit(localDate: "2026-01-16")
        }
        XCTAssertTrue(library.waitForCallCount(2))

        let groupsWhileNextSyncIsBlocked = try runtime.groups(
            level: .fine,
            localDate: "2026-01-15"
        )

        XCTAssertEqual(groupsWhileNextSyncIsBlocked, expectedGroups)
        XCTAssertEqual(groupsWhileNextSyncIsBlocked.indexRunID, initialCommit.payload.indexRunID)
        XCTAssertEqual(groupsWhileNextSyncIsBlocked.groups.flatMap(\.assetIDs), [firstAsset.id])
        XCTAssertTrue(groupsWhileNextSyncIsBlocked.groups.allSatisfy {
            $0.localDate == "2026-01-15"
        })

        library.releaseNextCall()
        let nextCommit = try await nextSync.value

        XCTAssertThrowsError(
            try runtime.groups(level: .fine, localDate: "2026-01-15")
        ) { error in
            XCTAssertEqual(error as? IndexRuntimeError, .indexDateMismatch)
        }
        let currentGroups = try runtime.groups(level: .fine, localDate: "2026-01-16")
        XCTAssertEqual(currentGroups.indexRunID, nextCommit.payload.indexRunID)
        XCTAssertEqual(currentGroups.groups.flatMap(\.assetIDs), [secondAsset.id])
    }

    func testConcurrentSyncsSerializeAndReadsKeepUsingTheCommittedSnapshot() async throws {
        let firstDate = ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")!
        let secondDate = ISO8601DateFormatter().date(from: "2026-01-16T03:00:00Z")!
        let thirdDate = ISO8601DateFormatter().date(from: "2026-01-17T03:00:00Z")!
        let library = ControllablyBlockedPhotoLibrary(
            assets: [
                asset(id: "sync-order-a", date: firstDate, latitude: 10, mediaKind: .photo),
                asset(id: "sync-order-b", date: secondDate, latitude: 10, mediaKind: .photo),
                asset(id: "sync-order-c", date: thirdDate, latitude: 10, mediaKind: .photo),
            ]
        )
        defer { library.releaseAll() }
        let runtime = IndexRuntime(library: library, timezone: timezone)

        let initialTask = Task.detached {
            try runtime.syncWithCommit(localDate: "2026-01-15")
        }
        XCTAssertTrue(library.waitForCallCount(1))
        library.releaseNextCall()
        let initial = try await initialTask.value
        let initialGroups = try runtime.groups(
            level: .fine,
            expectedRunID: initial.payload.indexRunID
        )

        let secondTask = Task.detached {
            try runtime.syncWithCommit(localDate: "2026-01-16")
        }
        XCTAssertTrue(library.waitForCallCount(2))
        let thirdTask = Task.detached {
            try runtime.syncWithCommit(localDate: "2026-01-17")
        }
        XCTAssertFalse(library.waitForCallCount(3, timeout: 0.1))

        let readRecorder = RuntimeGroupsRecorder()
        let readFinished = expectation(description: "snapshot read finishes during sync")
        DispatchQueue.global().async {
            readRecorder.record(
                Result {
                    try runtime.groups(
                        level: .fine,
                        expectedRunID: initial.payload.indexRunID
                    )
                }
            )
            readFinished.fulfill()
        }
        await fulfillment(of: [readFinished], timeout: 0.5)
        let readCompletedBeforeCommit = readRecorder.get() != nil
        library.releaseNextCall()
        if !readCompletedBeforeCommit {
            await fulfillment(of: [readFinished], timeout: 1)
        }

        XCTAssertTrue(readCompletedBeforeCommit)
        XCTAssertEqual(try XCTUnwrap(readRecorder.get()).get(), initialGroups)
        let second = try await secondTask.value
        XCTAssertTrue(library.waitForCallCount(3))
        XCTAssertEqual(second.generation, initial.generation + 1)
        XCTAssertEqual(
            try runtime.groups(
                level: .fine,
                expectedRunID: second.payload.indexRunID
            ).indexRunID,
            second.payload.indexRunID
        )
        XCTAssertThrowsError(
            try runtime.groups(
                level: .fine,
                expectedRunID: initial.payload.indexRunID
            )
        ) { error in
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
        XCTAssertThrowsError(
            try runtime.group(
                id: initialGroups.groups[0].id,
                expectedRunID: initial.payload.indexRunID
            )
        ) { error in
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }

        library.releaseNextCall()
        let third = try await thirdTask.value

        XCTAssertEqual(third.generation, second.generation + 1)
        XCTAssertTrue(runtime.isIndexed(localDate: "2026-01-17"))
        XCTAssertEqual(
            try runtime.groups(
                level: .fine,
                expectedRunID: third.payload.indexRunID
            ).indexRunID,
            third.payload.indexRunID
        )
    }

    private var timezone: TimeZone {
        TimeZone(identifier: "Asia/Seoul")!
    }

    private func asset(
        id: String,
        date: Date,
        latitude: Double,
        mediaKind: MediaKind
    ) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: id,
                capturedAt: date,
                mediaKind: mediaKind,
                durationSeconds: mediaKind == .video ? 10 : 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: GeoPoint(latitude: latitude, longitude: 20),
                originalFilename: mediaKind == .video ? "VID_\(id).MOV" : "IMG_\(id).HEIC"
            )
        )
    }
}

final class ControllablyBlockedPhotoLibrary: PhotoLibraryReading, @unchecked Sendable {
    private let condition = NSCondition()
    private let storedAssets: [PhotoAsset]
    private var callCount = 0
    private var releasedCallCount = 0

    init(assets: [PhotoAsset]) {
        storedAssets = assets
    }

    func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }

    func assets(from start: Date, to end: Date) throws -> [PhotoAsset] {
        condition.lock()
        callCount += 1
        let currentCall = callCount
        condition.broadcast()
        while releasedCallCount < currentCall {
            condition.wait()
        }
        condition.unlock()

        return storedAssets.filter { asset in
            guard let date = asset.capturedAt else { return false }
            return date >= start && date < end
        }
    }

    func waitForCallCount(_ expected: Int, timeout: TimeInterval = 1) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while callCount < expected {
            guard condition.wait(until: deadline) else { return callCount >= expected }
        }
        return true
    }

    func releaseNextCall() {
        condition.lock()
        releasedCallCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func releaseAll() {
        condition.lock()
        releasedCallCount = .max
        condition.broadcast()
        condition.unlock()
    }
}

private final class RuntimeGroupsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<GroupsPayload, Error>?

    func record(_ result: Result<GroupsPayload, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<GroupsPayload, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private final class FakePhotoLibrary: PhotoLibraryReading, @unchecked Sendable {
    let storedAssets: [PhotoAsset]

    init(assets: [PhotoAsset]) {
        storedAssets = assets
    }

    func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }
    func assets(from start: Date, to end: Date) throws -> [PhotoAsset] {
        storedAssets.filter { asset in
            guard let date = asset.capturedAt else { return false }
            return date >= start && date < end
        }
    }
}
