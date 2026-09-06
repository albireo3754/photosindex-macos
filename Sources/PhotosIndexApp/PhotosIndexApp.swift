import SwiftUI

@main
struct PhotosIndexApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: container.viewModel, mediaService: container.mediaService)
                .frame(minWidth: 960, minHeight: 620)
        }
    }
}
