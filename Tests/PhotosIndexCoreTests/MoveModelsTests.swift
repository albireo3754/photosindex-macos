import Foundation
import XCTest
@testable import PhotosIndexCore

final class MoveModelsTests: XCTestCase {
    func testMoveDigestIsDomainSeparatedFromCopyOnlyExport() throws {
        let exportPlan = makeExportPlan(included: ["ast_1"])
        let movePlan = MovePlan(
            exportPlan: exportPlan,
            operation: .deleteSourceAfterVerifiedUpload
        )

        let moveDigest = try MovePlanIntegrity.sha256(movePlan)

        XCTAssertNoThrow(try MovePlanIntegrity.verify(movePlan, digest: moveDigest))
        XCTAssertEqual(moveDigest.count, 64)
        XCTAssertNotEqual(moveDigest, try ExportPlanIntegrity.sha256(exportPlan))
    }

    func testMoveDigestRejectsTamperedSelection() throws {
        let original = MovePlan(
            exportPlan: makeExportPlan(included: ["ast_1"]),
            operation: .deleteSourceAfterVerifiedUpload
        )
        let tampered = MovePlan(
            exportPlan: makeExportPlan(included: ["ast_2"]),
            operation: .deleteSourceAfterVerifiedUpload
        )
        let digest = try MovePlanIntegrity.sha256(original)

        XCTAssertThrowsError(try MovePlanIntegrity.verify(tampered, digest: digest)) { error in
            guard case MovePlanIntegrityError.digestMismatch = error else {
                return XCTFail("Expected digest mismatch, got \(error)")
            }
        }
    }

    func testMoveReceiptRoundTripsOnlyPublicDeletionIdentifiers() throws {
        let exportReceipt = ExportReceipt(
            indexRunID: "run_test",
            groupID: "segment_test",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            destinationRoot: "/tmp/Naver Clip/2026-01-15_test",
            stagingRoot: "/tmp/PhotosIndex/run_test/segment_test",
            entries: [
                ExportReceiptEntry(
                    assetID: "ast_1",
                    safeFilename: "IMG_0001.JPG",
                    mediaKind: .photo,
                    bytes: 5,
                    sha256: String(repeating: "a", count: 64),
                    relativePath: "originals/IMG_0001.JPG",
                    reused: false
                )
            ],
            warnings: []
        )
        let receipt = MoveReceipt(
            exportReceipt: exportReceipt,
            deletedAssetIDs: ["ast_1"],
            completedAt: Date(timeIntervalSince1970: 2_000),
            warnings: []
        )

        let encoded = try CanonicalJSON.encode(receipt)
        let decoded = try CanonicalJSON.decode(MoveReceipt.self, from: encoded)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded, receipt)
        XCTAssertFalse(text.contains("localIdentifier"))
    }

    private func makeExportPlan(included: [String]) -> ExportPlan {
        ExportPlan(
            indexRunID: "run_test",
            groupID: "segment_test",
            generatedAt: Date(timeIntervalSince1970: 1_000),
            destinationRoot: "/tmp/Naver Clip/2026-01-15_test",
            stagingRoot: "/tmp/PhotosIndex/run_test/segment_test",
            groupAssetIDs: ["ast_1", "ast_2"],
            includedAssetIDs: included,
            excludedAssetIDs: ["ast_1", "ast_2"].filter { !included.contains($0) },
            label: "test",
            confidence: 0.95,
            warnings: []
        )
    }
}
