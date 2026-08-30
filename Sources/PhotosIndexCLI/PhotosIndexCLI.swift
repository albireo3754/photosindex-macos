import ArgumentParser
import Foundation
import PhotosIndexCommand
import PhotosIndexCore

@main
struct PhotosIndexCommandLine: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "photosindex",
        abstract: "Query the local PhotosIndex app.",
        subcommands: [
            StatusCommand.self,
            AuthorizeCommand.self,
            SyncCommand.self,
            GroupsCommand.self,
            DecisionsCommand.self,
            ExportRootCommand.self,
            MoveRootCommand.self,
        ]
    )
}

struct AuthorizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authorize",
        abstract: "Request Apple Photos access through PhotosIndex.app."
    )

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        let data = try AppConnection().run(
            CommandRequest(method: "authorize"),
            as: AuthorizationPayload.self
        )
        if format == "json" {
            writeJSON(data)
            return
        }
        let payload = try CanonicalJSON.decode(AuthorizationPayload.self, from: data)
        print("photos-permission\t\(payload.permission)")
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show app, protocol, and Photos permission status."
    )

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        let data = try AppConnection().run(CommandRequest(method: "status"), as: StatusPayload.self)
        if format == "json" {
            writeJSON(data)
            return
        }
        let status = try CanonicalJSON.decode(StatusPayload.self, from: data)
        print("app\t\(status.appVersion)")
        print("protocol\t\(status.protocolVersion)")
        print("photos-permission\t\(status.permission)")
    }
}

struct SyncCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Index Photos captured on one local calendar date."
    )

    @Option(name: .long, help: "Local date in YYYY-MM-DD form.")
    var date: String

    @Flag(name: .long, help: "Wait for the app-owned index operation to finish.")
    var wait = false

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        let request = CommandRequest(method: "sync", arguments: ["date": date])
        let data = try AppConnection().run(request, as: IndexSyncPayload.self)
        if format == "json" {
            writeJSON(data)
            return
        }
        let payload = try CanonicalJSON.decode(IndexSyncPayload.self, from: data)
        print("run-id\t\(payload.indexRunID)")
        print("date\t\(payload.localDate)")
        print("assets\t\(payload.assetCount)")
        print("coarse-sessions\t\(payload.coarseSessionCount)")
        print("fine-groups\t\(payload.fineGroupCount)")
    }
}

struct GroupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Query capture groups from the current app-owned index.",
        subcommands: [GroupsListCommand.self, GroupsShowCommand.self, GroupsInspectCommand.self]
    )
}

struct GroupsInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Materialize bounded JPEG/OCR evidence for one capture group."
    )

    @Argument(help: "Capture group identifier from groups list.")
    var id: String

    @Option(name: .long, help: "Expected index run identifier.")
    var indexRun: String

    @Option(name: .long, help: "Evidence output directory.")
    var output: String

    @Option(name: .long, help: "Maximum sample count (1...12).")
    var samples = 12

    @Option(name: .long, help: "One-based asset page number.")
    var page = 1

    @Option(name: .long, help: "Assets per page (1...12).")
    var pageSize = 12

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        let request = CommandRequest(
            method: "groups.inspect",
            arguments: [
                "id": id,
                "index-run": indexRun,
                "output": URL(fileURLWithPath: output).standardizedFileURL.path,
                "samples": String(samples),
                "page": String(page),
                "page-size": String(pageSize),
            ]
        )
        let data = try AppConnection().run(request, as: EvidenceInspectionPayload.self)
        if format == "json" {
            writeJSON(data)
            return
        }
        let payload = try CanonicalJSON.decode(EvidenceInspectionPayload.self, from: data)
        print("group-id\t\(payload.groupID)")
        print("index-run\t\(payload.indexRunID)")
        print("evidence-json\t\(payload.evidenceJSON)")
        print("summary\t\(payload.summaryMarkdown)")
        print("samples\t\(payload.sampleFiles.count)")
        print("page\t\(payload.page.pageNumber)/\(payload.page.totalPages)")
        print("covered-assets\t\(payload.page.assetIDs.count)")
    }
}

struct GroupsShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show bounded metadata for one capture group."
    )

    @Argument(help: "Capture group identifier from groups list.")
    var id: String

    @Option(name: .long, help: "Expected index run identifier.")
    var indexRun: String?

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        var arguments = ["id": id]
        if let indexRun { arguments["index-run"] = indexRun }
        let request = CommandRequest(method: "groups.show", arguments: arguments)
        let data = try AppConnection().run(request, as: GroupDetailPayload.self)
        if format == "json" {
            writeJSON(data)
            return
        }
        let payload = try CanonicalJSON.decode(GroupDetailPayload.self, from: data)
        print("group-id\t\(payload.group.id)")
        print("index-run\t\(payload.indexRunID)")
        print("assets\t\(payload.assets.count)")
        print("asset-id\tcaptured-at\tkind\tduration\tfilename\tlocation")
        let formatter = ISO8601DateFormatter()
        for asset in payload.assets {
            let capturedAt = asset.capturedAt.map(formatter.string(from:)) ?? "-"
            print("\(asset.id)\t\(capturedAt)\t\(asset.mediaKind.rawValue)\t\(asset.durationSeconds)\t\(asset.publicFilename ?? "-")\t\(asset.hasLocation)")
        }
    }
}

struct GroupsListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List deterministic capture groups."
    )

    @Option(name: .long, help: "Indexed local date (included in the request contract).")
    var date: String?

    @Option(name: .long, help: "Grouping level: coarse, fine, or media-kind.")
    var level = "fine"

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        guard let requestedLevel = GroupLevel(rawValue: level) else {
            throw CLIError.commandFailed("Unsupported grouping level: \(level)")
        }
        var arguments = ["level": requestedLevel.rawValue]
        if let date { arguments["date"] = date }
        let request = CommandRequest(method: "groups.list", arguments: arguments)
        let data = try AppConnection().run(request, as: GroupsPayload.self)
        let payload = try CanonicalJSON.decode(GroupsPayload.self, from: data)
        guard payload.level == requestedLevel else {
            throw CLIError.commandFailed(
                "The app returned \(payload.level.rawValue) groups for a \(requestedLevel.rawValue) request"
            )
        }
        let groupsMatchRequest = payload.groups.allSatisfy { group in
            guard group.level == requestedLevel else { return false }
            return requestedLevel == .mediaKind
                ? group.mediaKind != nil
                : group.mediaKind == nil
        }
        guard groupsMatchRequest else {
            throw CLIError.commandFailed(
                "The app returned group entries that do not match the \(requestedLevel.rawValue) request"
            )
        }
        if format == "json" {
            writeJSON(data)
            return
        }
        print("group-id\tlevel\tmedia-kind\tstart\tend\tassets\twarnings")
        let formatter = ISO8601DateFormatter()
        for group in payload.groups {
            let start = group.start.map(formatter.string(from:)) ?? "-"
            let end = group.end.map(formatter.string(from:)) ?? "-"
            let mediaKind = group.mediaKind?.rawValue ?? "-"
            print("\(group.id)\t\(group.level.rawValue)\t\(mediaKind)\t\(start)\t\(end)\t\(group.assetIDs.count)\t\(group.warnings.joined(separator: ","))")
        }
    }
}

func writeJSON(_ data: Data) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}
