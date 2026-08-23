import Foundation
import PhotosIndexCore
import PhotosIndexEvidence
import PhotosIndexPhotos

enum EvidenceInspectionServiceError: Error, Equatable {
    case timedOut
}

struct EvidenceInspectionService: Sendable {
    private let generator: EvidenceGenerator
    private let timeout: TimeInterval

    init(
        generator: EvidenceGenerator = EvidenceGenerator(
            imageProvider: PhotoKitEvidenceImageProvider(),
            analyzer: VisionEvidenceAnalyzer()
        ),
        timeout: TimeInterval = 600
    ) {
        self.generator = generator
        self.timeout = max(0.01, timeout)
    }

    func inspect(
        indexRunID: String,
        group: CaptureGroup,
        assets: [PhotoAsset],
        outputDirectory: URL,
        maxSamples: Int,
        page: EvidencePage
    ) throws -> EvidenceInspectionPayload {
        let box = BlockingResult<EvidenceGenerationResult>()
        let semaphore = DispatchSemaphore(value: 0)
        let request = EvidenceGenerationRequest(
            indexRunID: indexRunID,
            timezone: "Asia/Seoul",
            group: group,
            assets: assets.map(EvidenceSourceAsset.init(photoAsset:)),
            outputDirectory: outputDirectory,
            maxSamples: maxSamples,
            expectedAssetIDs: page.assetIDs
        )
        let task = Task.detached {
            do {
                let result = try await generator.generate(request)
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            task.cancel()
            throw EvidenceInspectionServiceError.timedOut
        }
        let result = try box.take().get()
        return EvidenceInspectionPayload(
            indexRunID: indexRunID,
            groupID: group.id,
            outputDirectory: outputDirectory.path,
            evidenceJSON: result.evidenceJSONURL.path,
            summaryMarkdown: result.summaryURL.path,
            sampleFiles: result.sampleURLs.map(\.path),
            packet: result.packet,
            page: page
        )
    }
}

private final class BlockingResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<Value, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(BlockingResultError.missingResult)
    }
}

private enum BlockingResultError: Error {
    case missingResult
}
