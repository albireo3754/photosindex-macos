import Foundation
import PhotosIndexCore

public struct EvidenceGenerator: Sendable {
    private let imageProvider: any EvidenceImageProviding
    private let analyzer: any EvidenceAnalyzing

    public init(
        imageProvider: any EvidenceImageProviding,
        analyzer: any EvidenceAnalyzing
    ) {
        self.imageProvider = imageProvider
        self.analyzer = analyzer
    }

    public func generate(_ request: EvidenceGenerationRequest) async throws -> EvidenceGenerationResult {
        let fileManager = FileManager.default
        let samplesDirectory = request.outputDirectory.appendingPathComponent("samples", isDirectory: true)
        try fileManager.createDirectory(at: samplesDirectory, withIntermediateDirectories: true)

        let groupIDs = Set(request.group.assetIDs)
        let expectedIDs = Set(request.expectedAssetIDs)
        let eligibleAssets = uniqueSorted(request.assets.filter {
            groupIDs.contains($0.id) && expectedIDs.contains($0.id)
        })
        var warnings = request.group.warnings
        let providedIDs = Set(eligibleAssets.map(\.id))
        warnings.append(contentsOf: request.expectedAssetIDs
            .filter { !providedIDs.contains($0) }
            .map { "missing-asset:\($0)" })

        let candidates = sampleCandidates(from: eligibleAssets, limit: request.maxSamples)
        let outcomes = try await generateSamples(
            candidates,
            samplesDirectory: samplesDirectory
        )
        let samples = outcomes.compactMap(\.sample)
        let sampleURLs = outcomes.compactMap(\.sampleURL)
        for outcome in outcomes {
            warnings.append(contentsOf: outcome.warnings)
        }
        let isPartial = outcomes.contains(where: \.isPartial)
        if isPartial, !warnings.contains("partial-evidence") {
            warnings.append("partial-evidence")
        }
        try Task.checkCancellation()

        let packet = GroupEvidencePacket(
            schemaVersion: 1,
            indexRunID: request.indexRunID,
            generatedAt: request.generatedAt,
            timezone: request.timezone,
            group: request.group,
            assets: eligibleAssets.map(\.publicMetadata),
            samples: samples,
            warnings: warnings
        )
        let evidenceJSONURL = request.outputDirectory.appendingPathComponent("evidence.json")
        let summaryURL = request.outputDirectory.appendingPathComponent("summary.md")
        try CanonicalJSON.encode(packet).write(to: evidenceJSONURL, options: .atomic)
        try summary(for: packet).write(to: summaryURL, atomically: true, encoding: .utf8)

        return EvidenceGenerationResult(
            packet: packet,
            evidenceJSONURL: evidenceJSONURL,
            summaryURL: summaryURL,
            sampleURLs: sampleURLs
        )
    }

    private func generateSamples(
        _ candidates: [SampleCandidate],
        samplesDirectory: URL
    ) async throws -> [SampleOutcome] {
        let maximumConcurrentRequests = 4
        return try await withThrowingTaskGroup(
            of: SampleOutcome.self,
            returning: [SampleOutcome].self
        ) { group in
            var nextOffset = 0
            while nextOffset < min(maximumConcurrentRequests, candidates.count) {
                let offset = nextOffset
                let candidate = candidates[offset]
                group.addTask {
                    try await generateSample(
                        offset: offset,
                        candidate: candidate,
                        samplesDirectory: samplesDirectory
                    )
                }
                nextOffset += 1
            }

            var outcomes: [SampleOutcome] = []
            outcomes.reserveCapacity(candidates.count)
            while let outcome = try await group.next() {
                outcomes.append(outcome)
                if nextOffset < candidates.count {
                    let offset = nextOffset
                    let candidate = candidates[offset]
                    group.addTask {
                        try await generateSample(
                            offset: offset,
                            candidate: candidate,
                            samplesDirectory: samplesDirectory
                        )
                    }
                    nextOffset += 1
                }
            }
            return outcomes.sorted { $0.ordinal < $1.ordinal }
        }
    }

    private func generateSample(
        offset: Int,
        candidate: SampleCandidate,
        samplesDirectory: URL
    ) async throws -> SampleOutcome {
        try Task.checkCancellation()
        let ordinal = offset + 1
        let sampleID = String(format: "sample-%03d", ordinal)
        let filename = String(format: "%03d.jpg", ordinal)
        let relativePath = "samples/\(filename)"
        let sampleURL = samplesDirectory.appendingPathComponent(filename, isDirectory: false)

        let imageData: Data
        do {
            imageData = try await imageProvider.jpegData(
                for: candidate.asset,
                position: candidate.positionSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SampleOutcome(
                ordinal: ordinal,
                sample: nil,
                sampleURL: nil,
                warnings: ["sample-generation-failed:\(candidate.asset.id)"],
                isPartial: true
            )
        }
        try imageData.write(to: sampleURL, options: .atomic)

        let analysis: EvidenceAnalysis
        var outcomeWarnings: [String] = []
        do {
            analysis = try await analyzer.analyze(jpegData: imageData)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            outcomeWarnings.append("analysis-failed:\(candidate.asset.id):\(sampleID)")
            analysis = EvidenceAnalysis(ocr: [], faceCount: 0)
        }
        let redactedOCR = analysis.ocr.map {
            OCRObservation(
                text: EvidenceRedactor.redact($0.text),
                confidence: $0.confidence
            )
        }
        return SampleOutcome(
            ordinal: ordinal,
            sample: EvidenceSample(
                id: sampleID,
                assetID: candidate.asset.id,
                kind: candidate.asset.mediaKind == .photo ? .photoThumbnail : .videoFrame,
                relativePath: relativePath,
                position: candidate.positionSeconds,
                ocr: redactedOCR,
                privacyFlags: analysis.privacyFlags
            ),
            sampleURL: sampleURL,
            warnings: outcomeWarnings,
            isPartial: !outcomeWarnings.isEmpty
        )
    }

    private func uniqueSorted(_ assets: [EvidenceSourceAsset]) -> [EvidenceSourceAsset] {
        var seen: Set<String> = []
        return assets
            .sorted(by: Self.assetOrdering)
            .filter { seen.insert($0.id).inserted }
    }

    private func sampleCandidates(
        from assets: [EvidenceSourceAsset],
        limit: Int
    ) -> [SampleCandidate] {
        guard limit > 0, !assets.isEmpty else { return [] }
        let baseAssets = mixedAssets(from: assets, limit: min(limit, assets.count))
        return baseAssets.map { asset in
            SampleCandidate(
                asset: asset,
                positionSeconds: nil
            )
        }
    }

    private func mixedAssets(from assets: [EvidenceSourceAsset], limit: Int) -> [EvidenceSourceAsset] {
        guard assets.count > limit else { return assets }
        let photos = assets.filter { $0.mediaKind == .photo }
        let videos = assets.filter { $0.mediaKind == .video }
        guard limit >= 2, !photos.isEmpty, !videos.isEmpty else {
            return evenlySample(assets, count: limit)
        }

        var photoCount = 1
        var videoCount = 1
        var preferPhoto = assets.first?.mediaKind == .photo
        while photoCount + videoCount < limit {
            if preferPhoto, photoCount < photos.count {
                photoCount += 1
            } else if !preferPhoto, videoCount < videos.count {
                videoCount += 1
            } else if photoCount < photos.count {
                photoCount += 1
            } else if videoCount < videos.count {
                videoCount += 1
            }
            preferPhoto.toggle()
        }
        return (evenlySample(photos, count: photoCount) + evenlySample(videos, count: videoCount))
            .sorted(by: Self.assetOrdering)
    }

    private func evenlySample(
        _ assets: [EvidenceSourceAsset],
        count: Int
    ) -> [EvidenceSourceAsset] {
        guard count > 0 else { return [] }
        guard count < assets.count else { return assets }
        guard count > 1 else { return [assets[0]] }
        return (0..<count).map { offset in
            let position = Double(offset) * Double(assets.count - 1) / Double(count - 1)
            return assets[Int(position.rounded())]
        }
    }

    private func summary(for packet: GroupEvidencePacket) -> String {
        var lines = [
            "# PhotosIndex Evidence",
            "",
            "- Index run: `\(packet.indexRunID)`",
            "- Group: `\(packet.group.id)`",
            "- Local date: \(packet.group.localDate)",
            "- Timezone: \(packet.timezone)",
            "- Assets: \(packet.assets.count)",
            "- Samples: \(packet.samples.count)",
            "",
            "## Samples",
            "",
        ]
        if packet.samples.isEmpty {
            lines.append("- No samples were available.")
        } else {
            for sample in packet.samples {
                let texts = sample.ocr
                    .map { $0.text.replacingOccurrences(of: "\n", with: " ") }
                    .filter { !$0.isEmpty }
                    .joined(separator: " | ")
                let suffix = texts.isEmpty ? "" : " — OCR: \(texts)"
                lines.append("- `\(sample.relativePath)` — \(sample.kind.rawValue)\(suffix)")
            }
        }
        lines.append(contentsOf: ["", "## Warnings", ""])
        if packet.warnings.isEmpty {
            lines.append("- None")
        } else {
            lines.append(contentsOf: packet.warnings.map { "- \($0)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func assetOrdering(_ lhs: EvidenceSourceAsset, _ rhs: EvidenceSourceAsset) -> Bool {
        switch (lhs.capturedAt, rhs.capturedAt) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

}

private struct SampleCandidate: Sendable {
    let asset: EvidenceSourceAsset
    let positionSeconds: Double?
}

private struct SampleOutcome: Sendable {
    let ordinal: Int
    let sample: EvidenceSample?
    let sampleURL: URL?
    let warnings: [String]
    let isPartial: Bool
}
