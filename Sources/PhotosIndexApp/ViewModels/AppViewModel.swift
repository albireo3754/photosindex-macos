import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    let title = "PhotosIndex"
    @Published var permissionStatus: String
    @Published var socketPath: String
    @Published var lastError: String?

    init(permissionStatus: String, socketPath: String) {
        self.permissionStatus = permissionStatus
        self.socketPath = socketPath
    }
}
