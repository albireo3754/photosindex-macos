import XCTest
@testable import PhotosIndexApp

final class ManualQAContractTests: XCTestCase {
    func testAvailableActionsFollowCurrentWorkflowState() {
        let unauthorized = ManualQAState(
            permissionStatus: "not-determined",
            busyPhase: nil,
            hasIndex: false,
            groupCount: 0
        )
        XCTAssertEqual(
            unauthorized.availableActions,
            [.requestPhotosAccess, .selectDate]
        )

        let denied = ManualQAState(
            permissionStatus: "denied",
            busyPhase: nil,
            hasIndex: false,
            groupCount: 0
        )
        XCTAssertEqual(denied.availableActions, [.refreshPhotosAccess, .selectDate])

        let ready = ManualQAState(
            permissionStatus: "authorized",
            busyPhase: nil,
            hasIndex: false,
            groupCount: 0
        )
        XCTAssertEqual(ready.availableActions, [.selectDate, .indexDate])

        let indexed = ManualQAState(
            permissionStatus: "limited",
            busyPhase: nil,
            hasIndex: true,
            groupCount: 2
        )
        XCTAssertEqual(
            indexed.availableActions,
            [.selectDate, .indexDate, .selectGroupLevel, .openGroup]
        )

        let indexing = ManualQAState(
            permissionStatus: "authorized",
            busyPhase: .indexing,
            hasIndex: false,
            groupCount: 0
        )
        XCTAssertEqual(indexing.availableActions, [])
    }

    func testAccessibilityValueIsStableAndMachineReadable() {
        let state = ManualQAState(
            permissionStatus: "authorized",
            busyPhase: nil,
            hasIndex: true,
            groupCount: 2
        )

        XCTAssertEqual(
            state.accessibilityValue,
            "permission=authorized;phase=indexed;groups=2;actions=select-date,index-date,select-group-level,open-group"
        )
        XCTAssertFalse(state.accessibilityValue.contains("2030-02-03"))
    }

    func testAccessibilityValueNormalizesUnexpectedPermissionText() {
        let state = ManualQAState(
            permissionStatus: "synthetic-private-value",
            busyPhase: nil,
            hasIndex: false,
            groupCount: 0
        )

        XCTAssertEqual(
            state.accessibilityValue,
            "permission=unknown;phase=needs-authorization;groups=0;actions=request-photos-access,select-date"
        )
        XCTAssertFalse(state.accessibilityValue.contains("synthetic-private-value"))
    }

    func testEveryBusyPhaseSuppressesActionsAndIsSerialized() {
        for phase in ManualQABusyPhase.allCases {
            let state = ManualQAState(
                permissionStatus: "authorized",
                busyPhase: phase,
                hasIndex: true,
                groupCount: 2
            )

            XCTAssertEqual(state.availableActions, [])
            XCTAssertTrue(state.accessibilityValue.contains("phase=\(phase.rawValue)"))
        }
    }

    func testManualQAActionsExcludeAgentOnlyAndDestructiveOperations() {
        XCTAssertEqual(
            ManualQAAction.allCases,
            [
                .requestPhotosAccess,
                .refreshPhotosAccess,
                .selectDate,
                .indexDate,
                .selectGroupLevel,
                .openGroup,
            ]
        )

        let actionNames = ManualQAAction.allCases.map(\.rawValue).joined(separator: ",")
        for excludedAction in ["evidence", "classify", "export", "move", "delete"] {
            XCTAssertFalse(actionNames.contains(excludedAction))
        }
    }

    func testAccessibilityIdentifiersAreStableAndUnique() {
        XCTAssertEqual(Set(ManualQAElement.allCases.map(\.rawValue)).count, ManualQAElement.allCases.count)
        XCTAssertTrue(ManualQAElement.allCases.allSatisfy { $0.rawValue.hasPrefix("photosindex.") })
    }
}
