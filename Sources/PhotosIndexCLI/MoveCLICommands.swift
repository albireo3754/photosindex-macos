import ArgumentParser
import Foundation
import PhotosIndexCommand
import PhotosIndexCore

struct MoveRootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Copy selected originals to iCloud, verify them, then delete the exact Photos sources.",
        subcommands: [MovePlanCommand.self, MoveApplyCommand.self]
    )
}

struct MovePlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Create a non-mutating, digest-bound verified move plan."
    )

    @Option(name: .long, help: "Path to validated ModelDecision JSON.")
    var decision: String

    @Option(name: .long, help: "Exact allowed iCloud Naver Clip root.")
    var to: String

    @Option(name: .long, help: "Layout name; currently dated-group only.")
    var layout = "dated-group"

    @Option(name: .long, help: "Write the canonical MovePlan JSON here.")
    var output: String

    @Option(name: .long, help: "Output format: json or table.")
    var format = "table"

    mutating func run() throws {
        guard layout == "dated-group" else {
            throw CLIError.commandFailed("Only --layout dated-group is supported")
        }
        let data = try AppConnection().run(
            CommandRequest(
                method: "move.plan",
                arguments: [
                    "decision": URL(fileURLWithPath: decision).standardizedFileURL.path,
                    "to": URL(fileURLWithPath: to, isDirectory: true).standardizedFileURL.path,
                    "layout": layout,
                ]
            ),
            as: MovePlanEnvelope.self
        )
        let envelope = try CanonicalJSON.decode(MovePlanEnvelope.self, from: data)
        try writeNewFile(try CanonicalJSON.encode(envelope.plan), to: output)
        if format == "json" {
            writeJSON(data)
            return
        }
        print("plan\t\(URL(fileURLWithPath: output).standardizedFileURL.path)")
        print("digest\t\(envelope.digest)")
        print("destination\t\(envelope.plan.exportPlan.destinationRoot)")
        print("included\t\(envelope.plan.exportPlan.includedAssetIDs.count)")
        print("source-action\t\(envelope.plan.operation.rawValue)")
    }
}

struct MoveApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply an app-issued move plan after destination and iCloud verification."
    )

    @Option(name: .long, help: "Path to canonical MovePlan JSON.")
    var plan: String

    @Option(name: .long, help: "Exact SHA-256 returned by move plan.")
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
                method: "move.apply",
                arguments: [
                    "plan": URL(fileURLWithPath: plan).standardizedFileURL.path,
                    "digest": digest.lowercased(),
                ]
            ),
            as: MoveReceipt.self
        )
        if format == "json" {
            writeJSON(data)
            return
        }
        let receipt = try CanonicalJSON.decode(MoveReceipt.self, from: data)
        print("destination\t\(receipt.exportReceipt.destinationRoot)")
        print("files\t\(receipt.exportReceipt.entries.count)")
        print("bytes\t\(receipt.exportReceipt.entries.reduce(Int64(0)) { $0 + $1.bytes })")
        print("deleted-from-photos\t\(receipt.deletedAssetIDs.count)")
    }
}
