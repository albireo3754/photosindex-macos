import XCTest
@testable import PhotosIndexCore

final class EvidencePageTests: XCTestCase {
    func testPagesOrderedAssetsWithoutSkippingCoverage() throws {
        let assetIDs = (0..<26).map { "ast_\($0)" }

        let first = try EvidencePage.make(
            groupAssetIDs: assetIDs,
            pageNumber: 1,
            pageSize: 12
        )
        let second = try EvidencePage.make(
            groupAssetIDs: assetIDs,
            pageNumber: 2,
            pageSize: 12
        )
        let last = try EvidencePage.make(
            groupAssetIDs: assetIDs,
            pageNumber: 3,
            pageSize: 12
        )

        XCTAssertEqual(first.assetIDs, Array(assetIDs[0..<12]))
        XCTAssertEqual(first.remainingAssetIDs, Array(assetIDs[12..<26]))
        XCTAssertEqual(second.assetIDs, Array(assetIDs[12..<24]))
        XCTAssertEqual(last.assetIDs, Array(assetIDs[24..<26]))
        XCTAssertEqual(last.remainingAssetIDs, [])
        XCTAssertEqual(first.totalPages, 3)
        XCTAssertEqual(last.totalPages, 3)
    }

    func testRejectsInvalidPageAndPageSize() {
        XCTAssertThrowsError(
            try EvidencePage.make(groupAssetIDs: ["ast_1"], pageNumber: 0, pageSize: 12)
        ) { error in
            XCTAssertEqual(error as? EvidencePageError, .invalidPageNumber)
        }
        XCTAssertThrowsError(
            try EvidencePage.make(groupAssetIDs: ["ast_1"], pageNumber: 1, pageSize: 13)
        ) { error in
            XCTAssertEqual(error as? EvidencePageError, .invalidPageSize)
        }
        XCTAssertThrowsError(
            try EvidencePage.make(groupAssetIDs: ["ast_1"], pageNumber: 2, pageSize: 1)
        ) { error in
            XCTAssertEqual(error as? EvidencePageError, .pageOutOfRange)
        }
    }
}
