import Foundation
import PhotosIndexCore

public enum CommandProtocol {
    public static let currentVersion = 1
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let method: String
    public let arguments: [String: String]

    public init(
        protocolVersion: Int = CommandProtocol.currentVersion,
        id: String = UUID().uuidString,
        method: String,
        arguments: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.method = method
        self.arguments = arguments
    }
}

public struct CommandFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recovery: String?

    public init(code: String, message: String, recovery: String? = nil) {
        self.code = code
        self.message = message
        self.recovery = recovery
    }
}

public struct CommandResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: String
    public let ok: Bool
    public let payload: Data?
    public let error: CommandFailure?

    public static func success<T: Encodable>(id: String, payload: T) throws -> CommandResponse {
        CommandResponse(
            protocolVersion: CommandProtocol.currentVersion,
            id: id,
            ok: true,
            payload: try CanonicalJSON.encode(payload),
            error: nil
        )
    }

    public static func failure(id: String, error: CommandFailure) -> CommandResponse {
        CommandResponse(
            protocolVersion: CommandProtocol.currentVersion,
            id: id,
            ok: false,
            payload: nil,
            error: error
        )
    }

    public func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else { throw CommandTransportError.missingPayload }
        return try CanonicalJSON.decode(type, from: payload)
    }
}

public struct StatusPayload: Codable, Equatable, Sendable {
    public let appVersion: String
    public let protocolVersion: Int
    public let permission: String

    public init(appVersion: String, protocolVersion: Int, permission: String) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.permission = permission
    }
}

public enum CommandTransportError: Error, Equatable {
    case missingPayload
    case responseIDMismatch
    case protocolMismatch
}
