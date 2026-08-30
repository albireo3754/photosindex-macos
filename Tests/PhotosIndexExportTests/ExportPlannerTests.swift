import Foundation
import XCTest
@testable import PhotosIndexExport

final class ExportPlannerTests: XCTestCase {
    private let planner = ExportPlanner()
    private let destinationRoot = URL(fileURLWithPath: "/tmp/photosindex-destination", isDirectory: true)
    private let stagingRoot = URL(fileURLWithPath: "/tmp/photosindex-staging", isDirectory: true)

    func testPlannerAcceptsCompletePartitionAndCanonicalizesOrder() throws {
        let assets = [
            makeAsset(localIdentifier: "photo-a", filename: "IMG_1001.HEIC"),
            makeAsset(localIdentifier: "photo-b", filename: "IMG_1002.HEIC"),
            makeAsset(localIdentifier: "photo-c", filename: "IMG_1003.HEIC"),
        ]
        let group = makeGroup(from: assets, warnings: ["some_assets_without_location"])
        let decision = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: [assets[2].id, assets[0].id],
            excluded: [assets[1].id],
            confidence: 0.92,
            unknowns: []
        )

        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(plan.indexRunID, "run_20260816")
        XCTAssertEqual(plan.groupID, group.id)
        XCTAssertEqual(plan.groupAssetIDs, assets.map(\.id))
        XCTAssertEqual(plan.includedAssetIDs, [assets[0].id, assets[2].id])
        XCTAssertEqual(plan.excludedAssetIDs, [assets[1].id])
        XCTAssertEqual(plan.confidence, 0.92)
        XCTAssertEqual(plan.warnings, ["some_assets_without_location"])

        let encoded = try CanonicalJSON.encode(plan)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"groupAssetIDs\""))
        XCTAssertTrue(text.contains("\"includedAssetIDs\""))
        let digest = try ExportPlanIntegrity.sha256(plan)
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, try ExportPlanIntegrity.sha256(plan))
    }

    func testPlannerRejectsRunMismatchLowConfidenceUnknownsAndDuplicatePartition() throws {
        let asset = makeAsset(localIdentifier: "photo-a", filename: "IMG_1001.HEIC")
        let group = makeGroup(from: [asset], warnings: [])

        let mismatchedRun = try makeDecision(
            runID: "run_wrong",
            groupID: group.id,
            included: [asset.id],
            excluded: [],
            confidence: 0.95,
            unknowns: []
        )

        XCTAssertThrowsError(
            try planner.makePlan(
                currentIndexRunID: "run_20260816",
                decision: mismatchedRun,
                group: group,
                assets: [asset],
                destinationRoot: destinationRoot,
                stagingRoot: stagingRoot
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .indexRunMismatch(expected: "run_20260816", actual: "run_wrong"))
        }

        let lowConfidence = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: [asset.id],
            excluded: [],
            confidence: 0.4,
            unknowns: []
        )

        XCTAssertThrowsError(
            try planner.makePlan(
                currentIndexRunID: "run_20260816",
                decision: lowConfidence,
                group: group,
                assets: [asset],
                destinationRoot: destinationRoot,
                stagingRoot: stagingRoot
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .lowConfidence(actual: 0.4, minimum: 0.8))
        }

        let unknowns = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: [asset.id],
            excluded: [],
            confidence: 0.9,
            unknowns: ["uncertain-sign"]
        )

        XCTAssertThrowsError(
            try planner.makePlan(
                currentIndexRunID: "run_20260816",
                decision: unknowns,
                group: group,
                assets: [asset],
                destinationRoot: destinationRoot,
                stagingRoot: stagingRoot
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .unknownsNotAllowed(["uncertain-sign"]))
        }

        let duplicatePartition = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: [asset.id, asset.id],
            excluded: [],
            confidence: 0.9,
            unknowns: []
        )

        XCTAssertThrowsError(
            try planner.makePlan(
                currentIndexRunID: "run_20260816",
                decision: duplicatePartition,
                group: group,
                assets: [asset],
                destinationRoot: destinationRoot,
                stagingRoot: stagingRoot
            )
        ) { error in
            XCTAssertEqual(error as? ExportError, .duplicateAssetIDs([asset.id]))
        }
    }

    func testPlannerAcceptsSelectionAcrossMultipleBoundedEvidencePages() throws {
        let assets = (0..<24).map {
            makeAsset(localIdentifier: "photo-\($0)", filename: String(format: "IMG_%04d.HEIC", $0))
        }
        let group = makeGroup(from: assets, warnings: [])
        let decision = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: assets.map(\.id),
            excluded: [],
            confidence: 0.95,
            unknowns: []
        )

        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot
        )

        XCTAssertEqual(plan.includedAssetIDs.count, 24)
    }

    func testPlannerAcceptsLargeExplicitSelection() throws {
        let assets = (0..<240).map {
            makeAsset(localIdentifier: "photo-\($0)", filename: String(format: "IMG_%04d.HEIC", $0))
        }
        let group = makeGroup(from: assets, warnings: [])
        let decision = try makeDecision(
            runID: "run_20260816",
            groupID: group.id,
            included: assets.map(\.id),
            excluded: [],
            confidence: 0.95,
            unknowns: []
        )

        let plan = try planner.makePlan(
            currentIndexRunID: "run_20260816",
            decision: decision,
            group: group,
            assets: assets,
            destinationRoot: destinationRoot,
            stagingRoot: stagingRoot
        )

        XCTAssertEqual(plan.includedAssetIDs.count, 240)
    }

    private func makeDecision(
        runID: String,
        groupID: String,
        included: [String],
        excluded: [String],
        confidence: Double,
        unknowns: [String]
    ) throws -> ModelDecision {
        try ModelDecision(
            schemaVersion: 1,
            indexRunID: runID,
            groupID: groupID,
            label: "sample-restaurant",
            confidence: confidence,
            includedAssetIDs: included,
            excludedAssetIDs: excluded,
            evidenceReferences: ["manifest.json"],
            unknowns: unknowns
        )
    }

    private func makeGroup(from assets: [PhotoAsset], warnings: [String]) -> CaptureGroup {
        let capturedDates = assets.compactMap(\.capturedAt).sorted()
        return CaptureGroup(
            id: "grp_20260816_01",
            level: .fine,
            mediaKind: nil,
            localDate: "2026-01-15",
            start: capturedDates.first,
            end: capturedDates.last,
            assetIDs: assets.map(\.id),
            warnings: warnings
        )
    }

    private func makeAsset(localIdentifier: String, filename: String?) -> PhotoAsset {
        PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: localIdentifier,
                capturedAt: Date(timeIntervalSince1970: 1_000),
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 4_032,
                pixelHeight: 3_024,
                coordinate: nil,
                originalFilename: filename
            )
        )
    }
}
