import Foundation
import XCTest
@testable import PhotosIndexCore

final class GroupingTests: XCTestCase {
    private let timezone = TimeZone(identifier: "Asia/Seoul")!

    func testCoarseBoundaryIsInclusive() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: GeoPoint(latitude: 10, longitude: 20)),
            GroupingAsset(id: "b", capturedAt: start.addingTimeInterval(120 * 60), coordinate: GeoPoint(latitude: 10, longitude: 20)),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].assetIDs, ["a", "b"])
    }

    func testCoarseSplitsCapturesBeyondDistanceLimit() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: GeoPoint(latitude: 10, longitude: 20)),
            GroupingAsset(
                id: "b",
                capturedAt: start.addingTimeInterval(10 * 60),
                coordinate: GeoPoint(latitude: 10.006, longitude: 20)
            ),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.map(\.assetIDs), [["a"], ["b"]])
    }

    func testFineGapOverThirtyMinutesSplitsSegments() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: nil),
            GroupingAsset(id: "b", capturedAt: start.addingTimeInterval(30 * 60 + 1), coordinate: nil),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].segments.map(\.assetIDs), [["a"], ["b"]])
        XCTAssertTrue(sessions[0].segments.allSatisfy { $0.warnings.contains("some_assets_without_location") })
    }

    func testFineSplitsDifferentLocationsWithinCoarseDistance() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: GeoPoint(latitude: 10, longitude: 20)),
            GroupingAsset(
                id: "b",
                capturedAt: start.addingTimeInterval(10 * 60),
                coordinate: GeoPoint(latitude: 10.003, longitude: 20)
            ),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].segments.map(\.assetIDs), [["a"], ["b"]])
    }

    func testFineKeepsSparseCapturesAtSameLocationWithinCoarseGap() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let location = GeoPoint(latitude: 10, longitude: 20)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: location),
            GroupingAsset(id: "b", capturedAt: start.addingTimeInterval(90 * 60), coordinate: location),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].segments.map(\.assetIDs), [["a", "b"]])
    }

    func testFineSameLocationBoundaryIsInclusive() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let location = GeoPoint(latitude: 10, longitude: 20)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: location),
            GroupingAsset(
                id: "b",
                capturedAt: start.addingTimeInterval(GroupingPolicy.coarseDefault.maxGap),
                coordinate: location
            ),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].segments.map(\.assetIDs), [["a", "b"]])
    }

    func testSameLocationBeyondCoarseGapStartsNewSession() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let location = GeoPoint(latitude: 10, longitude: 20)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: location),
            GroupingAsset(
                id: "b",
                capturedAt: start.addingTimeInterval(GroupingPolicy.coarseDefault.maxGap + 1),
                coordinate: location
            ),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.map(\.assetIDs), [["a"], ["b"]])
    }

    func testSameLocationAcrossLocalDateBoundaryStartsNewSession() throws {
        let start = ISO8601DateFormatter().date(from: "2026-01-14T14:59:00Z")!
        let location = GeoPoint(latitude: 10, longitude: 20)
        let assets = [
            GroupingAsset(id: "a", capturedAt: start, coordinate: location),
            GroupingAsset(id: "b", capturedAt: start.addingTimeInterval(2 * 60), coordinate: location),
        ]

        let sessions = AssetGrouper().group(
            assets,
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions.map(\.assetIDs), [["a"], ["b"]])
    }

    func testSortingUsesAssetIDForEqualCaptureDates() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let sessions = AssetGrouper().group(
            [
                GroupingAsset(id: "b", capturedAt: date, coordinate: nil),
                GroupingAsset(id: "a", capturedAt: date, coordinate: nil),
            ],
            timezone: timezone,
            coarse: .coarseDefault,
            fine: .fineDefault
        )

        XCTAssertEqual(sessions[0].assetIDs, ["a", "b"])
    }

    func testMediaKindGroupingBuildsOneDateWideGroupPerKind() {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            evidenceAsset(id: "video-late", date: start.addingTimeInterval(60), kind: .video, hasLocation: true),
            evidenceAsset(id: "photo-late", date: start.addingTimeInterval(120), kind: .photo, hasLocation: false),
            evidenceAsset(id: "photo-early", date: start, kind: .photo, hasLocation: true),
        ]

        let groups = MediaKindGrouper().group(assets, localDate: "2026-01-15")

        XCTAssertEqual(groups.map(\.mediaKind), [.photo, .video])
        XCTAssertTrue(groups.allSatisfy { $0.level == .mediaKind })
        XCTAssertEqual(groups[0].assetIDs, ["photo-early", "photo-late"])
        XCTAssertEqual(groups[1].assetIDs, ["video-late"])
        XCTAssertEqual(groups[0].warnings, ["some_assets_without_location"])
        XCTAssertEqual(groups[1].warnings, [])
        XCTAssertTrue(groups[0].id.hasPrefix("media-photo_20260115_"))
        XCTAssertTrue(groups[1].id.hasPrefix("media-video_20260115_"))
    }

    func testMediaKindGroupIDsDoNotDependOnInputOrder() {
        let start = Date(timeIntervalSince1970: 1_000)
        let assets = [
            evidenceAsset(id: "video-b", date: start.addingTimeInterval(60), kind: .video, hasLocation: true),
            evidenceAsset(id: "video-a", date: start, kind: .video, hasLocation: true),
        ]

        let forward = MediaKindGrouper().group(assets, localDate: "2026-01-15")
        let reversed = MediaKindGrouper().group(Array(assets.reversed()), localDate: "2026-01-15")

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.map(\.mediaKind), [.video])
    }

    private func evidenceAsset(
        id: String,
        date: Date,
        kind: MediaKind,
        hasLocation: Bool
    ) -> EvidenceAsset {
        EvidenceAsset(
            id: id,
            capturedAt: date,
            mediaKind: kind,
            durationSeconds: kind == .video ? 10 : 0,
            pixelWidth: 100,
            pixelHeight: 100,
            hasLocation: hasLocation,
            publicFilename: kind == .video ? "VID_0001.MOV" : "IMG_0001.HEIC"
        )
    }
}
