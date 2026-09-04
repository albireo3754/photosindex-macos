import Foundation

enum ManualQAAction: String, CaseIterable, Equatable {
    case requestPhotosAccess = "request-photos-access"
    case refreshPhotosAccess = "refresh-photos-access"
    case selectDate = "select-date"
    case indexDate = "index-date"
    case selectGroupLevel = "select-group-level"
    case openGroup = "open-group"
}

enum ManualQABusyPhase: String, CaseIterable, Equatable {
    case requestingPhotosAccess = "requesting-access"
    case indexing
    case loadingGroups = "loading-groups"
    case loadingGroupDetail = "loading-detail"
}

enum ManualQAElement: String, CaseIterable {
    case workspace = "photosindex.workspace"
    case workflowState = "photosindex.workflow-state"
    case permissionStatus = "photosindex.permission-status"
    case permissionGuidance = "photosindex.permission-guidance"
    case requestPhotosAccessButton = "photosindex.request-photos-access"
    case refreshPhotosAccessButton = "photosindex.refresh-photos-access"
    case datePicker = "photosindex.calendar-date"
    case indexDateButton = "photosindex.index-date"
    case agentConnectionDisclosure = "photosindex.agent-connection"
    case groupLevelPicker = "photosindex.group-level"
    case groupList = "photosindex.group-list"
    case groupRow = "photosindex.group-row"
    case groupDetail = "photosindex.group-detail"
    case assetList = "photosindex.asset-list"
    case assetRow = "photosindex.asset-row"
    case sidebarStatus = "photosindex.sidebar-status"
    case groupListStatus = "photosindex.group-list-status"
    case groupDetailStatus = "photosindex.group-detail-status"
}

struct ManualQAState: Equatable {
    let permissionStatus: String
    let busyPhase: ManualQABusyPhase?
    let hasIndex: Bool
    let groupCount: Int

    var availableActions: [ManualQAAction] {
        guard busyPhase == nil else { return [] }
        if Self.canRequestPhotosAccess(normalizedPhotoPermissionStatus(permissionStatus)) {
            return [.requestPhotosAccess, .selectDate]
        }
        guard Self.canReadPhotos(normalizedPhotoPermissionStatus(permissionStatus)) else {
            return [.refreshPhotosAccess, .selectDate]
        }

        var actions: [ManualQAAction] = [.selectDate, .indexDate]
        if hasIndex {
            actions.append(.selectGroupLevel)
        }
        if groupCount > 0 {
            actions.append(.openGroup)
        }
        return actions
    }

    var accessibilityValue: String {
        let phase: String
        if let busyPhase {
            phase = busyPhase.rawValue
        } else if hasIndex {
            phase = "indexed"
        } else if Self.canReadPhotos(normalizedPhotoPermissionStatus(permissionStatus)) {
            phase = "ready"
        } else if ["denied", "restricted"].contains(normalizedPhotoPermissionStatus(permissionStatus)) {
            phase = "blocked"
        } else {
            phase = "needs-authorization"
        }
        let actions = availableActions.map(\.rawValue).joined(separator: ",")
        return "permission=\(normalizedPhotoPermissionStatus(permissionStatus));phase=\(phase);groups=\(groupCount);actions=\(actions)"
    }

    private static func canReadPhotos(_ status: String) -> Bool {
        status == "authorized" || status == "limited"
    }

    private static func canRequestPhotosAccess(_ status: String) -> Bool {
        status == "not-determined" || status == "unknown"
    }
}

func normalizedPhotoPermissionStatus(_ status: String) -> String {
    switch status {
    case "authorized", "limited", "denied", "restricted", "not-determined", "unknown":
        status
    default:
        "unknown"
    }
}
