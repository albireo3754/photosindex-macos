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
            photo(id: "a", date: start, latitude: 10.0),
            photo(id: "b", date: start.addingTimeInterval(10 * 60), latitude: 10.0),
            photo(id: "c", date: start.addingTimeInterval(45 * 60), latitude: 10.0),
        ]
        let runtime = IndexRuntime(library: FakePhotoLibrary(assets: assets), timezone: timezone)

        let result = try runtime.sync(localDate: "2026-01-15")
        let groups = runtime.groups(level: .fine)

        XCTAssertEqual(result.assetCount, 3)
        XCTAssertEqual(result.coarseSessionCount, 1)
        XCTAssertEqual(result.fineGroupCount, 2)
        XCTAssertEqual(groups.groups.map(\.assetIDs), [[assets[0].id, assets[1].id], [assets[2].id]])
        XCTAssertFalse(result.indexRunID.isEmpty)
        _ = calendar
    }

    private func photo(id: String, date: Date, latitude: Double) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: id,
                capturedAt: date,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: GeoPoint(latitude: latitude, longitude: 20),
                originalFilename: "IMG_\(id).HEIC"
            )
        )
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
