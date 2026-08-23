import Foundation
import XCTest
@testable import PhotosIndexCore

final class ExampleFixtureTests: XCTestCase {
    func testPublicExampleFixturesDecode() throws {
        let examples = packageRoot.appendingPathComponent("Examples", isDirectory: true)

        _ = try CanonicalJSON.decode(
            GroupEvidencePacket.self,
            from: Data(contentsOf: examples.appendingPathComponent("evidence-packet.example.json"))
        )
        _ = try CanonicalJSON.decode(
            ModelDecision.self,
            from: Data(contentsOf: examples.appendingPathComponent("model-decision.example.json"))
        )
        _ = try CanonicalJSON.decode(
            ModelDecision.self,
            from: Data(
                contentsOf: examples.appendingPathComponent(
                    "model-decision-exclude-all.example.json"
                )
            )
        )
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
