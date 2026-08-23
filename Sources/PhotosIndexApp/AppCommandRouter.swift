import Foundation
import PhotosIndexCommand
import PhotosIndexCore
import PhotosIndexExport
import PhotosIndexPhotos

private enum AppCommandRouterError: Error {
    case evidenceInspectorUnavailable
    case invalidJSONInputFile
}

final class AppCommandRouter: @unchecked Sendable {
    private let runtime: IndexRuntime
    private let permission: @Sendable () -> String
    private let requestAuthorization: @Sendable () -> String
    private let inspectEvidence: @Sendable (
        String,
        CaptureGroup,
        [PhotoAsset],
        URL,
        Int,
        EvidencePage
    ) throws -> EvidenceInspectionPayload
    private let exportService: ExportCommandService

    init(
        runtime: IndexRuntime,
        permission: @escaping @Sendable () -> String,
        requestAuthorization: @escaping @Sendable () -> String,
        inspectEvidence: @escaping @Sendable (
            String,
            CaptureGroup,
            [PhotoAsset],
            URL,
            Int,
            EvidencePage
        ) throws -> EvidenceInspectionPayload = { _, _, _, _, _, _ in
            throw AppCommandRouterError.evidenceInspectorUnavailable
        },
        exportService: ExportCommandService? = nil
    ) {
        self.runtime = runtime
        self.permission = permission
        self.requestAuthorization = requestAuthorization
        self.inspectEvidence = inspectEvidence
        self.exportService = exportService ?? ExportCommandService(
            allowedRoot: Self.defaultExportRoot()
        )
    }

    func handle(_ request: CommandRequest) -> CommandResponse {
        do {
            switch request.method {
            case "status":
                return try .success(
                    id: request.id,
                    payload: StatusPayload(
                        appVersion: "0.1.0",
                        protocolVersion: CommandProtocol.currentVersion,
                        permission: permission()
                    )
                )
            case "authorize":
                return try .success(
                    id: request.id,
                    payload: AuthorizationPayload(permission: requestAuthorization())
                )
            case "sync":
                guard ["authorized", "limited"].contains(permission()) else {
                    return .failure(
                        id: request.id,
                        error: CommandFailure(
                            code: "photos-permission-required",
                            message: "Photos access is required before indexing.",
                            recovery: "Run photosindex authorize and approve the macOS prompt."
                        )
                    )
                }
                guard let date = request.arguments["date"] else {
                    return invalidArguments(request.id, "sync requires a date")
                }
                return try .success(id: request.id, payload: runtime.sync(localDate: date))
            case "groups.list":
                if let requestedDate = request.arguments["date"],
                   !runtime.isIndexed(localDate: requestedDate)
                {
                    return .failure(
                        id: request.id,
                        error: CommandFailure(
                            code: "index-date-mismatch",
                            message: "The current in-memory index is for a different date.",
                            recovery: "Run photosindex sync --date \(requestedDate) --wait."
                        )
                    )
                }
                let level = GroupLevel(rawValue: request.arguments["level"] ?? "fine") ?? .fine
                return try .success(id: request.id, payload: runtime.groups(level: level))
            case "groups.show":
                guard let id = request.arguments["id"] else {
                    return invalidArguments(request.id, "groups.show requires an id")
                }
                let detail = try runtime.group(id: id)
                if let expectedRunID = request.arguments["index-run"],
                   expectedRunID != detail.runID
                {
                    return .failure(
                        id: request.id,
                        error: CommandFailure(
                            code: "stale-index-run",
                            message: "The group belongs to a different index run.",
                            recovery: "Run photosindex groups list again and use its indexRunID."
                        )
                    )
                }
                return try .success(
                    id: request.id,
                    payload: GroupDetailPayload(
                        indexRunID: detail.runID,
                        group: detail.group,
                        assets: detail.assets.map(\.evidenceAsset)
                    )
                )
            case "groups.inspect":
                guard let id = request.arguments["id"],
                      let expectedRunID = request.arguments["index-run"],
                      let output = request.arguments["output"],
                      output.hasPrefix("/"),
                      let sampleText = request.arguments["samples"],
                      let samples = Int(sampleText),
                      (1...12).contains(samples),
                      let pageNumber = Int(request.arguments["page"] ?? "1"),
                      let pageSize = Int(request.arguments["page-size"] ?? "12")
                else {
                    return invalidArguments(
                        request.id,
                        "groups.inspect requires id, index-run, absolute output, and 1...12 samples"
                    )
                }
                let detail = try runtime.group(id: id)
                guard expectedRunID == detail.runID else {
                    return staleIndexRun(request.id)
                }
                let page = try EvidencePage.make(
                    groupAssetIDs: detail.group.assetIDs,
                    pageNumber: pageNumber,
                    pageSize: pageSize
                )
                guard samples >= page.assetIDs.count else {
                    return invalidArguments(
                        request.id,
                        "groups.inspect samples must cover every asset in the requested page"
                    )
                }
                let assetLookup = Dictionary(uniqueKeysWithValues: detail.assets.map { ($0.id, $0) })
                let pageAssets = page.assetIDs.compactMap { assetLookup[$0] }
                guard pageAssets.count == page.assetIDs.count else {
                    return invalidArguments(request.id, "groups.inspect page contains missing assets")
                }
                let outputURL = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
                let payload = try inspectEvidence(
                    detail.runID,
                    detail.group,
                    pageAssets,
                    outputURL,
                    samples,
                    page
                )
                return try .success(id: request.id, payload: payload)
            case "decisions.validate":
                guard let file = request.arguments["file"] else {
                    return invalidArguments(request.id, "decisions.validate requires file")
                }
                let decision: ModelDecision = try readCanonicalJSON(from: file)
                let detail = try runtime.group(id: decision.groupID)
                let payload = try exportService.validate(
                    currentIndexRunID: detail.runID,
                    decision: decision,
                    group: detail.group,
                    assets: detail.assets
                )
                return try .success(id: request.id, payload: payload)
            case "export.plan":
                guard let decisionFile = request.arguments["decision"],
                      let destinationRoot = request.arguments["to"]
                else {
                    return invalidArguments(
                        request.id,
                        "export.plan requires decision and to"
                    )
                }
                guard request.arguments["layout"] == nil || request.arguments["layout"] == "dated-group" else {
                    return invalidArguments(request.id, "export.plan supports dated-group layout only")
                }
                let decision: ModelDecision = try readCanonicalJSON(from: decisionFile)
                let detail = try runtime.group(id: decision.groupID)
                let envelope = try exportService.makePlan(
                    currentIndexRunID: detail.runID,
                    decision: decision,
                    group: detail.group,
                    assets: detail.assets,
                    requestedRoot: URL(fileURLWithPath: destinationRoot, isDirectory: true).standardizedFileURL
                )
                return try .success(id: request.id, payload: envelope)
            case "export.apply":
                guard let planFile = request.arguments["plan"],
                      let digest = request.arguments["digest"]
                else {
                    return invalidArguments(request.id, "export.apply requires plan and digest")
                }
                let plan: ExportPlan = try readCanonicalJSON(from: planFile)
                let detail = try runtime.group(id: plan.groupID)
                let receipt = try exportService.apply(
                    plan,
                    digest: digest,
                    currentIndexRunID: detail.runID,
                    group: detail.group,
                    assets: detail.assets
                )
                return try .success(id: request.id, payload: receipt)
            case "move.plan":
                guard let decisionFile = request.arguments["decision"],
                      let destinationRoot = request.arguments["to"]
                else {
                    return invalidArguments(
                        request.id,
                        "move.plan requires decision and to"
                    )
                }
                guard request.arguments["layout"] == nil || request.arguments["layout"] == "dated-group" else {
                    return invalidArguments(request.id, "move.plan supports dated-group layout only")
                }
                let decision: ModelDecision = try readCanonicalJSON(from: decisionFile)
                let detail = try runtime.group(id: decision.groupID)
                let envelope = try exportService.makeMovePlan(
                    currentIndexRunID: detail.runID,
                    decision: decision,
                    group: detail.group,
                    assets: detail.assets,
                    requestedRoot: URL(
                        fileURLWithPath: destinationRoot,
                        isDirectory: true
                    ).standardizedFileURL
                )
                return try .success(id: request.id, payload: envelope)
            case "move.apply":
                guard let planFile = request.arguments["plan"],
                      let digest = request.arguments["digest"]
                else {
                    return invalidArguments(request.id, "move.apply requires plan and digest")
                }
                let plan: MovePlan = try readCanonicalJSON(from: planFile)
                if let recovered = try exportService.resumeMoveIfNeeded(
                    plan,
                    digest: digest
                ) {
                    return try .success(id: request.id, payload: recovered)
                }
                let detail = try runtime.group(id: plan.exportPlan.groupID)
                let receipt = try exportService.applyMove(
                    plan,
                    digest: digest,
                    currentIndexRunID: detail.runID,
                    group: detail.group,
                    assets: detail.assets
                )
                return try .success(id: request.id, payload: receipt)
            default:
                return .failure(
                    id: request.id,
                    error: CommandFailure(
                        code: "unknown-command",
                        message: "Unsupported command: \(request.method)"
                    )
                )
            }
        } catch EvidenceInspectionServiceError.timedOut {
            return .failure(
                id: request.id,
                error: CommandFailure(
                    code: "evidence-timeout",
                    message: "Evidence generation exceeded its deadline.",
                    recovery: "Retry the group inspection after confirming iCloud originals are available."
                )
            )
        } catch ICloudUploadVerificationError.timedOut {
            return .failure(
                id: request.id,
                error: CommandFailure(
                    code: "icloud-upload-timeout",
                    message: "The verified files did not finish uploading before the move deadline.",
                    recovery: "Keep PhotosIndex running and retry move apply after iCloud finishes uploading."
                )
            )
        } catch let error as ICloudUploadVerificationError {
            return .failure(
                id: request.id,
                error: CommandFailure(
                    code: "icloud-upload-verification-failed",
                    message: String(describing: error)
                )
            )
        } catch let error as PhotoKitAssetDeletionError {
            return .failure(
                id: request.id,
                error: CommandFailure(
                    code: "source-delete-failed",
                    message: String(describing: error),
                    recovery: "The iCloud copy remains intact; retry the same move apply so PhotosIndex can resume its private pending journal."
                )
            )
        } catch {
            return .failure(
                id: request.id,
                error: CommandFailure(
                    code: "command-failed",
                    message: String(describing: error)
                )
            )
        }
    }

    private func invalidArguments(_ id: String, _ message: String) -> CommandResponse {
        .failure(id: id, error: CommandFailure(code: "invalid-arguments", message: message))
    }

    private func staleIndexRun(_ id: String) -> CommandResponse {
        .failure(
            id: id,
            error: CommandFailure(
                code: "stale-index-run",
                message: "The group belongs to a different index run.",
                recovery: "Run photosindex groups list again and use its indexRunID."
            )
        )
    }

    private func readCanonicalJSON<Value: Decodable>(from path: String) throws -> Value {
        guard path.hasPrefix("/") else {
            throw AppCommandRouterError.invalidJSONInputFile
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 1_048_576
        else {
            throw AppCommandRouterError.invalidJSONInputFile
        }
        return try CanonicalJSON.decode(Value.self, from: Data(contentsOf: url))
    }

    private static func defaultExportRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Naver Clip", isDirectory: true)
    }
}
