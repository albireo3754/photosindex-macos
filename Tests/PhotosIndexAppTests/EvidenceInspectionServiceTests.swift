import Foundation
import PhotosIndexCore
import PhotosIndexEvidence
import PhotosIndexPhotos
import XCTest
@testable import PhotosIndexApp

final class EvidenceInspectionServiceTests: XCTestCase {
    func testInspectCancelsAndReturnsTypedTimeoutWhenGenerationDoesNotFinish() throws {
        let provider = BlockingEvidenceProvider()
        let generator = EvidenceGenerator(
            imageProvider: provider,
            analyzer: EmptyEvidenceAnalyzer()
        )
        let service = EvidenceInspectionService(generator: generator, timeout: 0.05)
        let asset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "timeout-photo",
                capturedAt: Date(timeIntervalSince1970: 1_000),
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 100,
                pixelHeight: 100,
                coordinate: nil,
                originalFilename: "IMG_1000.JPG"
            )
        )
        let group = CaptureGroup(
            id: "segment_timeout",
            level: .fine,
            localDate: "2026-01-15",
            start: asset.capturedAt,
            end: asset.capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexEvidenceTimeoutTests-\(UUID().uuidString)")
        defer {
            provider.release()
            provider.waitUntilFinished()
            try? FileManager.default.removeItem(at: output)
        }

        let started = Date()
        XCTAssertThrowsError(
            try service.inspect(
                indexRunID: "run_timeout",
                group: group,
                assets: [asset],
                outputDirectory: output,
                maxSamples: 1,
                page: try EvidencePage.make(
                    groupAssetIDs: group.assetIDs,
                    pageNumber: 1,
                    pageSize: 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? EvidenceInspectionServiceError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}

private final class BlockingEvidenceProvider: EvidenceImageProviding, @unchecked Sendable {
    private let gate = AsyncGate()
    private let finished = DispatchSemaphore(value: 0)

    func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data {
        defer { finished.signal() }
        await gate.wait()
        try Task.checkCancellation()
        return Data()
    }

    func release() {
        Task { await gate.release() }
    }

    func waitUntilFinished() {
        _ = finished.wait(timeout: .now() + 1)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct EmptyEvidenceAnalyzer: EvidenceAnalyzing {
    func analyze(jpegData: Data) async throws -> EvidenceAnalysis {
        EvidenceAnalysis(ocr: [], faceCount: 0)
    }
}
