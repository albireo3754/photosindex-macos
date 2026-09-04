import Foundation
import PhotosIndexCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            HumanBrowserSidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } content: {
            CaptureGroupListView(viewModel: viewModel)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 440)
        } detail: {
            CaptureGroupDetailView(viewModel: viewModel)
        }
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
}

struct HumanBrowserSidebar: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isAgentConnectionExpanded = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Index one calendar day locally.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Browse groups and safe metadata.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Status", value: permissionLabel)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(ManualQAElement.permissionStatus.rawValue)
                    .accessibilityLabel("Photos permission")
                    .accessibilityValue("status=\(permissionStatus)")

                permissionGuidance
            } header: {
                Text("Photos access")
                    .font(.headline)
            }

            Section {
                workflowStatus
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Status")
                    .font(.headline)
            }

            Section {
                DisclosureGroup(isExpanded: $isAgentConnectionExpanded) {
                    Text("Local agents can connect while PhotosIndex is open. The connection is private to this macOS account.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Agent connection", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityIdentifier(ManualQAElement.agentConnectionDisclosure.rawValue)
                .accessibilityValue("state=\(isAgentConnectionExpanded ? "expanded" : "collapsed")")
                .disabled(viewModel.isBusy)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar date (Asia/Seoul)")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    DatePicker(
                        "Calendar date (Asia/Seoul)",
                        selection: selectedDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "Asia/Seoul")!)
                    .accessibilityIdentifier(ManualQAElement.datePicker.rawValue)
                    .accessibilityLabel("Calendar date (Asia/Seoul)")
                    .disabled(viewModel.isBusy)

                    if canRequestPhotosAccess {
                        Button("Request Photos Access", action: requestPhotosAccess)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(ManualQAElement.requestPhotosAccessButton.rawValue)
                            .disabled(viewModel.isBusy)
                    } else if canRefreshPhotosAccess {
                        Button("Refresh Access", action: refreshPhotosAccess)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(ManualQAElement.refreshPhotosAccessButton.rawValue)
                            .disabled(viewModel.isBusy)
                    }

                    if canIndex {
                        Button("Index Date", action: indexSelectedDate)
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(ManualQAElement.indexDateButton.rawValue)
                            .disabled(viewModel.isBusy || !canIndex)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(viewModel.title)
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

    private var permissionLabel: String {
        switch permissionStatus {
        case "authorized": "Full access"
        case "limited": "Limited access"
        case "denied": "Access denied"
        case "restricted": "Access restricted"
        case "not-determined": "Not requested"
        default: "Unknown"
        }
    }

    private var canRequestPhotosAccess: Bool {
        permissionStatus == "not-determined" || permissionStatus == "unknown"
    }

    private var canRefreshPhotosAccess: Bool {
        permissionStatus == "denied" || permissionStatus == "restricted"
    }

    private var canIndex: Bool {
        permissionStatus == "authorized" || permissionStatus == "limited"
    }

    private func requestPhotosAccess() {
        Task {
            await viewModel.requestPhotosAccess()
        }
    }

    private func indexSelectedDate() {
        guard !viewModel.isBusy, canIndex else { return }
        Task {
            await viewModel.indexSelectedDate()
        }
    }

    @ViewBuilder
    private var permissionGuidance: some View {
        switch permissionStatus {
        case "denied":
            refreshAccessGuidance(
                "Open System Settings, choose Privacy & Security, then Photos, and allow PhotosIndex.",
                systemImage: "gear",
                state: "denied"
            )
        case "restricted":
            refreshAccessGuidance(
                "Photos access is restricted by this Mac or account. Ask the device administrator to allow it.",
                systemImage: "lock",
                state: "restricted"
            )
        case "limited":
            Label {
                Text("Only selected Photos items can be indexed. Change the selection in Photos privacy settings if needed.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
            .accessibilityIdentifier(ManualQAElement.permissionGuidance.rawValue)
            .accessibilityValue("state=limited")
        default:
            EmptyView()
        }
    }

    private func refreshAccessGuidance(
        _ message: String,
        systemImage: String,
        state: String
    ) -> some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(ManualQAElement.permissionGuidance.rawValue)
        .accessibilityValue("state=\(state)")
    }

    private func refreshPhotosAccess() {
        Task {
            await viewModel.refreshPhotosAccess()
        }
    }

    @ViewBuilder
    private var workflowStatus: some View {
        if viewModel.isBusy {
            ProgressView(busyLabel)
                .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                .accessibilityValue("state=\(busyState)")
        } else if viewModel.lastError != nil {
            Label("PhotosIndex couldn’t complete the request. Please try again.", systemImage: "exclamationmark.circle")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.red)
                .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                .accessibilityValue("state=error")
        } else if let syncResult = viewModel.syncResult {
            if viewModel.groups.isEmpty {
                Label("No groups found for this grouping level.", systemImage: "tray")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                    .accessibilityValue("state=no-groups;level=\(viewModel.selectedLevel.rawValue);groups=0")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Indexed assets", value: "\(syncResult.assetCount)")
                    LabeledContent("Groups", value: "\(viewModel.groups.count)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(ManualQAElement.workflowState.rawValue)
                .accessibilityValue(
                    "state=indexed;level=\(viewModel.selectedLevel.rawValue);assets=\(syncResult.assetCount);groups=\(viewModel.groups.count)"
                )
            }
        } else {
            Label("No date indexed yet.", systemImage: "calendar.badge.clock")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(ManualQAElement.sidebarStatus.rawValue)
                .accessibilityValue("state=not-indexed;groups=0")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
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
            }
            .padding()

            Divider()

            groupContent
        }
        .navigationTitle("Capture groups")
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
        } else if viewModel.syncResult == nil {
            ContentUnavailableView(
                "Index a date",
                systemImage: "calendar",
                description: Text("Choose a calendar date in the sidebar, then select Index Date.")
            )
            .accessibilityIdentifier(ManualQAElement.groupListStatus.rawValue)
            .accessibilityValue("state=not-indexed;groups=0")
        } else if viewModel.groups.isEmpty {
            ContentUnavailableView(
                "No capture groups",
                systemImage: "tray",
                description: Text("No Photos items matched this date and grouping level.")
            )
            .accessibilityIdentifier(ManualQAElement.groupListStatus.rawValue)
            .accessibilityValue("state=no-groups;level=\(viewModel.selectedLevel.rawValue);groups=0")
        } else {
            List {
                ForEach(Array(viewModel.groups.enumerated()), id: \.element.id) { index, group in
                    CaptureGroupRow(
                        group: group,
                        ordinal: index + 1,
                        isSelected: viewModel.selectedGroupID == group.id
                    ) {
                        Task {
                            await viewModel.selectGroup(group.id)
                        }
                    }
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
}

private struct CaptureGroupRow: View {
    let group: CaptureGroup
    let ordinal: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    var body: some View {
        Group {
            if viewModel.isLoadingGroupDetail {
                ProgressView("Loading group details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(ManualQAElement.groupDetailStatus.rawValue)
                    .accessibilityValue("state=loading-detail")
            } else if let detail = viewModel.selectedGroupDetail {
                detailList(detail)
            } else {
                ContentUnavailableView(
                    "Select a group",
                    systemImage: "rectangle.stack",
                    description: Text("Choose an ordinal group from the middle column to see its safe metadata.")
                )
                .accessibilityIdentifier(ManualQAElement.groupDetailStatus.rawValue)
                .accessibilityValue("state=no-selection;assets=0;warnings=0")
            }
        }
        .navigationTitle(detailTitle)
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

    private func detailList(_ detail: GroupDetailPayload) -> some View {
        List {
            Section("Selected group") {
                LabeledContent(
                    "Time range",
                    value: HumanBrowserFormatting.timeRange(
                        start: detail.group.start,
                        end: detail.group.end
                    )
                )
                LabeledContent("Asset count", value: "\(detail.assets.count)")
                LabeledContent("Warning count", value: "\(detail.group.warnings.count)")
            }
            .accessibilityIdentifier(ManualQAElement.groupDetail.rawValue)
            .accessibilityValue(
                "state=loaded;level=\(detail.group.level.rawValue);assets=\(detail.assets.count);warnings=\(detail.group.warnings.count)"
            )

            Section("Assets") {
                ForEach(Array(detail.assets.enumerated()), id: \.element.id) { index, asset in
                    AssetMetadataRow(asset: asset, ordinal: index + 1)
                }
            }
            .accessibilityIdentifier(ManualQAElement.assetList.rawValue)
            .accessibilityValue("assets=\(detail.assets.count)")
        }
        .listStyle(.inset)
    }
}

private struct AssetMetadataRow: View {
    let asset: EvidenceAsset
    let ordinal: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Asset \(ordinal)")
                .font(.headline)
            LabeledContent("Media kind", value: asset.mediaKind.displayName)
            LabeledContent("Capture time", value: HumanBrowserFormatting.timestamp(asset.capturedAt))
            LabeledContent(
                "Dimensions",
                value: HumanBrowserFormatting.dimensions(
                    width: asset.pixelWidth,
                    height: asset.pixelHeight
                )
            )
            LabeledContent("Duration", value: HumanBrowserFormatting.duration(asset.durationSeconds))
            LabeledContent("Location present", value: asset.hasLocation ? "Yes" : "No")
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("\(ManualQAElement.assetRow.rawValue).\(ordinal)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(
            "ordinal=\(ordinal);kind=\(asset.mediaKind.rawValue);location=\(asset.hasLocation ? "present" : "absent")"
        )
    }

    private var accessibilityLabel: String {
        [
            "Asset \(ordinal)",
            "Media kind \(asset.mediaKind.displayName)",
            "Capture time \(HumanBrowserFormatting.timestamp(asset.capturedAt))",
            "Dimensions \(HumanBrowserFormatting.dimensions(width: asset.pixelWidth, height: asset.pixelHeight))",
            "Duration \(HumanBrowserFormatting.duration(asset.durationSeconds))",
            "Location present \(asset.hasLocation ? "Yes" : "No")",
        ].joined(separator: ". ")
    }
}

private enum HumanBrowserFormatting {
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

private extension MediaKind {
    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}
