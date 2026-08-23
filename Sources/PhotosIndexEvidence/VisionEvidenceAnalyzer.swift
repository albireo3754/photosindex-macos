import Foundation
import PhotosIndexCore
import Vision

public struct VisionEvidenceAnalyzer: EvidenceAnalyzing, Sendable {
    private let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["ko-KR", "en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func analyze(jpegData: Data) async throws -> EvidenceAnalysis {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.recognitionLanguages = recognitionLanguages
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(data: jpegData, options: [:])
        try handler.perform([textRequest, faceRequest])

        let textObservations = (textRequest.results ?? []).sorted { left, right in
            if left.boundingBox.midY != right.boundingBox.midY {
                return left.boundingBox.midY > right.boundingBox.midY
            }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        let ocr = textObservations.compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return OCRObservation(text: text, confidence: Double(candidate.confidence))
        }
        return EvidenceAnalysis(ocr: ocr, faceCount: faceRequest.results?.count ?? 0)
    }
}
