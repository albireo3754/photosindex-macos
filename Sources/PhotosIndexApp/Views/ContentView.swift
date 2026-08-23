import Photos
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            List {
                Label("Timeline", systemImage: "calendar")
                Label("Groups", systemImage: "square.grid.2x2")
            }
            .navigationTitle(viewModel.title)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("Local Apple Photos index")
                    .font(.title2)
                LabeledContent("Photos permission", value: viewModel.permissionStatus)
                LabeledContent("CLI socket", value: viewModel.socketPath)
                    .textSelection(.enabled)
                if let error = viewModel.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Request Photos Access") {
                    PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                        Task { @MainActor in
                            viewModel.permissionStatus = Self.permissionName(status)
                        }
                    }
                }
                Spacer()
            }
            .padding(24)
        }
    }

    private static func permissionName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .limited: "limited"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not-determined"
        @unknown default: "unknown"
        }
    }
}
