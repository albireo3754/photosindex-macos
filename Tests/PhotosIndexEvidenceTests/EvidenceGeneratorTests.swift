import Foundation
import PhotosIndexCore
import XCTest
@testable import PhotosIndexEvidence

final class EvidenceGeneratorTests: XCTestCase {
    func testSamplingIsDeterministicMixedAndCappedAtTwelve() async throws {
        let assets = makeAssets(count: 20)
        let group = makeGroup(assets: assets)
        let firstDirectory = temporaryDirectory(named: "deterministic-first")
        let secondDirectory = temporaryDirectory(named: "deterministic-second")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let generator = EvidenceGenerator(
            imageProvider: StubImageProvider(),
            analyzer: StubAnalyzer()
        )
        let first = try await generator.generate(
            EvidenceGenerationRequest(
                indexRunID: "run-deterministic",
                timezone: "Asia/Seoul",
                group: group,
                assets: assets,
                outputDirectory: firstDirectory,
                generatedAt: fixedDate
            )
        )
        let second = try await generator.generate(
            EvidenceGenerationRequest(
                indexRunID: "run-deterministic",
                timezone: "Asia/Seoul",
                group: group,
                assets: Array(assets.reversed()),
                outputDirectory: secondDirectory,
                generatedAt: fixedDate
            )
        )

        XCTAssertEqual(first.packet.samples.count, 12)
        XCTAssertEqual(
            first.packet.samples.map(\.assetID),
            second.packet.samples.map(\.assetID)
        )
        XCTAssertEqual(
            Set(first.packet.samples.map { $0.kind.rawValue }),
            Set([EvidenceSampleKind.photoThumbnail.rawValue, EvidenceSampleKind.videoFrame.rawValue])
        )
        XCTAssertEqual(try Data(contentsOf: first.evidenceJSONURL), try Data(contentsOf: second.evidenceJSONURL))
        XCTAssertEqual(first.sampleURLs.count, 12)
        XCTAssertTrue(first.sampleURLs.allSatisfy { $0.pathExtension == "jpg" })
    }

    func testOCRRedactionPreservesFoodAndPlaceTerms() async throws {
        let asset = makeAsset(index: 0, mediaKind: .photo)
        let directory = temporaryDirectory(named: "redaction")
        defer { try? FileManager.default.removeItem(at: directory) }
        let analyzer = StubAnalyzer(
            analysis: EvidenceAnalysis(
                ocr: [
                    OCRObservation(
                        text: "샘플 음식점 owner@example.com 010-0000-0000 주문 123456789",
                        confidence: 0.96
                    )
                ],
                faceCount: 0
            )
        )
        let result = try await EvidenceGenerator(
            imageProvider: StubImageProvider(),
            analyzer: analyzer
        ).generate(
            EvidenceGenerationRequest(
                indexRunID: "run-redaction",
                timezone: "Asia/Seoul",
                group: makeGroup(assets: [asset]),
                assets: [asset],
                outputDirectory: directory,
                generatedAt: fixedDate
            )
        )

        let rendered = try outputText(for: result)
        XCTAssertTrue(rendered.contains("샘플 음식점"))
        XCTAssertTrue(rendered.contains("[REDACTED_EMAIL]"))
        XCTAssertTrue(rendered.contains("[REDACTED_PHONE]"))
        XCTAssertTrue(rendered.contains("[REDACTED_ID]"))
        XCTAssertFalse(rendered.contains("owner@example.com"))
        XCTAssertFalse(rendered.contains("010-0000-0000"))
        XCTAssertFalse(rendered.contains("123456789"))
    }

    func testOutputsExcludePrivateSourceIdentifierAndExactLocation() async throws {
        let asset = EvidenceSourceAsset(
            id: "ast_public",
            sourceIdentifier: "private-local-id?lat=10.123456&lon=20.654321",
            capturedAt: fixedDate,
            mediaKind: .photo,
            durationSeconds: 0,
            pixelWidth: 4032,
            pixelHeight: 3024,
            hasLocation: true,
            publicFilename: "IMG_0001.HEIC"
        )
        let directory = temporaryDirectory(named: "privacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await EvidenceGenerator(
            imageProvider: StubImageProvider(),
            analyzer: StubAnalyzer()
        ).generate(
            EvidenceGenerationRequest(
                indexRunID: "run-privacy",
                timezone: "Asia/Seoul",
                group: makeGroup(assets: [asset]),
                assets: [asset],
                outputDirectory: directory,
                generatedAt: fixedDate
            )
        )

        let rendered = try outputText(for: result)
        XCTAssertFalse(rendered.contains("private-local-id"))
        XCTAssertFalse(rendered.contains("10.123456"))
        XCTAssertFalse(rendered.contains("20.654321"))
        XCTAssertTrue(rendered.contains("\"hasLocation\":true"))
    }

    func testProviderFailureProducesPartialPacketAndWarning() async throws {
        let assets = [
            makeAsset(index: 0, mediaKind: .photo),
            makeAsset(index: 1, mediaKind: .video),
            makeAsset(index: 2, mediaKind: .photo),
        ]
        let failedID = assets[1].id
        let directory = temporaryDirectory(named: "partial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await EvidenceGenerator(
            imageProvider: StubImageProvider(failingAssetIDs: [failedID]),
            analyzer: StubAnalyzer()
        ).generate(
            EvidenceGenerationRequest(
                indexRunID: "run-partial",
                timezone: "Asia/Seoul",
                group: makeGroup(assets: assets),
                assets: assets,
                outputDirectory: directory,
                generatedAt: fixedDate
            )
        )

        XCTAssertEqual(result.packet.samples.count, 2)
        XCTAssertFalse(result.packet.samples.contains { $0.assetID == failedID })
        XCTAssertTrue(result.packet.warnings.contains("sample-generation-failed:\(failedID)"))
        XCTAssertEqual(result.packet.warnings.filter { $0 == "partial-evidence" }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.evidenceJSONURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.summaryURL.path))
    }

    func testGeneratesIndependentAssetsConcurrently() async throws {
        let assets = makeAssets(count: 4)
        let directory = temporaryDirectory(named: "concurrent")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ConcurrencyProbeImageProvider()

        _ = try await EvidenceGenerator(
            imageProvider: provider,
            analyzer: StubAnalyzer()
        ).generate(
            EvidenceGenerationRequest(
                indexRunID: "run-concurrent",
                timezone: "Asia/Seoul",
                group: makeGroup(assets: assets),
                assets: assets,
                outputDirectory: directory,
                generatedAt: fixedDate
            )
        )

        let maximumConcurrentRequests = await provider.maximumConcurrentRequests
        XCTAssertGreaterThan(maximumConcurrentRequests, 1)
    }

    func testRequestsOnePreviewPerAssetWithoutDuplicateVideoPositions() async throws {
        let assets = [
            makeAsset(index: 0, mediaKind: .photo),
            makeAsset(index: 1, mediaKind: .video),
            makeAsset(index: 2, mediaKind: .video),
        ]
        let directory = temporaryDirectory(named: "one-preview-per-asset")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = CountingImageProvider()

        let result = try await EvidenceGenerator(
            imageProvider: provider,
            analyzer: StubAnalyzer()
        ).generate(
            EvidenceGenerationRequest(
                indexRunID: "run-one-preview",
                timezone: "Asia/Seoul",
                group: makeGroup(assets: assets),
                assets: assets,
                outputDirectory: directory,
                generatedAt: fixedDate
            )
        )

        XCTAssertEqual(result.packet.samples.map(\.assetID), assets.map(\.id))
        XCTAssertTrue(result.packet.samples.allSatisfy { $0.position == nil })
        for asset in assets {
            let requestCount = await provider.requestCount(for: asset.id)
            XCTAssertEqual(requestCount, 1)
        }
    }

    private var fixedDate: Date {
        Date(timeIntervalSince1970: 1_768_446_000)
    }

    private func makeAssets(count: Int) -> [EvidenceSourceAsset] {
        (0..<count).map { index in
            makeAsset(index: index, mediaKind: index.isMultiple(of: 2) ? .photo : .video)
        }
    }

    private func makeAsset(index: Int, mediaKind: MediaKind) -> EvidenceSourceAsset {
        EvidenceSourceAsset(
            id: String(format: "ast_%03d", index),
            sourceIdentifier: "private-source-\(index)",
            capturedAt: fixedDate.addingTimeInterval(Double(index * 60)),
            mediaKind: mediaKind,
            durationSeconds: mediaKind == .video ? 10 : 0,
            pixelWidth: 1920,
            pixelHeight: 1080,
            hasLocation: true,
            publicFilename: String(format: "IMG_%04d.%@", index, mediaKind == .video ? "MOV" : "HEIC")
        )
    }

    private func makeGroup(assets: [EvidenceSourceAsset]) -> CaptureGroup {
        let sorted = assets.sorted { $0.id < $1.id }
        return CaptureGroup(
            id: "grp_test",
            level: .fine,
            localDate: "2026-01-15",
            start: sorted.compactMap(\.capturedAt).first,
            end: sorted.compactMap(\.capturedAt).last,
            assetIDs: sorted.map(\.id),
            warnings: []
        )
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotosIndexEvidenceTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func outputText(for result: EvidenceGenerationResult) throws -> String {
        let json = try String(contentsOf: result.evidenceJSONURL, encoding: .utf8)
        let summary = try String(contentsOf: result.summaryURL, encoding: .utf8)
        return json + "\n" + summary
    }
}

private struct StubImageProvider: EvidenceImageProviding {
    let failingAssetIDs: Set<String>

    init(failingAssetIDs: Set<String> = []) {
        self.failingAssetIDs = failingAssetIDs
    }

    func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data {
        if failingAssetIDs.contains(asset.id) {
            throw StubError.imageUnavailable
        }
        return Data("jpeg:\(asset.id):\(position ?? -1)".utf8)
    }
}

private struct StubAnalyzer: EvidenceAnalyzing {
    let analysis: EvidenceAnalysis

    init(analysis: EvidenceAnalysis = EvidenceAnalysis(ocr: [], faceCount: 0)) {
        self.analysis = analysis
    }

    func analyze(jpegData: Data) async throws -> EvidenceAnalysis {
        analysis
    }
}

private actor ConcurrencyProbeImageProvider: EvidenceImageProviding {
    private var activeRequests = 0
    private(set) var maximumConcurrentRequests = 0

    func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data {
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        try await Task.sleep(nanoseconds: 50_000_000)
        activeRequests -= 1
        return Data("jpeg:\(asset.id)".utf8)
    }
}

private actor CountingImageProvider: EvidenceImageProviding {
    private var requestCounts: [String: Int] = [:]

    func jpegData(for asset: EvidenceSourceAsset, position: Double?) async throws -> Data {
        requestCounts[asset.id, default: 0] += 1
        return Data("jpeg:\(asset.id)".utf8)
    }

    func requestCount(for assetID: String) -> Int {
        requestCounts[assetID, default: 0]
    }
}

private enum StubError: Error {
    case imageUnavailable
}
