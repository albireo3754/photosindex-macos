import Foundation
import PhotosIndexCore
import SwiftUI

enum HumanBrowserPresentationState: Equatable {
    case setup
    case authorizationNeeded
    case blocked
    case loading
    case noResults
    case browser
    case error

    static func resolve(
        permissionStatus: String,
        busyPhase: ManualQABusyPhase?,
        hasIndex: Bool,
        groupCount: Int,
        hasSelection: Bool,
        hasError: Bool
    ) -> Self {
        if busyPhase != nil {
            if groupCount > 0 {
                return .browser
            }
            return .loading
        }

        switch normalizedPhotoPermissionStatus(permissionStatus) {
        case "not-determined", "unknown":
            return .authorizationNeeded
        case "denied", "restricted":
            return .blocked
        default:
            break
        }

        if hasError {
            return groupCount > 0 && hasSelection ? .browser : .error
        }

        guard hasIndex else { return .setup }
        return groupCount > 0 ? .browser : .noResults
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    let mediaService: any HumanMediaServing
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            if presentationState == .browser {
                NavigationSplitView {
                    CaptureGroupListView(viewModel: viewModel)
                        .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 460)
                } detail: {
                    CaptureGroupDetailView(viewModel: viewModel, mediaService: mediaService)
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                HumanBrowserWorkspace(
                    viewModel: viewModel,
                    presentationState: presentationState
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualQAElement.workspace.rawValue)
        .accessibilityLabel("PhotosIndex browser")
        .accessibilityValue(viewModel.manualQAState.accessibilityValue)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await viewModel.refreshPhotosAccess()
            }
        }
    }

    private var presentationState: HumanBrowserPresentationState {
        HumanBrowserPresentationState.resolve(
            permissionStatus: viewModel.permissionStatus,
            busyPhase: viewModel.manualQAState.busyPhase,
            hasIndex: viewModel.syncResult != nil,
            groupCount: viewModel.groups.count,
            hasSelection: viewModel.selectedGroupID != nil,
            hasError: viewModel.lastError != nil
        )
    }
}

struct HumanBrowserWorkspace: View {
    @ObservedObject var viewModel: AppViewModel
    let presentationState: HumanBrowserPresentationState
    @State private var isAgentConnectionExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            workspaceContent
            privacyDisclosure
        }
        .padding(40)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedDate: Binding<Date> {
        Binding(
            get: { viewModel.selectedDate },
            set: { viewModel.selectDate($0) }
        )
    }

    private var permissionStatus: String {
        normalizedPhotoPermissionStatus(viewModel.permissionStatus)
    }

    private var canRequestPhotosAccess: Bool {
        permissionStatus == "not-determined" || permissionStatus == "unknown"
    }

    private var canIndex: Bool {
        permissionStatus == "authorized" || permissionStatus == "limited"
    }

    private func indexSelectedDate() {
        guard !viewModel.isBusy, canIndex else { return }
        Task {
            await viewModel.indexSelectedDate()
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch presentationState {
        case .loading:
            VStack(alignment: .center, spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(busyLabel)
                    .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                    .accessibilityValue("state=\(busyState)")

                Text(busyLabel)
                    .font(.headline)
                    .accessibilityIdentifier(ManualQAElement.groupListStatus.rawValue)
                    .accessibilityValue("state=\(busyState)")

                Text("This can take a moment. Your library is not changed.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        case .error:
            errorWorkspace
        case .blocked:
            blockedWorkspace
        case .authorizationNeeded:
            authorizationWorkspace
        case .noResults:
            noResultsWorkspace
        case .setup:
            setupWorkspace
        case .browser:
            EmptyView()
        }
    }

    private var setupWorkspace: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Browse a day in your library")
                .font(.largeTitle.weight(.semibold))
            Text("Choose a calendar day to gather its capture groups, preview photos, and play videos.")
                .font(.title3)
                .foregroundStyle(.secondary)
            limitedAccessBanner
            datePicker
            Button(action: indexSelectedDate) {
                Text(indexActionTitle)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(ManualQAElement.indexDateButton.rawValue)
                .disabled(!canIndex)
            Text("Browsing is read-only. Nothing is changed in Photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                .accessibilityValue("state=not-indexed;groups=0")
        }
    }

    private var authorizationWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Allow Photos access", systemImage: "photo.badge.plus")
                .font(.title2)
                .accessibilityIdentifier(ManualQAElement.permissionStatus.rawValue)
                .accessibilityValue("status=\(permissionStatus)")
            Text("Photos access is needed to index the calendar day you choose.")
                .foregroundStyle(.secondary)
            datePicker
            Button(action: requestPhotosAccess) {
                Text("Allow Photos Access")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(ManualQAElement.requestPhotosAccessButton.rawValue)
        }
    }

    private var blockedWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(blockedTitle, systemImage: permissionStatus == "denied" ? "hand.raised" : "lock")
                .font(.title2)
                .accessibilityIdentifier(ManualQAElement.permissionStatus.rawValue)
                .accessibilityValue("status=\(permissionStatus)")
            Text(blockedMessage)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ManualQAElement.permissionGuidance.rawValue)
                .accessibilityValue("state=\(permissionStatus)")
            datePicker
            Button(action: refreshPhotosAccess) {
                Text("Refresh Photos Access")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(ManualQAElement.refreshPhotosAccessButton.rawValue)
        }
    }

    private var noResultsWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("No capture groups", systemImage: "tray")
                .font(.title2)
            Text("No Photos items matched this calendar day and grouping.")
                .foregroundStyle(.secondary)
            limitedAccessBanner
            datePicker
            groupingPicker
            Text("Groups use capture time and approximate proximity. They are browsing cohorts, not event labels.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(action: indexSelectedDate) {
                Text(reindexActionTitle)
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(ManualQAElement.indexDateButton.rawValue)
                .disabled(!canIndex)
            VStack(alignment: .leading) {
                Text("No groups found for this grouping level.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                    .accessibilityValue("state=no-groups;level=\(viewModel.selectedLevel.rawValue);groups=0")
            }
            .accessibilityIdentifier(ManualQAElement.groupListStatus.rawValue)
            .accessibilityValue("state=no-groups;level=\(viewModel.selectedLevel.rawValue);groups=0")
        }
    }

    private var errorWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Try again", systemImage: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.red)
            Text("PhotosIndex couldn’t complete the request. Please try again.")
                .foregroundStyle(.secondary)
            datePicker
            if canIndex {
                Button(action: indexSelectedDate) {
                    Text("Retry Indexing")
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(ManualQAElement.indexDateButton.rawValue)
            } else {
                Button(action: refreshPhotosAccess) {
                    Text("Refresh Photos Access")
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(ManualQAElement.refreshPhotosAccessButton.rawValue)
            }
            Text("The request needs another try.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                .accessibilityValue("state=error")
        }
    }

    private var datePicker: some View {
        GroupBox {
            DatePicker(
                "Calendar day",
                selection: selectedDate,
                displayedComponents: .date
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
            .frame(width: 220, alignment: .leading)
            .accessibilityIdentifier(ManualQAElement.datePicker.rawValue)
            .accessibilityLabel("Calendar date (Asia/Seoul)")
            .disabled(viewModel.isBusy)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendar day")
                    .font(.headline)
                Text("Asia/Seoul time")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var groupingPicker: some View {
        Picker("Grouping", selection: selectedLevel) {
            Text("Fine").tag(GroupLevel.fine)
            Text("Coarse").tag(GroupLevel.coarse)
            Text("Media kind").tag(GroupLevel.mediaKind)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(ManualQAElement.groupLevelPicker.rawValue)
        .accessibilityValue("level=\(viewModel.selectedLevel.rawValue)")
        .disabled(viewModel.isBusy || viewModel.syncResult == nil)
    }

    @ViewBuilder
    private var limitedAccessBanner: some View {
        if permissionStatus == "limited" {
            VStack(alignment: .leading) {
                Label("Only selected Photos items can be indexed. Change the selection in Photos privacy settings if needed.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(ManualQAElement.permissionGuidance.rawValue)
                    .accessibilityValue("state=limited")
            }
            .accessibilityIdentifier(ManualQAElement.permissionStatus.rawValue)
            .accessibilityValue("status=limited")
        }
    }

    private var selectedLevel: Binding<GroupLevel> {
        Binding(
            get: { viewModel.selectedLevel },
            set: { level in
                Task {
                    await viewModel.selectLevel(level)
                }
            }
        )
    }

    private var blockedTitle: String {
        permissionStatus == "denied" ? "Photos access is off" : "Photos access is restricted"
    }

    private var blockedMessage: String {
        if permissionStatus == "denied" {
            "Open System Settings, choose Privacy & Security, then Photos, and allow PhotosIndex."
        } else {
            "Photos access is restricted by this Mac or account. Ask the device administrator to allow it."
        }
    }

    private var indexActionTitle: String {
        "Browse \(selectedDay)"
    }

    private var reindexActionTitle: String {
        "Re-index \(selectedDay)"
    }

    private var selectedDay: String {
        Self.selectedDayFormatter.string(from: viewModel.selectedDate)
    }

    private static let selectedDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")!
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private var privacyDisclosure: some View {
        DisclosureGroup(isExpanded: $isAgentConnectionExpanded) {
            Text("Preview photos and play videos here without changing your library. Media stays in this local app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("Your library stays private", systemImage: "lock")
        }
        .accessibilityIdentifier(ManualQAElement.agentConnectionDisclosure.rawValue)
        .accessibilityValue("state=\(isAgentConnectionExpanded ? "expanded" : "collapsed")")
        .disabled(viewModel.isBusy)
    }

    private func requestPhotosAccess() {
        Task {
            await viewModel.requestPhotosAccess()
        }
    }

    private func refreshPhotosAccess() {
        Task {
            await viewModel.refreshPhotosAccess()
        }
    }

    private var busyLabel: String {
        switch viewModel.manualQAState.busyPhase {
        case .requestingPhotosAccess: "Requesting Photos access…"
        case .indexing: "Indexing date…"
        case .loadingGroups: "Loading groups…"
        case .loadingGroupDetail: "Loading group details…"
        case nil: "Working…"
        }
    }

    private var busyState: String {
        viewModel.manualQAState.busyPhase?.rawValue ?? "working"
    }
}

struct CaptureGroupListView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isPrivacyDisclosureExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupListHeader

            Divider()

            groupContent
        }
    }

    private var groupListHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Capture groups")
                    .font(.headline)
                Spacer()
                Button("Re-index", action: indexSelectedDate)
                    .accessibilityIdentifier(ManualQAElement.indexDateButton.rawValue)
                    .disabled(viewModel.isBusy)
            }

            DatePicker("Date", selection: selectedDate, displayedComponents: .date)
                .datePickerStyle(.compact)
                .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
                .accessibilityIdentifier(ManualQAElement.datePicker.rawValue)
                .accessibilityLabel("Calendar date (Asia/Seoul)")
                .disabled(viewModel.isBusy)

            if viewModel.permissionStatus == "limited" {
                limitedAccessBanner
            }

            if let syncResult = viewModel.syncResult {
                LabeledContent("Indexed", value: "\(syncResult.assetCount) assets · \(viewModel.groups.count) groups")
                    .font(.callout)
                    .accessibilityIdentifier(ManualQAElement.workflowState.rawValue)
                    .accessibilityValue(
                        "state=indexed;level=\(viewModel.selectedLevel.rawValue);assets=\(syncResult.assetCount);groups=\(viewModel.groups.count)"
                    )
            }

            Picker("Grouping", selection: selectedLevel) {
                Text("Fine").tag(GroupLevel.fine)
                Text("Coarse").tag(GroupLevel.coarse)
                Text("Media kind").tag(GroupLevel.mediaKind)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(ManualQAElement.groupLevelPicker.rawValue)
            .accessibilityValue("level=\(viewModel.selectedLevel.rawValue)")
            .disabled(viewModel.isBusy || viewModel.syncResult == nil)

            Text("Groups use capture time and approximate proximity. They are browsing cohorts, not event labels.")
                .font(.callout)
                .foregroundStyle(.secondary)

            DisclosureGroup(isExpanded: $isPrivacyDisclosureExpanded) {
                Text("Preview photos and play videos here without changing your library. Media stays in this local app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } label: {
                Label("Your library stays private", systemImage: "lock")
            }
            .accessibilityIdentifier(ManualQAElement.agentConnectionDisclosure.rawValue)
            .accessibilityValue("state=\(isPrivacyDisclosureExpanded ? "expanded" : "collapsed")")
            .disabled(viewModel.isBusy)
        }
        .padding()
    }

    private var selectedDate: Binding<Date> {
        Binding(
            get: { viewModel.selectedDate },
            set: { viewModel.selectDate($0) }
        )
    }

    private var limitedAccessBanner: some View {
        VStack(alignment: .leading) {
            Label("Only selected Photos items can be indexed. Change the selection in Photos privacy settings if needed.", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(ManualQAElement.permissionGuidance.rawValue)
                .accessibilityValue("state=limited")
        }
        .accessibilityIdentifier(ManualQAElement.permissionStatus.rawValue)
        .accessibilityValue("status=limited")
    }

    private var selectedLevel: Binding<GroupLevel> {
        Binding(
            get: { viewModel.selectedLevel },
            set: { level in
                Task {
                    await viewModel.selectLevel(level)
                }
            }
        )
    }

    @ViewBuilder
    private var groupContent: some View {
        if viewModel.isIndexing || viewModel.isLoadingGroups {
            centeredProgress("Loading capture groups…", state: "loading-groups")
        } else {
            List(selection: selectedGroupID) {
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                    CaptureGroupRow(
                        group: group,
                        ordinal: index + 1,
                        isSelected: viewModel.selectedGroupID == group.id
                    )
                    .tag(group.id)
                    .disabled(viewModel.isBusy)
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(ManualQAElement.groupList.rawValue)
            .accessibilityValue(
                "level=\(viewModel.selectedLevel.rawValue);groups=\(viewModel.groups.count)"
            )
        }
    }

    private func centeredProgress(_ label: String, state: String) -> some View {
        ProgressView(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(ManualQAElement.groupListStatus.rawValue)
            .accessibilityValue("state=\(state)")
    }

    private var selectedGroupID: Binding<String?> {
        Binding(
            get: { viewModel.selectedGroupID },
            set: { id in
                guard let id else {
                    viewModel.clearGroupSelection()
                    return
                }
                Task {
                    await viewModel.selectGroup(id)
                }
            }
        )
    }

    private func indexSelectedDate() {
        guard !viewModel.isBusy else { return }
        Task {
            await viewModel.indexSelectedDate()
        }
    }
}

private struct CaptureGroupRow: View {
    let group: CaptureGroup
    let ordinal: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Group \(ordinal)")
                    .font(.headline)
                Spacer()
                if let mediaKind = group.mediaKind {
                    Text(mediaKind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(HumanBrowserFormatting.timeRange(start: group.start, end: group.end))
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Label("\(group.assetIDs.count) assets", systemImage: "photo.on.rectangle")
                Label("\(group.warnings.count) warnings", systemImage: "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("\(ManualQAElement.groupRow.rawValue).\(ordinal)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            "ordinal=\(ordinal);level=\(group.level.rawValue);assets=\(group.assetIDs.count);warnings=\(group.warnings.count);selected=\(isSelected)"
        )
    }

    private var accessibilityLabel: String {
        var parts = [
            "Group \(ordinal)",
            HumanBrowserFormatting.timeRange(start: group.start, end: group.end),
            "\(group.assetIDs.count) assets",
            "\(group.warnings.count) warnings",
        ]
        if let mediaKind = group.mediaKind {
            parts.append(mediaKind.displayName)
        }
        return parts.joined(separator: ", ")
    }
}

struct CaptureGroupDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let mediaService: any HumanMediaServing
    @State private var selectedMedia: MediaSelection?
    @StateObject private var preview = MediaPreviewModel()

    var body: some View {
        Group {
            if viewModel.isLoadingGroupDetail {
                ProgressView("Loading group details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(ManualQAElement.groupDetailStatus.rawValue)
                    .accessibilityValue("state=loading-detail")
            } else if let detail = viewModel.selectedGroupDetail {
                detailList(detail)
            } else if viewModel.lastError != nil, viewModel.selectedGroupID != nil {
                detailError
            } else {
                ContentUnavailableView(
                    "Select a group",
                    systemImage: "rectangle.stack",
                    description: Text("Choose a group to preview its photos and videos.")
                )
                .accessibilityIdentifier(ManualQAElement.groupDetailStatus.rawValue)
                .accessibilityValue("state=no-selection;assets=0;warnings=0")
            }
        }
        .navigationTitle(detailTitle)
        .sheet(item: $selectedMedia, onDismiss: { preview.clear() }) { selection in
            MediaViewer(selection: selection, service: mediaService, model: preview) {
                closeMedia()
            }
        }
        .onChange(of: mediaContext) { _, _ in closeMedia() }
        .onDisappear { closeMedia() }
    }

    private var mediaContext: [String] {
        [viewModel.selectedGroupDetail?.indexRunID ?? "",
         viewModel.selectedGroupDetail?.group.id ?? "",
         viewModel.syncResult?.indexRunID ?? "",
         viewModel.selectedGroupID ?? "", viewModel.permissionStatus,
         String(viewModel.selectedDate.timeIntervalSinceReferenceDate)]
    }

    private func closeMedia() {
        preview.clear()
        selectedMedia = nil
    }

    private var detailTitle: String {
        guard let ordinal = selectedGroupOrdinal else { return "Group details" }
        return "Group \(ordinal) details"
    }

    private var selectedGroupOrdinal: Int? {
        guard let selectedGroupID = viewModel.selectedGroupID,
              let index = viewModel.groups.firstIndex(where: { $0.id == selectedGroupID })
        else {
            return nil
        }
        return index + 1
    }

    private var detailError: some View {
        ContentUnavailableView {
            Label("Couldn’t load this group", systemImage: "exclamationmark.circle")
        } description: {
            Text("PhotosIndex couldn’t load the group’s safe metadata. Please try again.")
        } actions: {
            Button("Retry", action: retrySelectedGroup)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier(ManualQAElement.groupDetailStatus.rawValue)
        .accessibilityValue("state=error")
    }

    private func retrySelectedGroup() {
        guard let selectedGroupID = viewModel.selectedGroupID,
              !viewModel.isBusy
        else { return }
        Task {
            await viewModel.selectGroup(selectedGroupID)
        }
    }

    private func detailList(_ detail: GroupDetailPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HumanBrowserFormatting.timeRange(start: detail.group.start, end: detail.group.end))
                        .font(.headline)
                    Text("\(detail.assets.count) assets · \(detail.group.warnings.count) warnings")
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier(ManualQAElement.groupDetail.rawValue)
                .accessibilityValue(
                    "state=loaded;level=\(detail.group.level.rawValue);assets=\(detail.assets.count);warnings=\(detail.group.warnings.count)"
                )

                MediaBrowserView(detail: detail, service: mediaService) { selection in
                    preview.clear()
                    selectedMedia = selection
                }
                .id(mediaContext)
            }
            .padding()
        }
    }
}

enum HumanBrowserFormatting {
    static func timestamp(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year!,
            components.month!,
            components.day!,
            components.hour!,
            components.minute!,
            components.second!
        )
    }

    static func timeRange(start: Date?, end: Date?) -> String {
        switch (start, end) {
        case let (start?, end?) where start == end:
            timestamp(start)
        case let (start?, end?):
            "\(timestamp(start)) – \(timestamp(end))"
        case let (start?, nil):
            timestamp(start)
        case let (nil, end?):
            timestamp(end)
        case (nil, nil):
            "Unknown capture time"
        }
    }

    static func dimensions(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "Unknown" }
        return "\(width) × \(height)"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Unknown" }
        return String(
            format: "%.1f seconds",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
    }
}

extension MediaKind {
    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}
