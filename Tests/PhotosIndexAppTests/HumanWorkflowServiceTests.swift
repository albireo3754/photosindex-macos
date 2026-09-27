import Foundation
import PhotosIndexCore
import PhotosIndexPhotos
import XCTest
@testable import PhotosIndexApp

final class HumanWorkflowServiceTests: XCTestCase {
    func testSyncListAndDetailReturnPublicCorePayloads() async throws {
        let capturedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")
        )
        let photoAsset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "synthetic-local-asset-001",
                capturedAt: capturedAt,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 1_200,
                pixelHeight: 800,
                coordinate: GeoPoint(latitude: 10, longitude: 20),
                originalFilename: "IMG_SYNTHETIC_001.HEIC"
            )
        )
        let runtime = IndexRuntime(
            library: HumanWorkflowPhotoLibrary(assets: [photoAsset]),
            timezone: try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        )
        let service = HumanWorkflowService(
            runtime: runtime,
            authorizationStatus: { "authorized" },
            requestAuthorization: { "authorized" }
        )

        let commit = try await service.sync(localDate: "2026-01-15")
        let sync = commit.payload
        let groups = try await service.groups(
            level: .fine,
            expectedRunID: sync.indexRunID
        )
        let group = try XCTUnwrap(groups.groups.first)
        let detail = try await service.groupDetail(
            id: group.id,
            expectedRunID: sync.indexRunID
        )
        let publicAssets: [EvidenceAsset] = detail.assets

        XCTAssertEqual(sync.localDate, "2026-01-15")
        XCTAssertEqual(commit.generation, 1)
        XCTAssertEqual(sync.assetCount, 1)
        XCTAssertEqual(groups.indexRunID, sync.indexRunID)
        XCTAssertEqual(groups.level, .fine)
        XCTAssertEqual(groups.groups.count, 1)
        XCTAssertEqual(detail.indexRunID, sync.indexRunID)
        XCTAssertEqual(detail.group, group)
        XCTAssertEqual(publicAssets, [photoAsset.evidenceAsset])
        XCTAssertTrue(try encodedAssetKeys(publicAssets[0]).isDisjoint(with: [
            "localIdentifier",
            "coordinate",
            "exactBytes",
        ]))
    }

    func testGroupsAndDetailRejectAStaleExpectedRun() async throws {
        let capturedAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-15T03:00:00Z")
        )
        let photoAsset = PhotoAssetMapper.map(
            PhotoMetadataInput(
                localIdentifier: "synthetic-local-asset-stale",
                capturedAt: capturedAt,
                mediaKind: .photo,
                durationSeconds: 0,
                pixelWidth: 1_200,
                pixelHeight: 800,
                coordinate: nil,
                originalFilename: "IMG_SYNTHETIC_STALE.HEIC"
            )
        )
        let runtime = IndexRuntime(
            library: HumanWorkflowPhotoLibrary(assets: [photoAsset]),
            timezone: try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        )
        let service = HumanWorkflowService(
            runtime: runtime,
            authorizationStatus: { "authorized" },
            requestAuthorization: { "authorized" }
        )
        let first = try await service.sync(localDate: "2026-01-15")
        let groups = try await service.groups(
            level: .fine,
            expectedRunID: first.payload.indexRunID
        )
        let groupID = try XCTUnwrap(groups.groups.first?.id)

        _ = try runtime.sync(localDate: "2026-01-15")

        do {
            _ = try await service.groups(
                level: .fine,
                expectedRunID: first.payload.indexRunID
            )
            XCTFail("Expected stale groups to be rejected")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
        do {
            _ = try await service.groupDetail(
                id: groupID,
                expectedRunID: first.payload.indexRunID
            )
            XCTFail("Expected stale group detail to be rejected")
        } catch {
            XCTAssertEqual(error as? IndexRuntimeError, .staleIndexRun)
        }
    }

    func testRequestAuthorizationUsesInjectedClosure() async {
        let runtime = IndexRuntime(
            library: HumanWorkflowPhotoLibrary(assets: []),
            timezone: TimeZone(secondsFromGMT: 0)!
        )
        let service = HumanWorkflowService(
            runtime: runtime,
            authorizationStatus: { "denied" },
            requestAuthorization: { "limited" }
        )

        let initialPermission = await service.authorizationStatus()
        let permission = await service.requestAuthorization()

        XCTAssertEqual(initialPermission, "denied")
        XCTAssertEqual(permission, "limited")
    }

    private func encodedAssetKeys(_ asset: EvidenceAsset) throws -> Set<String> {
        let data = try JSONEncoder().encode(asset)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return Set(object.keys)
    }
}

private struct HumanWorkflowPhotoLibrary: PhotoLibraryReading {
    let assets: [PhotoAsset]

    func authorizationStatus() -> PhotoAuthorizationStatus { .authorized }

    func requestAuthorization() async -> PhotoAuthorizationStatus { .authorized }

    func assets(from start: Date, to end: Date) throws -> [PhotoAsset] {
        assets.filter { asset in
            guard let capturedAt = asset.capturedAt else { return false }
            return capturedAt >= start && capturedAt < end
        }
    }
}
