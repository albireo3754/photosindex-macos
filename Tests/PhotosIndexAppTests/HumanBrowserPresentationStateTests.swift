import XCTest
@testable import PhotosIndexApp

final class HumanBrowserPresentationStateTests: XCTestCase {
    func testRoutesSetupAndPermissionStates() {
        XCTAssertEqual(resolve(permissionStatus: "authorized"), .setup)
        XCTAssertEqual(resolve(permissionStatus: "not-determined"), .authorizationNeeded)
        XCTAssertEqual(resolve(permissionStatus: "denied"), .blocked)
        XCTAssertEqual(resolve(permissionStatus: "restricted"), .blocked)
    }

    func testRoutesLoadingAndIndexedStates() {
        XCTAssertEqual(resolve(busyPhase: .indexing), .loading)
        XCTAssertEqual(
            resolve(
                busyPhase: .loadingGroups,
                hasIndex: true,
                groupCount: 0
            ),
            .loading
        )
        XCTAssertEqual(
            resolve(
                busyPhase: .loadingGroups,
                hasIndex: true,
                groupCount: 2
            ),
            .browser
        )
        XCTAssertEqual(resolve(hasIndex: true), .noResults)
        XCTAssertEqual(resolve(hasIndex: true, groupCount: 2), .browser)
        XCTAssertEqual(
            resolve(
                busyPhase: .loadingGroupDetail,
                hasIndex: true,
                groupCount: 2,
                hasSelection: true
            ),
            .browser
        )
    }

    func testRoutesErrorsByTheirAvailableContext() {
        XCTAssertEqual(
            resolve(
                hasIndex: true,
                groupCount: 2,
                hasSelection: true,
                hasError: true
            ),
            .browser
        )
        XCTAssertEqual(resolve(hasError: true), .error)
        XCTAssertEqual(
            resolve(permissionStatus: "denied", hasError: true),
            .blocked
        )
        XCTAssertEqual(
            resolve(permissionStatus: "restricted", hasError: true),
            .blocked
        )
    }

    private func resolve(
        permissionStatus: String = "authorized",
        busyPhase: ManualQABusyPhase? = nil,
        hasIndex: Bool = false,
        groupCount: Int = 0,
        hasSelection: Bool = false,
        hasError: Bool = false
    ) -> HumanBrowserPresentationState {
        HumanBrowserPresentationState.resolve(
            permissionStatus: permissionStatus,
            busyPhase: busyPhase,
            hasIndex: hasIndex,
            groupCount: groupCount,
            hasSelection: hasSelection,
            hasError: hasError
        )
    }
}
