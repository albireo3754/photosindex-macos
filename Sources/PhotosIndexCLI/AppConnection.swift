import AppKit
import Darwin
import Foundation
import PhotosIndexCommand

struct AppConnection {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func run<Payload: Codable>(_ request: CommandRequest, as type: Payload.Type) throws -> Data {
        let socketPath = environment["PHOTOSINDEX_SOCKET_PATH"] ?? "/tmp/photosindex-\(getuid()).sock"
        let runner = CommandRunner(client: UnixCommandClient(path: socketPath))
        do {
            return try runner.run(request, as: type)
        } catch let error as CLIError {
            throw error
        } catch {
            // A transport failure means the app may not be running yet.
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
            } catch {
                usleep(50_000)
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
