import Darwin
import Foundation
import Photos
import PhotosIndexCommand
import PhotosIndexExport
import PhotosIndexPhotos

@MainActor
final class AppContainer: ObservableObject {
    let viewModel: AppViewModel
    private let host: UnixCommandHost
    private let runtime: IndexRuntime
    private let router: AppCommandRouter

    init() {
        let socketPath = "/tmp/photosindex-\(getuid()).sock"
        let authorizationStatus: @Sendable () -> String = {
            Self.permissionName(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
        let permission = authorizationStatus()
        let requestAuthorization: @Sendable () -> String = {
            Self.requestPhotosAuthorizationSynchronously()
        }
        let runtime = IndexRuntime(
            library: PhotoKitLibrary(),
            timezone: TimeZone(identifier: "Asia/Seoul")!
        )
        let service = HumanWorkflowService(
            runtime: runtime,
            authorizationStatus: authorizationStatus,
            requestAuthorization: requestAuthorization
        )
        let viewModel = AppViewModel(
            permissionStatus: permission,
            socketPath: socketPath,
            selectedDate: Date(),
            service: service
        )
        self.viewModel = viewModel
        host = UnixCommandHost(path: socketPath)
        self.runtime = runtime
        let evidenceInspectionService = EvidenceInspectionService()
        let exportRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Naver Clip", isDirectory: true)
        let pendingMoveRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("PhotosIndex", isDirectory: true)
            .appendingPathComponent("pending-moves", isDirectory: true)
        let exportService = ExportCommandService(
            allowedRoot: exportRoot,
            pendingMoveStore: FilePendingMoveStore(root: pendingMoveRoot)
        )
        router = AppCommandRouter(
            runtime: runtime,
            permission: authorizationStatus,
            requestAuthorization: requestAuthorization,
            externalSyncDidComplete: { [weak viewModel] commit in
                Task { @MainActor [weak viewModel] in
                    viewModel?.externalSyncDidComplete(commit)
                }
            },
            inspectEvidence: { runID, group, assets, output, samples, page in
                try evidenceInspectionService.inspect(
                    indexRunID: runID,
                    group: group,
                    assets: assets,
                    outputDirectory: output,
                    maxSamples: samples,
                    page: page
                )
            },
            exportService: exportService
        )
        do {
            let commandRouter = router
            try host.start { request in
                commandRouter.handle(request)
            }
        } catch {
            viewModel.lastError = "Command socket failed: \(error)"
        }
    }

    deinit {
        host.stop()
    }

    nonisolated private static func permissionName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }

    nonisolated private static func requestPhotosAuthorizationSynchronously() -> String {
        let result = AuthorizationResult()
        let semaphore = DispatchSemaphore(value: 0)
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            result.set(Self.permissionName(status))
            semaphore.signal()
        }
        semaphore.wait()
        return result.get()
    }
}

private final class AuthorizationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "unknown"

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
