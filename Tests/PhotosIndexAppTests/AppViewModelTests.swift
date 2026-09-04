import Foundation
import PhotosIndexCore
import XCTest
@testable import PhotosIndexApp

@MainActor
final class AppViewModelTests: XCTestCase {
    func testDisplaysInitialWorkflowState() {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)

        XCTAssertEqual(model.permissionStatus, "authorized")
        XCTAssertEqual(model.socketPath, "/tmp/photosindex-synthetic.sock")
        XCTAssertEqual(model.title, "PhotosIndex")
        XCTAssertEqual(model.selectedLevel, .fine)
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertFalse(model.isBusy)
    }

    func testAuthorizationGatesIndexingAndLimitedAccessMayIndex() async {
        let blockedFixture = makeFixture()
        let blockedModel = makeViewModel(
            permissionStatus: "denied",
            service: blockedFixture.service
        )

        await blockedModel.indexSelectedDate()

        let blockedSyncDates = await blockedFixture.service.recordedSyncDates()
        let blockedLevels = await blockedFixture.service.recordedLevels()
        XCTAssertEqual(blockedSyncDates, [])
        XCTAssertEqual(blockedLevels, [])
        XCTAssertEqual(
            blockedModel.lastError,
            "Photos access is required before indexing."
        )

        let limitedFixture = makeFixture(authorizationResult: "limited")
        let limitedModel = makeViewModel(
            permissionStatus: "not-determined",
            service: limitedFixture.service
        )

        await limitedModel.requestPhotosAccess()
        await limitedModel.indexSelectedDate()

        let authorizationCalls = await limitedFixture.service.authorizationCallCount()
        let limitedSyncDates = await limitedFixture.service.recordedSyncDates()
        XCTAssertEqual(limitedModel.permissionStatus, "limited")
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(limitedSyncDates, ["2030-01-02"])
    }

    func testRefreshPhotosAccessRecoversAfterSystemSettingsChange() async {
        let fixture = makeFixture(authorizationResult: "denied")
        let model = makeViewModel(
            permissionStatus: "denied",
            service: fixture.service
        )
        await model.indexSelectedDate()
        await fixture.service.setAuthorizationStatus("authorized")

        await model.refreshPhotosAccess()

        XCTAssertEqual(model.permissionStatus, "authorized")
        XCTAssertNil(model.lastError)
        XCTAssertEqual(
            model.manualQAState.availableActions,
            [.selectDate, .indexDate]
        )

        await model.indexSelectedDate()
        XCTAssertEqual(model.syncResult, fixture.syncResult)
    }

    func testRefreshPhotosAccessClearsAuthorizedIndexAfterChangingToLimited() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)
        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertEqual(model.selectedGroupID, fixture.fineGroup.id)
        XCTAssertEqual(model.selectedGroupDetail, fixture.fineDetail)
        await fixture.service.setAuthorizationStatus("limited")

        await model.refreshPhotosAccess()

        XCTAssertEqual(model.permissionStatus, "limited")
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.manualQAState.hasIndex)
        XCTAssertEqual(model.manualQAState.groupCount, 0)
    }

    func testRefreshPhotosAccessClearsLimitedIndexWhenStatusRemainsLimited() async {
        let fixture = makeFixture(authorizationResult: "limited")
        let model = makeViewModel(
            permissionStatus: "limited",
            service: fixture.service
        )
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)
        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertEqual(model.selectedGroupID, fixture.fineGroup.id)
        XCTAssertEqual(model.selectedGroupDetail, fixture.fineDetail)

        await model.refreshPhotosAccess()

        XCTAssertEqual(model.permissionStatus, "limited")
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.manualQAState.hasIndex)
        XCTAssertEqual(model.manualQAState.groupCount, 0)
    }

    func testRefreshPhotosAccessClearsLimitedStateWhileGroupDetailIsBlocked() async {
        let fixture = makeFixture(
            authorizationResult: "limited",
            blockGroupDetail: true
        )
        let model = makeViewModel(
            permissionStatus: "limited",
            service: fixture.service
        )
        await model.indexSelectedDate()
        let loadingDetail = Task { await model.selectGroup(fixture.fineGroup.id) }
        await fixture.service.waitForGroupDetailStart()

        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertEqual(model.selectedGroupID, fixture.fineGroup.id)
        XCTAssertTrue(model.isLoadingGroupDetail)

        await model.refreshPhotosAccess()

        XCTAssertEqual(model.permissionStatus, "limited")
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.isLoadingGroupDetail)
        XCTAssertTrue(model.isBusy)

        await fixture.service.releaseGroupDetail()
        await loadingDetail.value

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertFalse(model.isLoadingGroupDetail)
        XCTAssertFalse(model.isBusy)
    }

    func testRefreshPhotosAccessWhileLimitedSyncIsBlockedDiscardsTheOldResult() async {
        let fixture = makeFixture(
            authorizationResult: "limited",
            blockSync: true
        )
        let model = makeViewModel(
            permissionStatus: "limited",
            service: fixture.service
        )
        let indexing = Task { await model.indexSelectedDate() }
        await fixture.service.waitForSyncStart()

        XCTAssertTrue(model.isIndexing)
        XCTAssertTrue(model.isBusy)

        await model.refreshPhotosAccess()

        XCTAssertEqual(model.permissionStatus, "limited")
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.isIndexing)
        XCTAssertTrue(model.isBusy)

        await fixture.service.releaseSync()
        await indexing.value

        let levels = await fixture.service.recordedLevels()
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertEqual(levels, [])
        XCTAssertFalse(model.isIndexing)
        XCTAssertFalse(model.isBusy)
    }

    func testIndexUsesAsiaSeoulCalendarDateAndLoadsFineGroups() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)

        await model.indexSelectedDate()

        let syncDates = await fixture.service.recordedSyncDates()
        let levels = await fixture.service.recordedLevels()
        XCTAssertEqual(syncDates, ["2030-01-02"])
        XCTAssertEqual(levels, [.fine])
        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.manualQAState.hasIndex)
        XCTAssertEqual(model.manualQAState.groupCount, 1)
    }

    func testIndexPublishesBusyStateUntilServiceCompletes() async {
        let fixture = makeFixture(blockSync: true)
        let model = makeViewModel(service: fixture.service)
        let indexing = Task { await model.indexSelectedDate() }

        await fixture.service.waitForSyncStart()

        XCTAssertTrue(model.isIndexing)
        XCTAssertTrue(model.isBusy)
        XCTAssertEqual(model.manualQAState.busyPhase, .indexing)

        await fixture.service.releaseSync()
        await indexing.value

        XCTAssertFalse(model.isIndexing)
        XCTAssertFalse(model.isBusy)
    }

    func testLevelSwitchesReloadGroupsWithoutReindexing() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)

        await model.selectLevel(.coarse)
        XCTAssertEqual(model.selectedLevel, .coarse)
        XCTAssertEqual(model.groups, [fixture.coarseGroup])
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)

        await model.selectLevel(.mediaKind)
        XCTAssertEqual(model.groups, [fixture.mediaKindGroup])

        await model.selectLevel(.fine)
        let syncDates = await fixture.service.recordedSyncDates()
        let levels = await fixture.service.recordedLevels()
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertEqual(syncDates.count, 1)
        XCTAssertEqual(levels, [.fine, .coarse, .mediaKind, .fine])
    }

    func testSelectingGroupLoadsPublicDetail() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()

        await model.selectGroup(fixture.fineGroup.id)

        let groupIDs = await fixture.service.recordedGroupIDs()
        XCTAssertEqual(model.selectedGroupID, fixture.fineGroup.id)
        XCTAssertEqual(model.selectedGroupDetail, fixture.fineDetail)
        XCTAssertEqual(groupIDs, [fixture.fineGroup.id])
        XCTAssertNil(model.lastError)
    }

    func testChangingCalendarDateClearsIndexedAndSelectedState() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)
        let nextDate = ISO8601DateFormatter().date(from: "2030-01-02T15:30:00Z")!

        model.selectDate(nextDate)

        XCTAssertEqual(model.selectedDate, nextDate)
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertFalse(model.manualQAState.hasIndex)
        XCTAssertEqual(model.manualQAState.groupCount, 0)
    }

    func testChangingDateWhileIndexingDiscardsTheStaleResult() async {
        let fixture = makeFixture(blockSync: true)
        let model = makeViewModel(service: fixture.service)
        let indexing = Task { await model.indexSelectedDate() }
        await fixture.service.waitForSyncStart()

        model.selectDate(ISO8601DateFormatter().date(from: "2030-01-02T15:30:00Z")!)
        await fixture.service.releaseSync()
        await indexing.value

        let levels = await fixture.service.recordedLevels()
        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertEqual(levels, [])
        XCTAssertNil(model.lastError)
        XCTAssertFalse(model.isBusy)
    }

    func testStaleExpectedRunClearsTheEntireDisplayedIndex() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)
        await fixture.service.replaceCurrentRunID("run_synthetic_external")

        await model.selectLevel(.coarse)

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertFalse(model.manualQAState.hasIndex)
    }

    func testStaleExpectedRunWhileLoadingDetailClearsTheEntireDisplayedIndex() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await fixture.service.replaceCurrentRunID("run_synthetic_external")

        await model.selectGroup(fixture.fineGroup.id)

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
    }

    func testExternalSyncInvalidatesAnAlreadyDisplayedUIRun() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)

        model.externalSyncDidComplete(externalCommit(generation: 2))

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertNil(model.lastError)
    }

    func testExternalSyncAfterUICommitPreventsStalePublication() async {
        let fixture = makeFixture(blockGroups: true)
        let model = makeViewModel(service: fixture.service)
        let indexing = Task { await model.indexSelectedDate() }
        await fixture.service.waitForGroupsStart()

        model.externalSyncDidComplete(externalCommit(generation: 2))
        await fixture.service.releaseGroups()
        await indexing.value

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
    }

    func testUILaterCommitRemainsAuthoritativeAfterDelayedExternalNotification() async {
        let fixture = makeFixture(blockSync: true, syncGeneration: 2)
        let model = makeViewModel(service: fixture.service)
        let indexing = Task { await model.indexSelectedDate() }
        await fixture.service.waitForSyncStart()

        model.externalSyncDidComplete(externalCommit(generation: 1))
        await fixture.service.releaseSync()
        await indexing.value

        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])

        model.externalSyncDidComplete(externalCommit(generation: 1))

        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
    }

    func testFailuresClearStaleSuccessAndCanRecoverWithoutLeakingDetails() async {
        let fixture = makeFixture()
        let model = makeViewModel(service: fixture.service)
        await model.indexSelectedDate()
        await model.selectGroup(fixture.fineGroup.id)

        await fixture.service.failNextGroupDetail()
        await model.selectGroup(fixture.fineGroup.id)

        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertFalse(model.lastError?.contains(fixture.fineGroup.id) ?? true)
        XCTAssertFalse(model.lastError?.contains("/private/") ?? true)

        await model.selectGroup(fixture.fineGroup.id)
        XCTAssertEqual(model.selectedGroupDetail, fixture.fineDetail)
        XCTAssertNil(model.lastError)

        await fixture.service.failNextSync()
        await model.indexSelectedDate()

        XCTAssertNil(model.syncResult)
        XCTAssertTrue(model.groups.isEmpty)
        XCTAssertNil(model.selectedGroupID)
        XCTAssertNil(model.selectedGroupDetail)
        XCTAssertFalse(model.lastError?.contains("/private/") ?? true)

        await model.indexSelectedDate()
        XCTAssertEqual(model.syncResult, fixture.syncResult)
        XCTAssertEqual(model.groups, [fixture.fineGroup])
        XCTAssertNil(model.lastError)
    }

    private func externalCommit(generation: UInt64) -> IndexSyncCommit {
        IndexSyncCommit(
            payload: IndexSyncPayload(
                indexRunID: "run_synthetic_external_\(generation)",
                localDate: "2030-01-03",
                assetCount: 0,
                coarseSessionCount: 0,
                fineGroupCount: 0
            ),
            generation: generation
        )
    }

    private func makeViewModel(
        permissionStatus: String = "authorized",
        service: FakeHumanWorkflowService
    ) -> AppViewModel {
        AppViewModel(
            permissionStatus: permissionStatus,
            socketPath: "/tmp/photosindex-synthetic.sock",
            selectedDate: ISO8601DateFormatter().date(from: "2030-01-01T15:30:00Z")!,
            service: service
        )
    }

    private func makeFixture(
        authorizationResult: String = "authorized",
        blockSync: Bool = false,
        blockGroups: Bool = false,
        blockGroupDetail: Bool = false,
        syncGeneration: UInt64 = 1
    ) -> WorkflowFixture {
        let capturedAt = ISO8601DateFormatter().date(from: "2030-01-02T03:00:00Z")!
        let asset = EvidenceAsset(
            id: "asset_synthetic_001",
            capturedAt: capturedAt,
            mediaKind: .photo,
            durationSeconds: 0,
            pixelWidth: 1_200,
            pixelHeight: 800,
            hasLocation: false,
            publicFilename: "IMG_SYNTHETIC_001.HEIC"
        )
        let fineGroup = CaptureGroup(
            id: "segment_synthetic_fine",
            level: .fine,
            localDate: "2030-01-02",
            start: capturedAt,
            end: capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
        let coarseGroup = CaptureGroup(
            id: "session_synthetic_coarse",
            level: .coarse,
            localDate: "2030-01-02",
            start: capturedAt,
            end: capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
        let mediaKindGroup = CaptureGroup(
            id: "media_photo_synthetic",
            level: .mediaKind,
            mediaKind: .photo,
            localDate: "2030-01-02",
            start: capturedAt,
            end: capturedAt,
            assetIDs: [asset.id],
            warnings: []
        )
        let syncResult = IndexSyncPayload(
            indexRunID: "run_synthetic",
            localDate: "2030-01-02",
            assetCount: 1,
            coarseSessionCount: 1,
            fineGroupCount: 1
        )
        let fineDetail = GroupDetailPayload(
            indexRunID: syncResult.indexRunID,
            group: fineGroup,
            assets: [asset]
        )
        let service = FakeHumanWorkflowService(
            authorizationResult: authorizationResult,
            syncResult: syncResult,
            groupPayloads: [
                GroupsPayload(
                    indexRunID: syncResult.indexRunID,
                    level: .fine,
                    groups: [fineGroup]
                ),
                GroupsPayload(
                    indexRunID: syncResult.indexRunID,
                    level: .coarse,
                    groups: [coarseGroup]
                ),
                GroupsPayload(
                    indexRunID: syncResult.indexRunID,
                    level: .mediaKind,
                    groups: [mediaKindGroup]
                ),
            ],
            details: [
                fineDetail,
                GroupDetailPayload(
                    indexRunID: syncResult.indexRunID,
                    group: coarseGroup,
                    assets: [asset]
                ),
                GroupDetailPayload(
                    indexRunID: syncResult.indexRunID,
                    group: mediaKindGroup,
                    assets: [asset]
                ),
            ],
            blockSync: blockSync,
            blockGroups: blockGroups,
            blockGroupDetail: blockGroupDetail,
            syncGeneration: syncGeneration
        )
        return WorkflowFixture(
            service: service,
            syncResult: syncResult,
            fineGroup: fineGroup,
            coarseGroup: coarseGroup,
            mediaKindGroup: mediaKindGroup,
            fineDetail: fineDetail
        )
    }
}

private struct WorkflowFixture {
    let service: FakeHumanWorkflowService
    let syncResult: IndexSyncPayload
    let fineGroup: CaptureGroup
    let coarseGroup: CaptureGroup
    let mediaKindGroup: CaptureGroup
    let fineDetail: GroupDetailPayload
}

private enum SyntheticWorkflowError: Error {
    case expectedFailure
    case missingDetail
}

private actor FakeHumanWorkflowService: HumanWorkflowServing {
    private let authorizationResult: String
    private var currentAuthorizationStatus: String
    private let syncResult: IndexSyncPayload
    private let groupPayloads: [GroupsPayload]
    private let details: [GroupDetailPayload]
    private let blockSync: Bool
    private let blockGroups: Bool
    private let blockGroupDetail: Bool
    private var nextSyncGeneration: UInt64
    private var currentRunID: String?
    private var authorizationCalls = 0
    private var syncDates: [String] = []
    private var levels: [GroupLevel] = []
    private var groupIDs: [String] = []
    private var shouldFailNextSync = false
    private var shouldFailNextGroupDetail = false
    private var syncStarted = false
    private var syncStartContinuation: CheckedContinuation<Void, Never>?
    private var syncContinuation: CheckedContinuation<Void, Never>?
    private var groupsStarted = false
    private var groupsStartContinuation: CheckedContinuation<Void, Never>?
    private var groupsContinuation: CheckedContinuation<Void, Never>?
    private var groupDetailStarted = false
    private var groupDetailStartContinuation: CheckedContinuation<Void, Never>?
    private var groupDetailContinuation: CheckedContinuation<Void, Never>?

    init(
        authorizationResult: String,
        syncResult: IndexSyncPayload,
        groupPayloads: [GroupsPayload],
        details: [GroupDetailPayload],
        blockSync: Bool,
        blockGroups: Bool,
        blockGroupDetail: Bool,
        syncGeneration: UInt64
    ) {
        self.authorizationResult = authorizationResult
        currentAuthorizationStatus = authorizationResult
        self.syncResult = syncResult
        self.groupPayloads = groupPayloads
        self.details = details
        self.blockSync = blockSync
        self.blockGroups = blockGroups
        self.blockGroupDetail = blockGroupDetail
        nextSyncGeneration = syncGeneration
    }

    func authorizationStatus() async -> String {
        currentAuthorizationStatus
    }

    func requestAuthorization() async -> String {
        authorizationCalls += 1
        currentAuthorizationStatus = authorizationResult
        return authorizationResult
    }

    func sync(localDate: String) async throws -> IndexSyncCommit {
        syncDates.append(localDate)
        syncStarted = true
        syncStartContinuation?.resume()
        syncStartContinuation = nil
        if blockSync {
            await withCheckedContinuation { continuation in
                syncContinuation = continuation
            }
        }
        if shouldFailNextSync {
            shouldFailNextSync = false
            throw SyntheticWorkflowError.expectedFailure
        }
        let commit = IndexSyncCommit(
            payload: syncResult,
            generation: nextSyncGeneration
        )
        nextSyncGeneration &+= 1
        currentRunID = syncResult.indexRunID
        return commit
    }

    func groups(level: GroupLevel, expectedRunID: String) async throws -> GroupsPayload {
        levels.append(level)
        groupsStarted = true
        groupsStartContinuation?.resume()
        groupsStartContinuation = nil
        if blockGroups {
            await withCheckedContinuation { continuation in
                groupsContinuation = continuation
            }
        }
        guard let currentRunID else { throw IndexRuntimeError.notIndexed }
        guard expectedRunID == currentRunID else { throw IndexRuntimeError.staleIndexRun }
        guard let payload = groupPayloads.first(where: { $0.level == level }) else {
            preconditionFailure("Missing synthetic groups payload")
        }
        return payload
    }

    func groupDetail(id: String, expectedRunID: String) async throws -> GroupDetailPayload {
        groupIDs.append(id)
        groupDetailStarted = true
        groupDetailStartContinuation?.resume()
        groupDetailStartContinuation = nil
        if blockGroupDetail {
            await withCheckedContinuation { continuation in
                groupDetailContinuation = continuation
            }
        }
        if shouldFailNextGroupDetail {
            shouldFailNextGroupDetail = false
            throw SyntheticWorkflowError.expectedFailure
        }
        guard let currentRunID else { throw IndexRuntimeError.notIndexed }
        guard expectedRunID == currentRunID else { throw IndexRuntimeError.staleIndexRun }
        guard let detail = details.first(where: { $0.group.id == id }) else {
            throw SyntheticWorkflowError.missingDetail
        }
        return detail
    }

    func failNextSync() {
        shouldFailNextSync = true
    }

    func setAuthorizationStatus(_ status: String) {
        currentAuthorizationStatus = status
    }

    func failNextGroupDetail() {
        shouldFailNextGroupDetail = true
    }

    func replaceCurrentRunID(_ runID: String) {
        currentRunID = runID
    }

    func waitForSyncStart() async {
        guard !syncStarted else { return }
        await withCheckedContinuation { continuation in
            syncStartContinuation = continuation
        }
    }

    func releaseSync() {
        syncContinuation?.resume()
        syncContinuation = nil
    }

    func waitForGroupsStart() async {
        guard !groupsStarted else { return }
        await withCheckedContinuation { continuation in
            groupsStartContinuation = continuation
        }
    }

    func releaseGroups() {
        groupsContinuation?.resume()
        groupsContinuation = nil
    }

    func waitForGroupDetailStart() async {
        guard !groupDetailStarted else { return }
        await withCheckedContinuation { continuation in
            groupDetailStartContinuation = continuation
        }
    }

    func releaseGroupDetail() {
        groupDetailContinuation?.resume()
        groupDetailContinuation = nil
    }

    func authorizationCallCount() -> Int { authorizationCalls }
    func recordedSyncDates() -> [String] { syncDates }
    func recordedLevels() -> [GroupLevel] { levels }
    func recordedGroupIDs() -> [String] { groupIDs }
}
