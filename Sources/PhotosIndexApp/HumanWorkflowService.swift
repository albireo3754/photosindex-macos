import Foundation
import PhotosIndexCore
import PhotosIndexPhotos

protocol HumanWorkflowServing: Sendable {
    func authorizationStatus() async -> String
    func requestAuthorization() async -> String
    func sync(localDate: String) async throws -> IndexSyncCommit
    func groups(level: GroupLevel, expectedRunID: String) async throws -> GroupsPayload
    func groupDetail(id: String, expectedRunID: String) async throws -> GroupDetailPayload
}

final class HumanWorkflowService: HumanWorkflowServing {
    private let runtime: IndexRuntime
    private let authorizationStatusReader: @Sendable () -> String
    private let authorizationRequest: @Sendable () -> String

    init(
        runtime: IndexRuntime,
        authorizationStatus: @escaping @Sendable () -> String,
        requestAuthorization: @escaping @Sendable () -> String
    ) {
        self.runtime = runtime
        authorizationStatusReader = authorizationStatus
        authorizationRequest = requestAuthorization
    }

    func authorizationStatus() async -> String {
        authorizationStatusReader()
    }

    func requestAuthorization() async -> String {
        await Task.detached(priority: .userInitiated) { [authorizationRequest] in
            authorizationRequest()
        }.value
    }

    func sync(localDate: String) async throws -> IndexSyncCommit {
        try await Task.detached(priority: .userInitiated) { [runtime] in
            try runtime.syncWithCommit(localDate: localDate)
        }.value
    }

    func groups(level: GroupLevel, expectedRunID: String) async throws -> GroupsPayload {
        try runtime.groups(level: level, expectedRunID: expectedRunID)
    }

    func groupDetail(id: String, expectedRunID: String) async throws -> GroupDetailPayload {
        let detail = try runtime.group(id: id, expectedRunID: expectedRunID)
        return GroupDetailPayload(
            indexRunID: detail.runID,
            group: detail.group,
            assets: detail.assets.map(\.evidenceAsset)
        )
    }
}
