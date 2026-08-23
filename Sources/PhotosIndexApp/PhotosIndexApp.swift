import SwiftUI

@main
struct PhotosIndexApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: container.viewModel)
                .frame(minWidth: 640, minHeight: 420)
        }
    }
}
