import XCTest
@testable import PhotosIndexApp

@MainActor
final class AppViewModelTests: XCTestCase {
    func testDisplaysCurrentPermissionAndSocketState() {
        let model = AppViewModel(
            permissionStatus: "authorized",
            socketPath: "/tmp/photosindex-501.sock"
        )

        XCTAssertEqual(model.permissionStatus, "authorized")
        XCTAssertEqual(model.socketPath, "/tmp/photosindex-501.sock")
        XCTAssertEqual(model.title, "PhotosIndex")
    }
}
