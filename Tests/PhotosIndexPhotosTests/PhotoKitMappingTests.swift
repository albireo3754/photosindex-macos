import Foundation
import XCTest
import PhotosIndexCore
@testable import PhotosIndexPhotos

final class PhotoKitMappingTests: XCTestCase {
    func testPublicIDIsStableAndDoesNotExposeLocalIdentifier() {
        let localIdentifier = "ABC-PRIVATE/L0/001"
        let first = PhotoAssetMapper.publicID(for: localIdentifier)
        let second = PhotoAssetMapper.publicID(for: localIdentifier)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("ast_"))
        XCTAssertFalse(first.contains("ABC-PRIVATE"))
    }

    func testMapsVideoMetadataWithoutInventingByteSize() {
        let date = Date(timeIntervalSince1970: 100)
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "video-private",
                capturedAt: date,
                mediaKind: .video,
                durationSeconds: 12.5,
                pixelWidth: 3840,
                pixelHeight: 2160,
                coordinate: GeoPoint(latitude: 10.5, longitude: 20.0),
                originalFilename: "IMG_0001.MOV"
            )
        )

        XCTAssertEqual(asset.capturedAt, date)
        XCTAssertEqual(asset.mediaKind, .video)
        XCTAssertEqual(asset.exactBytes, nil)
        XCTAssertEqual(asset.publicFilename, "IMG_0001.MOV")
    }

    func testDeletionReconciliationSelectsOnlyTargetsStillPresent() {
        let first = PhotoDeletionTarget(id: "ast_first", localIdentifier: "private-first")
        let second = PhotoDeletionTarget(id: "ast_second", localIdentifier: "private-second")

        XCTAssertEqual(
            PhotoKitAssetDeleter.presentTargets(
                from: [first, second],
                fetchedLocalIdentifiers: ["private-second"]
            ),
            [second]
        )
        XCTAssertEqual(
            PhotoKitAssetDeleter.presentTargets(
                from: [first, second],
                fetchedLocalIdentifiers: []
            ),
            []
        )
    }
}
