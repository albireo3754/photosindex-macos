import ArgumentParser
import Foundation
import PhotosIndexCommand
import PhotosIndexCore

struct DecisionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decisions",
        abstract: "Validate external model decisions against the current index.",
        subcommands: [DecisionsValidateCommand.self]
    )
}

struct DecisionsValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Validate a complete include/exclude ModelDecision."
    )

    @Option(name: .long, help: "Path to ModelDecision JSON.")
    var file: String

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        let data = try AppConnection().run(
            CommandRequest(
                method: "decisions.validate",
                arguments: ["file": URL(fileURLWithPath: file).standardizedFileURL.path]
            ),
            as: DecisionValidationPayload.self
        )
        if format == "json" {
            writeJSON(data)
            return
        }
        let payload = try CanonicalJSON.decode(DecisionValidationPayload.self, from: data)
        print("valid\t\(payload.valid)")
        print("index-run\t\(payload.indexRunID)")
        print("group-id\t\(payload.groupID)")
        print("included\t\(payload.includedAssetCount)")
        print("excluded\t\(payload.excludedAssetCount)")
    }
}

struct ExportRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Plan or apply a digest-bound copy-only export.",
        subcommands: [ExportPlanCommand.self, ExportApplyCommand.self]
    )
}

struct ExportPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Create a non-mutating export plan."
    )

    @Option(name: .long, help: "Path to validated ModelDecision JSON.")
    var decision: String

    @Option(name: .long, help: "Exact allowed iCloud Naver Clip root.")
    var to: String

    @Option(name: .long, help: "Layout name; currently dated-group only.")
    var layout = "dated-group"

    @Option(name: .long, help: "Write the canonical plan JSON here.")
    var output: String

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        guard layout == "dated-group" else {
            throw CLIError.commandFailed("Only --layout dated-group is supported")
        }
        let request = CommandRequest(
            method: "export.plan",
            arguments: [
                "decision": URL(fileURLWithPath: decision).standardizedFileURL.path,
                "to": URL(fileURLWithPath: to, isDirectory: true).standardizedFileURL.path,
                "layout": layout,
            ]
        )
        let data = try AppConnection().run(request, as: ExportPlanEnvelope.self)
        let envelope = try CanonicalJSON.decode(ExportPlanEnvelope.self, from: data)
        try writeNewFile(try CanonicalJSON.encode(envelope.plan), to: output)
        if format == "json" {
            writeJSON(data)
            return
        }
        print("plan\t\(URL(fileURLWithPath: output).standardizedFileURL.path)")
        print("digest\t\(envelope.digest)")
        print("destination\t\(envelope.plan.destinationRoot)")
        print("included\t\(envelope.plan.includedAssetIDs.count)")
    }
}

struct ExportApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply an app-issued export plan using its exact digest."
    )

    @Option(name: .long, help: "Path to canonical ExportPlan JSON.")
    var plan: String

    @Option(name: .long, help: "Exact SHA-256 returned by export plan.")
    var digest: String

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw CLIError.commandFailed("--digest must be a 64-character SHA-256")
        }
        let data = try AppConnection(
            receiveTimeout: AppConnection.longRunningReceiveTimeout
        ).run(
            CommandRequest(
                method: "export.apply",
                arguments: [
                    "plan": URL(fileURLWithPath: plan).standardizedFileURL.path,
                    "digest": digest.lowercased(),
                ]
            ),
            as: ExportReceipt.self
        )
        if format == "json" {
            writeJSON(data)
            return
        }
        let receipt = try CanonicalJSON.decode(ExportReceipt.self, from: data)
        print("destination\t\(receipt.destinationRoot)")
        print("files\t\(receipt.entries.count)")
        print("bytes\t\(receipt.entries.reduce(Int64(0)) { $0 + $1.bytes })")
    }
}

func writeNewFile(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw CLIError.invalidFile("Refusing to overwrite existing file: \(url.path)")
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}
