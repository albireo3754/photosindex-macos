import AppKit
import AVKit
import PhotosIndexCore
import SwiftUI

@MainActor
final class MediaPreviewModel: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private var requestID = UUID()
    private var playbackObservation: NSKeyValueObservation?

    func load(
        service: any HumanMediaServing,
        assetID: String, groupID: String, expectedRunID: String,
        targetSize: CGSize, video: Bool
    ) async {
        guard !Task.isCancelled else { return }
        clear()
        let request = requestID
        isLoading = true
        defer {
            if requestID == request {
                if Task.isCancelled { clear() } else { isLoading = false }
            }
        }
        do {
            if video {
                let item = try await service.playerItem(
                    assetID: assetID, groupID: groupID, expectedRunID: expectedRunID
                )
                guard !Task.isCancelled, requestID == request else { return }
                player = AVPlayer(playerItem: item)
                playbackObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        self?.playbackFailed(for: item)
                    }
                }
            } else {
                let result = try await service.image(
                    assetID: assetID, groupID: groupID, expectedRunID: expectedRunID,
                    targetSize: targetSize
                )
                guard !Task.isCancelled, requestID == request else { return }
                image = result
            }
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            self.error = "Couldn’t load this media. It may need to download from iCloud. Check your connection and Photos access, then retry."
        }
    }

    func clear() {
        requestID = UUID()
        playbackObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        image = nil
        error = nil
        isLoading = false
    }

    func playbackFailed(for item: AVPlayerItem) {
        guard player?.currentItem === item else { return }
        clear()
        error = "Couldn’t play this video. Check your connection and Photos access, then retry."
    }
}

struct MediaSelection: Identifiable {
    let asset: EvidenceAsset
    let ordinal: Int
    let groupID: String
    let runID: String
    var id: [String] { [runID, groupID, asset.id] }
}

struct MediaBrowserView: View {
    let detail: GroupDetailPayload
    let service: any HumanMediaServing
    let open: (MediaSelection) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
            ForEach(Array(detail.assets.enumerated()), id: \.element.id) { index, asset in
                let selection = MediaSelection(
                    asset: asset, ordinal: index + 1,
                    groupID: detail.group.id, runID: detail.indexRunID
                )
                MediaThumbnail(selection: selection, service: service) { open(selection) }
            }
        }
        .accessibilityIdentifier(ManualQAElement.assetList.rawValue)
        .accessibilityValue("assets=\(detail.assets.count)")
    }
}

private struct MediaThumbnail: View {
    let selection: MediaSelection
    let service: any HumanMediaServing
    let open: () -> Void
    @StateObject private var model = MediaPreviewModel()
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let image = model.image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if model.error != nil {
                        Image(systemName: "icloud.slash")
                            .font(.largeTitle)
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 160)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    Label(selection.asset.mediaKind == .video ? "Open video" : "Open photo",
                          systemImage: selection.asset.mediaKind == .video ? "play.circle.fill" : "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(ManualQAElement.assetPreview.rawValue).\(selection.ordinal)")
            .accessibilityLabel("Open \(selection.asset.mediaKind.displayName.lowercased()) \(selection.ordinal)")
            .accessibilityValue("state=\(model.image != nil ? "loaded" : model.error != nil ? "error" : "loading")")
            VStack(alignment: .leading, spacing: 3) {
                Text("Asset \(selection.ordinal) · \(selection.asset.mediaKind.displayName)")
                    .font(.headline)
                Text(HumanBrowserFormatting.timestamp(selection.asset.capturedAt))
                if selection.asset.mediaKind == .video {
                    Text(HumanBrowserFormatting.duration(selection.asset.durationSeconds))
                }
            }
            .font(.caption)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("\(ManualQAElement.assetRow.rawValue).\(selection.ordinal)")
            .accessibilityLabel(metadataLabel)
            .accessibilityValue("ordinal=\(selection.ordinal);kind=\(selection.asset.mediaKind.rawValue);location=\(selection.asset.hasLocation ? "present" : "absent")")
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry preview") { retry += 1 }
                    .accessibilityIdentifier(ManualQAElement.mediaRetry.rawValue)
            } else if model.isLoading {
                Text("Loading preview… May download from iCloud.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: selection.id + [String(retry)]) {
            await model.load(
                service: service, assetID: selection.asset.id,
                groupID: selection.groupID, expectedRunID: selection.runID,
                targetSize: CGSize(width: 320, height: 320), video: false
            )
        }
        .onDisappear { model.clear() }
    }

    private var metadataLabel: String {
        let asset = selection.asset
        return [
            "Asset \(selection.ordinal)", "Media kind \(asset.mediaKind.displayName)",
            "Capture time \(HumanBrowserFormatting.timestamp(asset.capturedAt))",
            "Dimensions \(HumanBrowserFormatting.dimensions(width: asset.pixelWidth, height: asset.pixelHeight))",
            "Duration \(HumanBrowserFormatting.duration(asset.durationSeconds))",
            "Location present \(asset.hasLocation ? "Yes" : "No")",
        ].joined(separator: ". ")
    }
}

struct MediaViewer: View {
    let selection: MediaSelection
    let service: any HumanMediaServing
    @ObservedObject var model: MediaPreviewModel
    let close: () -> Void
    @State private var retry = 0

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Asset \(selection.ordinal) · \(selection.asset.mediaKind.displayName)")
                    .font(.headline)
                Spacer()
                Button("Close") { model.clear(); close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(ManualQAElement.mediaClose.rawValue)
            }
            HStack {
                Text(HumanBrowserFormatting.timestamp(selection.asset.capturedAt))
                Text(HumanBrowserFormatting.dimensions(width: selection.asset.pixelWidth, height: selection.asset.pixelHeight))
                if selection.asset.mediaKind == .video {
                    Text(HumanBrowserFormatting.duration(selection.asset.durationSeconds))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Group {
                if let player = model.player {
                    VideoPlayer(player: player)
                        .accessibilityIdentifier(ManualQAElement.mediaPlayer.rawValue)
                } else if let image = model.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .accessibilityLabel("Photo \(selection.ordinal)")
                } else if let error = model.error {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button("Retry") { retry += 1 }
                            .accessibilityIdentifier(ManualQAElement.mediaRetry.rawValue)
                    }
                } else {
                    ProgressView("Loading media… This may download from iCloud.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 960, minHeight: 480, idealHeight: 720)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ManualQAElement.mediaViewer.rawValue)
        .accessibilityValue("state=\(previewState)")
        .task(id: selection.id + [String(retry)]) {
            await model.load(
                service: service, assetID: selection.asset.id,
                groupID: selection.groupID, expectedRunID: selection.runID,
                targetSize: CGSize(width: 2048, height: 2048),
                video: selection.asset.mediaKind == .video
            )
        }
        .onDisappear { model.clear() }
    }

    private var previewState: String {
        if model.player != nil { return "video-ready" }
        if model.image != nil { return "photo-ready" }
        return model.error != nil ? "error" : "loading"
    }
}
