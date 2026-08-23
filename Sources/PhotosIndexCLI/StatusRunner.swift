import Foundation
import PhotosIndexCommand
import PhotosIndexCore

struct CommandRunner {
    let client: UnixCommandClient

    func run<Payload: Codable>(_ request: CommandRequest, as type: Payload.Type) throws -> Data {
        let response = try client.send(request)
        guard response.ok else {
            throw CLIError.commandFailed(response.error?.message ?? "Unknown command failure")
        }
        return try CanonicalJSON.encode(response.decodePayload(type))
    }
}

struct StatusRunner {
    let client: UnixCommandClient

    func run() throws -> Data {
        try CommandRunner(client: client).run(CommandRequest(method: "status"), as: StatusPayload.self)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case commandFailed(String)
    case appLaunchFailed
    case invalidFile(String)

    var description: String {
        switch self {
        case let .commandFailed(message): message
        case .appLaunchFailed: "Unable to launch PhotosIndex.app"
        case let .invalidFile(message): message
        }
    }
}
