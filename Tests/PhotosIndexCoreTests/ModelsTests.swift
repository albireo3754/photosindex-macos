import Foundation
import XCTest
@testable import PhotosIndexCore

final class ModelsTests: XCTestCase {
    func testEvidencePacketCanonicalJSONIsStableAndPrivate() throws {
        let group = CaptureGroup(
            id: "grp_fine_1",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: Date(timeIntervalSince1970: 100),
            end: Date(timeIntervalSince1970: 200),
            assetIDs: ["asset_1"],
            warnings: []
        )
        let packet = GroupEvidencePacket(
            schemaVersion: 1,
            indexRunID: "run_1",
            generatedAt: Date(timeIntervalSince1970: 300),
            timezone: "Asia/Seoul",
            group: group,
            assets: [
                EvidenceAsset(
                    id: "asset_1",
                    capturedAt: Date(timeIntervalSince1970: 100),
                    mediaKind: .photo,
                    durationSeconds: 0,
                    pixelWidth: 4032,
                    pixelHeight: 3024,
                    hasLocation: true,
                    publicFilename: "IMG_1234.HEIC"
                )
            ],
            samples: [],
            warnings: []
        )

        let first = try CanonicalJSON.encode(packet)
        let second = try CanonicalJSON.encode(packet)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))

        XCTAssertEqual(first, second)
        XCTAssertFalse(text.contains("localIdentifier"))
        XCTAssertFalse(text.contains("latitude"))
        XCTAssertFalse(text.contains("longitude"))
    }

    func testDecisionRejectsConfidenceOutsideUnitInterval() {
        XCTAssertThrowsError(
            try ModelDecision(
                schemaVersion: 1,
                indexRunID: "run_1",
                groupID: "grp_1",
                label: "sample-restaurant",
                confidence: 1.1,
                includedAssetIDs: [],
                excludedAssetIDs: [],
                evidenceReferences: [],
                unknowns: []
            )
        )
    }

    func testCaptureGroupDecodesLegacyPayloadWithoutMediaKind() throws {
        let data = Data(
            #"{"assetIDs":["ast_synthetic"],"end":null,"id":"segment_synthetic","level":"fine","localDate":"2026-01-15","start":null,"warnings":[]}"#.utf8
        )

        let group = try CanonicalJSON.decode(CaptureGroup.self, from: data)

        XCTAssertEqual(group.level, .fine)
        XCTAssertNil(group.mediaKind)
    }

    func testCaptureGroupLegacyInitializerDefaultsMediaKindToNil() {
        let group = CaptureGroup(
            id: "segment_synthetic",
            level: .fine,
            localDate: "2026-01-15",
            start: nil,
            end: nil,
            assetIDs: ["ast_synthetic"],
            warnings: []
        )

        XCTAssertNil(group.mediaKind)
    }
}
