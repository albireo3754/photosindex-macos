import AppKit
import AVFoundation
import PhotosIndexCore
import PhotosIndexPhotos
import XCTest
@testable import PhotosIndexApp

@MainActor
final class HumanMediaServiceTests: XCTestCase {
    func testImageResolvesOnlySelectedAssetAndPassesBoundedTarget() async throws {
        let fixture = try fixture()
        let size = CGSize(width: 320, height: 240)
        let image = try await fixture.service.image(
            assetID: fixture.photo.id, groupID: fixture.group.id,
            expectedRunID: fixture.runID, targetSize: size
        )
        XCTAssertTrue(image === fixture.provider.resultImage)
        XCTAssertEqual(fixture.provider.identifiers, [fixture.photo.localIdentifier])
        XCTAssertEqual(fixture.provider.targetSize, size)
    }

    func testAssetOutsideGroupNeverReachesPhotoKitProvider() async throws {
        let fixture = try fixture()
        do {
            _ = try await fixture.service.image(
                assetID: fixture.video.id, groupID: fixture.group.id,
                expectedRunID: fixture.runID, targetSize: CGSize(width: 320, height: 240)
            )
            XCTFail("An asset outside the selected group must be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .assetUnavailable)
        }
        XCTAssertTrue(fixture.provider.identifiers.isEmpty)
    }

    func testMediaLookupSupportsEveryGroupingLevel() async throws {
        let fixture = try fixture()
        for level in [GroupLevel.coarse, .fine, .mediaKind] {
            let group = try XCTUnwrap(fixture.runtime.groups(level: level).groups.first {
                $0.assetIDs.contains(fixture.photo.id)
            })
            _ = try await fixture.service.image(
                assetID: fixture.photo.id, groupID: group.id,
                expectedRunID: fixture.runID, targetSize: CGSize(width: 320, height: 240)
            )
        }
        XCTAssertEqual(fixture.provider.identifiers, Array(repeating: fixture.photo.localIdentifier, count: 3))
    }

    func testMissingGroupNeverReachesPhotoKitProvider() async throws {
        let fixture = try fixture()
        do {
            _ = try await fixture.service.image(
                assetID: fixture.photo.id, groupID: "synthetic-missing-group",
                expectedRunID: fixture.runID, targetSize: CGSize(width: 320, height: 240)
            )
            XCTFail("A missing group must be rejected")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .groupNotFound)
        }
        XCTAssertTrue(fixture.provider.identifiers.isEmpty)
    }

    func testStaleRunNeverReachesPhotoKitProvider() async throws {
        let fixture = try fixture()
        _ = try fixture.runtime.sync(localDate: "2030-02-03")
        do {
            _ = try await fixture.service.image(
                assetID: fixture.photo.id, groupID: fixture.group.id,
                expectedRunID: fixture.runID, targetSize: CGSize(width: 320, height: 240)
            )
            XCTFail("A stale index must be rejected")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
        XCTAssertTrue(fixture.provider.identifiers.isEmpty)
    }

    func testRunReplacedDuringImageLoadRejectsResult() async throws {
        let fixture = try fixture()
        fixture.provider.beforeReturn = { _ = try fixture.runtime.sync(localDate: "2030-02-03") }
        do {
            _ = try await fixture.service.image(
                assetID: fixture.photo.id, groupID: fixture.group.id,
                expectedRunID: fixture.runID, targetSize: CGSize(width: 320, height: 240)
            )
            XCTFail("A late image from an old index must be discarded")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
        XCTAssertEqual(fixture.provider.identifiers.count, 1)
    }

    func testPhotoCannotBeOpenedAsVideo() async throws {
        let fixture = try fixture()
        do {
            _ = try await fixture.service.playerItem(
                assetID: fixture.photo.id, groupID: fixture.group.id, expectedRunID: fixture.runID
            )
            XCTFail("Only videos may create player items")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .unsupportedMediaType)
        }
        XCTAssertTrue(fixture.provider.identifiers.isEmpty)
    }

    func testVideoResolvesSelectedVideoAndRejectsLateStaleResult() async throws {
        let fixture = try fixture()
        let videoGroup = try XCTUnwrap(fixture.runtime.groups(level: .mediaKind).groups.first { $0.mediaKind == .video })
        let item = try await fixture.service.playerItem(
            assetID: fixture.video.id, groupID: videoGroup.id, expectedRunID: fixture.runID
        )
        XCTAssertTrue(item === fixture.provider.resultItem)
        XCTAssertEqual(fixture.provider.identifiers, [fixture.video.localIdentifier])
        fixture.provider.beforeReturn = { _ = try fixture.runtime.sync(localDate: "2030-02-03") }
        do {
            _ = try await fixture.service.playerItem(
                assetID: fixture.video.id, groupID: videoGroup.id, expectedRunID: fixture.runID
            )
            XCTFail("A late video from an old index must be discarded")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
    }

    private func fixture() throws -> (
        service: HumanMediaService, runtime: IndexRuntime, provider: StubMediaProvider,
        photo: PhotoAsset, video: PhotoAsset, group: CaptureGroup, runID: String
    ) {
        let date = ISO8601DateFormatter().date(from: "2030-02-03T03:00:00Z")!
        func asset(_ kind: MediaKind) -> PhotoAsset {
            PhotoAssetMapper.map(PhotoMetadataInput(
                localIdentifier: "synthetic-media-\(kind.rawValue)", capturedAt: date,
                mediaKind: kind, durationSeconds: kind == .video ? 5 : 0,
                pixelWidth: 640, pixelHeight: 480, coordinate: nil,
                originalFilename: "synthetic-media"
            ))
        }
        let photo = asset(.photo)
        let video = asset(.video)
        let runtime = IndexRuntime(
            library: MediaTestLibrary(storedAssets: [photo, video]),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let sync = try runtime.sync(localDate: "2030-02-03")
        let group = try XCTUnwrap(runtime.groups(level: .mediaKind).groups.first { $0.mediaKind == .photo })
        let provider = StubMediaProvider()
        return (HumanMediaService(runtime: runtime, provider: provider), runtime, provider,
                photo, video, group, sync.indexRunID)
    }
}

@MainActor
private final class StubMediaProvider: PhotoMediaProviding {
    let resultImage = NSImage(size: CGSize(width: 4, height: 4))
    let resultItem = AVPlayerItem(asset: AVMutableComposition())
    var identifiers: [String] = []
    var targetSize: CGSize?
    var beforeReturn: (() throws -> Void)?

    func image(localIdentifier: String, targetSize: CGSize) async throws -> NSImage {
        identifiers.append(localIdentifier)
        self.targetSize = targetSize
        try beforeReturn?()
        return resultImage
    }

    func playerItem(localIdentifier: String) async throws -> AVPlayerItem {
        identifiers.append(localIdentifier)
        try beforeReturn?()
        return resultItem
    }
}

private struct MediaTestLibrary: PhotoLibraryReading {
    let storedAssets: [PhotoAsset]
    func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }
    func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }
    func assets(from start: Date, to end: Date) throws -> [PhotoAsset] { storedAssets }
}
