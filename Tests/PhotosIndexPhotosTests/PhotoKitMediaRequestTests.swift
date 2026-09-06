import AppKit
import Photos
import XCTest
@testable import PhotosIndexPhotos

@MainActor
final class PhotoKitMediaRequestTests: XCTestCase {
    func testTargetSizeIsBoundedAndPreservesAspectRatio() throws {
        XCTAssertEqual(
            try PhotoKitMediaProvider.boundedTargetSize(CGSize(width: 8192, height: 4096)),
            CGSize(width: 4096, height: 2048)
        )
        XCTAssertEqual(
            try PhotoKitMediaProvider.boundedTargetSize(CGSize(width: 200, height: 400)),
            CGSize(width: 200, height: 400)
        )
        XCTAssertEqual(
            try PhotoKitMediaProvider.boundedTargetSize(CGSize(width: 0.5, height: 0.5)),
            CGSize(width: 1, height: 1)
        )
    }

    func testInvalidTargetSizesAreRejected() {
        for size in [
            CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: 10, height: -1),
            CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan),
        ] {
            XCTAssertThrowsError(try PhotoKitMediaProvider.boundedTargetSize(size)) {
                XCTAssertEqual($0 as? PhotoKitMediaError, .invalidTargetSize)
            }
        }
    }

    func testCallbackBeforeRequestIDAndDuplicateCallbacksCompleteOnce() async throws {
        let cancellations = MediaCancellationRecorder()
        let value = try await PhotoKitMediaRequest<Int>.value { request in
            request.receive(42, info: nil, unavailable: .imageUnavailable)
            request.receive(99, info: nil, unavailable: .imageUnavailable)
            request.cancel()
            return 7
        } cancel: { cancellations.record($0) }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(cancellations.ids, [])
    }

    func testDegradedCallbacksAreIgnoredUntilFinalImage() async throws {
        let value = try await PhotoKitMediaRequest<Int>.value { request in
            request.receive(1, info: [PHImageResultIsDegradedKey: true], unavailable: .imageUnavailable)
            request.receive(nil, info: [PHImageResultIsDegradedKey: true], unavailable: .imageUnavailable)
            request.receive(2, info: [PHImageResultIsDegradedKey: false], unavailable: .imageUnavailable)
            return 7
        } cancel: { _ in XCTFail("Completed request must not be cancelled") }
        XCTAssertEqual(value, 2)
    }

    func testPhotoKitErrorsAreSanitized() async {
        do {
            _ = try await PhotoKitMediaRequest<Int>.value { request in
                request.receive(1, info: [PHImageErrorKey: NSError(
                    domain: "synthetic-domain", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "synthetic-private-detail"]
                )], unavailable: .imageUnavailable)
                return 7
            } cancel: { _ in }
            XCTFail("Expected sanitized failure")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .requestFailed)
            XCTAssertFalse(String(describing: error).contains("synthetic-private-detail"))
        }
    }

    func testMissingFinalImageAndVideoUseTypedErrors() async {
        for unavailable in [PhotoKitMediaError.imageUnavailable, .videoUnavailable] {
            do {
                _ = try await PhotoKitMediaRequest<Int>.value { request in
                    request.receive(nil, info: nil, unavailable: unavailable)
                    return 7
                } cancel: { _ in }
                XCTFail("Expected missing media failure")
            } catch {
                XCTAssertEqual(error as? PhotoKitMediaError, unavailable)
            }
        }
    }

    func testCancelBeforeContinuationRegistration() async {
        let request = PhotoKitMediaRequest<Int>()
        request.cancel()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertFalse(request.install(continuation))
            } as Int
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
    }

    func testAlreadyCancelledTaskDoesNotStartRequest() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotoKitMediaRequest<Int>.value { _ in
                XCTFail("Already cancelled task must not request media")
                return 7
            } cancel: { _ in XCTFail("No PhotoKit request was started") }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
    }

    func testTaskCancellationBeforeRequestIDCancelsLateRegistration() async {
        let cancellations = MediaCancellationRecorder()
        let task = Task { @MainActor in
            try await PhotoKitMediaRequest<Int>.value { request in
                withUnsafeCurrentTask { $0?.cancel() }
                request.receive(42, info: nil, unavailable: .videoUnavailable)
                return 7
            } cancel: { cancellations.record($0) }
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
        XCTAssertEqual(cancellations.ids, [7])
    }

    func testTaskCancellationAfterRequestIDCancelsRequest() async {
        let cancellations = MediaCancellationRecorder()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            try await PhotoKitMediaRequest<Int>.value { _ in
                signal.yield(())
                signal.finish()
                return 7
            } cancel: { cancellations.record($0) }
        }
        for await _ in started { break }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
        XCTAssertEqual(cancellations.ids, [7])
    }

    func testPhotoKitCancellationBeforeRequestID() async {
        let cancellations = MediaCancellationRecorder()
        do {
            _ = try await PhotoKitMediaRequest<Int>.value { request in
                request.receive(nil, info: [PHImageCancelledKey: true], unavailable: .videoUnavailable)
                return 7
            } cancel: { cancellations.record($0) }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
        XCTAssertEqual(cancellations.ids, [7])
    }

    func testCancellationAllowsReentrantCallbackAndIgnoresLateResults() async {
        let request = PhotoKitMediaRequest<Int>()
        let cancellations = MediaCancellationRecorder()
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                XCTAssertTrue(request.install(continuation))
                request.registerCancellation {
                    cancellations.record(7)
                    request.receive(nil, info: [PHImageCancelledKey: true], unavailable: .imageUnavailable)
                }
                request.cancel()
                request.cancel()
                request.receive(42, info: nil, unavailable: .imageUnavailable)
            } as Int
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
        }
        XCTAssertEqual(cancellations.ids, [7])
    }

    func testConcurrentCancellationAndCompletionHaveOneWinner() async {
        for _ in 0..<100 {
            let request = PhotoKitMediaRequest<Int>()
            let cancellations = MediaCancellationRecorder()
            do {
                let value: Int = try await withCheckedThrowingContinuation { continuation in
                    XCTAssertTrue(request.install(continuation))
                    request.registerCancellation { cancellations.record(7) }
                    DispatchQueue.concurrentPerform(iterations: 8) { index in
                        if index.isMultiple(of: 2) {
                            request.cancel()
                        } else {
                            request.receive(42, info: nil, unavailable: .imageUnavailable)
                        }
                    }
                }
                XCTAssertEqual(value, 42)
                XCTAssertEqual(cancellations.ids, [])
            } catch {
                XCTAssertEqual(error as? PhotoKitMediaError, .cancelled)
                XCTAssertEqual(cancellations.ids, [7])
            }
        }
    }
}

private final class MediaCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIDs: [PHImageRequestID] = []

    var ids: [PHImageRequestID] {
        lock.lock()
        defer { lock.unlock() }
        return recordedIDs
    }

    func record(_ id: PHImageRequestID) {
        lock.lock()
        recordedIDs.append(id)
        lock.unlock()
    }
}
