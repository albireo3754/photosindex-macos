import AppKit
import AVFoundation
import XCTest
@testable import PhotosIndexApp

@MainActor
final class MediaPreviewModelTests: XCTestCase {
    func testPhotoLoadsAndClearReleasesIt() async {
        let service = PreviewTestService()
        let model = MediaPreviewModel()
        await load(model, service: service)
        XCTAssertTrue(model.image === service.imageResult)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
        model.clear()
        XCTAssertNil(model.image)
        XCTAssertNil(model.player)
    }

    func testVideoDoesNotAutoplayAndClearDetachesItem() async {
        let service = PreviewTestService()
        let model = MediaPreviewModel()
        await load(model, service: service, video: true)
        let player = model.player
        XCTAssertNotNil(player)
        XCTAssertEqual(player?.rate, 0)
        XCTAssertNotNil(player?.currentItem)
        model.clear()
        XCTAssertNil(model.player)
        XCTAssertNil(player?.currentItem)
        XCTAssertEqual(player?.rate, 0)
    }

    func testClearWhileLoadingDiscardsLatePhoto() async {
        let service = PreviewTestService()
        service.hold = true
        let model = MediaPreviewModel()
        let task = Task { await self.load(model, service: service) }
        await service.waitUntilStarted()
        XCTAssertTrue(model.isLoading)
        model.clear()
        service.finish()
        await task.value
        XCTAssertNil(model.image)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testPlaybackFailureReleasesPlayerAndLateFailureCannotReplaceNewPhoto() async throws {
        let service = PreviewTestService()
        let model = MediaPreviewModel()
        await load(model, service: service, video: true)
        let player = try XCTUnwrap(model.player)
        let item = try XCTUnwrap(player.currentItem)
        model.playbackFailed(for: item)
        XCTAssertNil(model.player)
        XCTAssertNil(player.currentItem)
        XCTAssertNotNil(model.error)
        await load(model, service: service)
        model.playbackFailed(for: item)
        XCTAssertTrue(model.image === service.imageResult)
        XCTAssertNil(model.error)
    }

    func testCancelledLoadDiscardsLateVideo() async {
        let service = PreviewTestService()
        service.hold = true
        let model = MediaPreviewModel()
        let task = Task { await self.load(model, service: service, video: true) }
        await service.waitUntilStarted()
        task.cancel()
        service.finish()
        await task.value
        XCTAssertNil(model.player)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    func testNewSelectionWinsWhenOldLoadCompletesLast() async {
        let oldService = PreviewTestService()
        oldService.hold = true
        let newService = PreviewTestService()
        let model = MediaPreviewModel()
        let old = Task { await self.load(model, service: oldService) }
        await oldService.waitUntilStarted()
        await load(model, service: newService)
        oldService.finish()
        await old.value
        XCTAssertTrue(model.image === newService.imageResult)
        XCTAssertFalse(model.isLoading)
    }

    func testFailureIsSanitizedAndRetrySucceeds() async {
        let service = PreviewTestService()
        service.fail = true
        let model = MediaPreviewModel()
        await load(model, service: service)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.error?.contains("synthetic-private") ?? true)
        XCTAssertFalse(model.isLoading)
        service.fail = false
        await load(model, service: service)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.image)
    }

    private func load(_ model: MediaPreviewModel, service: PreviewTestService, video: Bool = false) async {
        await model.load(
            service: service, assetID: "synthetic-asset", groupID: "synthetic-group",
            expectedRunID: "synthetic-run", targetSize: CGSize(width: 320, height: 320), video: video
        )
    }
}

@MainActor
private final class PreviewTestService: HumanMediaServing {
    let imageResult = NSImage(size: CGSize(width: 4, height: 4))
    var hold = false
    var fail = false
    private var completion: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func image(assetID: String, groupID: String, expectedRunID: String, targetSize: CGSize) async throws -> NSImage {
        try await waitIfHeld()
        return imageResult
    }

    func playerItem(assetID: String, groupID: String, expectedRunID: String) async throws -> AVPlayerItem {
        try await waitIfHeld()
        return AVPlayerItem(asset: AVMutableComposition())
    }

    func waitUntilStarted() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        completion?.resume()
        completion = nil
    }

    private func waitIfHeld() async throws {
        if hold {
            await withCheckedContinuation {
                completion = $0
                started?.resume()
                started = nil
            }
        }
        if fail { throw NSError(domain: "synthetic-private", code: 1) }
    }
}
