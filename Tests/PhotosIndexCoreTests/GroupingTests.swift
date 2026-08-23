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
}
