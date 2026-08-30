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
