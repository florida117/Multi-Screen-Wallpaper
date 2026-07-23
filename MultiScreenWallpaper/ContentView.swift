import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let openImageRequested = Notification.Name("openImageRequested")
}

struct ContentView: View {
    @StateObject private var manager = WallpaperManager()
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasView(manager: manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Wallpaper preview canvas")
            Divider()
            statusBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .openImageRequested)) { _ in
            showFilePicker = true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { manager.loadImage(from: url) }
            case .failure(let error):
                manager.statusMessage = error.localizedDescription
                manager.isError = true
            }
        }
    }

    private var canAdjustSplits: Bool {
        manager.sourceImage != nil && manager.layout.arrangement != .grid
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Open Image…") { showFilePicker = true }
                .help("Open a panoramic image (⌘O)")

            Button("Reset Splits") { manager.resetFractions() }
                .disabled(!canAdjustSplits)
                .help("Evenly re-space the split lines")

            Spacer()

            Toggle("Reapply on display change", isOn: $manager.autoReapply)
                .toggleStyle(.checkbox)
                .help("Automatically re-apply the wallpaper when displays are connected, disconnected, or rearranged")
                .accessibilityHint("When on, the wallpaper is re-applied automatically after the display arrangement changes")

            if manager.isProcessing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Applying wallpaper")
            }

            Button("Apply Wallpaper") { manager.applyWallpapers() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(manager.sourceImage == nil || manager.isProcessing)
                .help("Render and set the wallpaper on every display (⌘↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack {
            if manager.statusMessage.isEmpty {
                Text(displaySummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Label(manager.statusMessage,
                      systemImage: manager.isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(manager.isError ? .red : .secondary)
            }
            Spacer()
            if manager.sourceImage != nil {
                Text(hintText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
    }

    private var displaySummary: String {
        let count = manager.displayCount
        let noun = "\(count) display\(count == 1 ? "" : "s") detected"
        switch manager.layout.arrangement {
        case .row where count > 1:    return "\(noun) · row"
        case .column:                 return "\(noun) · column"
        case .grid:                   return "\(noun) · grid"
        default:                      return noun
        }
    }

    private var hintText: String {
        switch manager.layout.arrangement {
        case .grid:
            return "Grid layout — mapped by position · ⌘↩ to apply"
        case .column:
            return "Drag or ↑/↓ split lines to adjust · ⌘↩ to apply"
        case .row:
            return "Drag or ←/→ split lines to adjust · ⌘↩ to apply"
        }
    }
}
