import Foundation
import PhotosIndexCore

@MainActor
final class AppViewModel: ObservableObject {
    let title = "PhotosIndex"

    @Published var permissionStatus: String
    @Published var socketPath: String
    @Published var lastError: String?
    @Published private(set) var selectedDate: Date
    @Published private(set) var selectedLevel: GroupLevel = .fine
    @Published private(set) var syncResult: IndexSyncPayload?
    @Published private(set) var groups: [CaptureGroup] = []
    @Published private(set) var selectedGroupID: String?
    @Published private(set) var selectedGroupDetail: GroupDetailPayload?
    @Published private(set) var isRequestingPhotosAccess = false
    @Published private(set) var isIndexing = false
    @Published private(set) var isLoadingGroups = false
    @Published private(set) var isLoadingGroupDetail = false

    private let service: any HumanWorkflowServing
    private let seoulTimeZone = TimeZone(identifier: "Asia/Seoul")!
    private var stateRevision = 0
    private var displayedSyncGeneration: UInt64?
    private var latestExternalSyncGeneration: UInt64 = 0

    init(
        permissionStatus: String,
        socketPath: String,
        selectedDate: Date,
        service: any HumanWorkflowServing
    ) {
        self.permissionStatus = permissionStatus
        self.socketPath = socketPath
        self.selectedDate = selectedDate
        self.service = service
    }

    var isBusy: Bool {
        isRequestingPhotosAccess || isIndexing || isLoadingGroups || isLoadingGroupDetail
    }

    var manualQAState: ManualQAState {
        ManualQAState(
            permissionStatus: permissionStatus,
            busyPhase: manualQABusyPhase,
            hasIndex: syncResult != nil,
            groupCount: groups.count
        )
    }

    func refreshPhotosAccess() async {
        invalidateIndexedState()
        lastError = nil
        let status = await service.authorizationStatus()
        permissionStatus = status
    }

    func externalSyncDidComplete(_ commit: IndexSyncCommit) {
        guard commit.generation > latestExternalSyncGeneration else { return }
        latestExternalSyncGeneration = commit.generation
        guard let displayedSyncGeneration,
              displayedSyncGeneration < commit.generation
        else { return }

        invalidateIndexedState()
        lastError = nil
    }

    private var manualQABusyPhase: ManualQABusyPhase? {
        if isRequestingPhotosAccess { return .requestingPhotosAccess }
        if isIndexing { return .indexing }
        if isLoadingGroups { return .loadingGroups }
        if isLoadingGroupDetail { return .loadingGroupDetail }
        return nil
    }

    func requestPhotosAccess() async {
        guard !isBusy else { return }

        lastError = nil
        isRequestingPhotosAccess = true
        let status = await service.requestAuthorization()
        isRequestingPhotosAccess = false
        permissionStatus = status

        if !canIndex {
            invalidateIndexedState()
        }
    }

    func selectDate(_ date: Date) {
        let previousLocalDate = localDate(for: selectedDate)
        selectedDate = date
        guard localDate(for: date) != previousLocalDate else { return }

        invalidateIndexedState()
        lastError = nil
    }

    func indexSelectedDate() async {
        guard canIndex else {
            invalidateIndexedState()
            lastError = "Photos access is required before indexing."
            return
        }
        guard !isBusy else { return }

        invalidateIndexedState()
        lastError = nil
        isIndexing = true
        defer {
            isIndexing = false
            isLoadingGroups = false
        }
        let revision = stateRevision
        let requestedDate = localDate(for: selectedDate)

        do {
            let commit = try await service.sync(localDate: requestedDate)
            let result = commit.payload
            guard revision == stateRevision else { return }
            guard commit.generation > latestExternalSyncGeneration else {
                invalidateForStaleRun()
                return
            }
            guard result.localDate == requestedDate else {
                invalidateIndexedState()
                lastError = "PhotosIndex couldn’t index that date. Please try again."
                return
            }

            isLoadingGroups = true
            let payload = try await service.groups(
                level: selectedLevel,
                expectedRunID: result.indexRunID
            )
            isLoadingGroups = false
            guard revision == stateRevision else { return }
            guard commit.generation > latestExternalSyncGeneration else {
                invalidateForStaleRun()
                return
            }
            guard groupsPayload(payload, matches: result, level: selectedLevel) else {
                invalidateForStaleRun()
                return
            }

            syncResult = result
            displayedSyncGeneration = commit.generation
            groups = payload.groups
        } catch {
            guard revision == stateRevision else { return }
            if isStaleIndexError(error) {
                invalidateForStaleRun()
            } else {
                invalidateIndexedState()
                lastError = "PhotosIndex couldn’t index that date. Please try again."
            }
        }
    }

    func selectLevel(_ level: GroupLevel) async {
        guard !isBusy else { return }
        guard level != selectedLevel || (syncResult != nil && groups.isEmpty) else { return }

        selectedLevel = level
        stateRevision &+= 1
        clearGroupState()
        lastError = nil
        guard let syncResult else { return }

        let revision = stateRevision
        isLoadingGroups = true
        defer { isLoadingGroups = false }

        do {
            let payload = try await service.groups(
                level: level,
                expectedRunID: syncResult.indexRunID
            )
            guard revision == stateRevision else { return }
            guard groupsPayload(payload, matches: syncResult, level: level) else {
                invalidateForStaleRun()
                return
            }

            groups = payload.groups
        } catch {
            guard revision == stateRevision else { return }
            if isStaleIndexError(error) {
                invalidateForStaleRun()
            } else {
                lastError = "PhotosIndex couldn’t load groups. Please try again."
            }
        }
    }

    func selectGroup(_ id: String) async {
        guard !isBusy else { return }
        guard let syncResult,
              let expectedGroup = groups.first(where: { $0.id == id })
        else {
            clearSelectedGroup()
            lastError = "Select an indexed group before opening details."
            return
        }

        stateRevision &+= 1
        let revision = stateRevision
        selectedGroupID = id
        selectedGroupDetail = nil
        lastError = nil
        isLoadingGroupDetail = true
        defer { isLoadingGroupDetail = false }

        do {
            let detail = try await service.groupDetail(
                id: id,
                expectedRunID: syncResult.indexRunID
            )
            guard revision == stateRevision else { return }
            guard detail.indexRunID == syncResult.indexRunID,
                  detail.group == expectedGroup
            else {
                invalidateForStaleRun()
                return
            }
            selectedGroupDetail = detail
        } catch {
            guard revision == stateRevision else { return }
            if isStaleIndexError(error) {
                invalidateForStaleRun()
            } else {
                selectedGroupDetail = nil
                lastError = "PhotosIndex couldn’t load that group. Please try again."
            }
        }
    }

    private var canIndex: Bool {
        permissionStatus == "authorized" || permissionStatus == "limited"
    }

    private func localDate(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoulTimeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!
        )
    }

    private func groupsPayload(
        _ payload: GroupsPayload,
        matches syncResult: IndexSyncPayload,
        level: GroupLevel
    ) -> Bool {
        payload.indexRunID == syncResult.indexRunID
            && payload.level == level
            && payload.groups.allSatisfy {
                $0.level == level && $0.localDate == syncResult.localDate
            }
    }

    private func invalidateIndexedState() {
        stateRevision &+= 1
        clearIndexedState()
    }

    private func invalidateForStaleRun() {
        invalidateIndexedState()
        lastError = "The index changed. Index the date again."
    }

    private func isStaleIndexError(_ error: Error) -> Bool {
        guard let runtimeError = error as? IndexRuntimeError else { return false }
        return runtimeError == .staleIndexRun || runtimeError == .notIndexed
    }

    private func clearIndexedState() {
        syncResult = nil
        displayedSyncGeneration = nil
        clearGroupState()
    }

    private func clearGroupState() {
        groups = []
        clearSelectedGroup()
    }

    private func clearSelectedGroup() {
        selectedGroupID = nil
        selectedGroupDetail = nil
    }
}
