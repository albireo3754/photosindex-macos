import AppKit
import Darwin
import Foundation
import PhotosIndexCommand

struct AppConnection {
    static let longRunningReceiveTimeout: TimeInterval = 4 * 60 * 60

    let environment: [String: String]
    let receiveTimeout: TimeInterval

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        receiveTimeout: TimeInterval = 3_700
    ) {
        self.environment = environment
        self.receiveTimeout = receiveTimeout
    }

    func run<Payload: Codable>(_ request: CommandRequest, as type: Payload.Type) throws -> Data {
        let socketPath = environment["PHOTOSINDEX_SOCKET_PATH"] ?? "/tmp/photosindex-\(getuid()).sock"
        let runner = CommandRunner(
            client: UnixCommandClient(path: socketPath, receiveTimeout: receiveTimeout)
        )
        do {
            return try runner.run(request, as: type)
        } catch let error as CLIError {
            throw error
        } catch let error as UnixSocketError {
            guard case .connectFailed = error else { throw error }
            // A connection failure means the app may not be running yet.
        } catch {
            throw error
        }

        guard let appPath = resolveAppPath() else {
            throw CLIError.appLaunchFailed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-gj", appPath]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CLIError.appLaunchFailed }

        for _ in 0..<100 {
            do {
                return try runner.run(request, as: type)
            } catch let error as CLIError {
                throw error
            } catch let error as UnixSocketError {
                guard case .connectFailed = error else { throw error }
                usleep(50_000)
            } catch {
                throw error
            }
        }
        throw CLIError.appLaunchFailed
    }

    func resolveAppPath() -> String? {
        if let override = environment["PHOTOSINDEX_APP_PATH"] {
            return override
        }
        if let installed = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "dev.pray.PhotosIndex"
        ) {
            return installed.path
        }
        let candidates = [
            "/Applications/PhotosIndex.app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/PhotosIndex.app").path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
