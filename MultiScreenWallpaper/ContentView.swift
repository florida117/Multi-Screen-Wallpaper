import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let openImageRequested = Notification.Name("openImageRequested")
}

struct ContentView: View {
    @ObservedObject var manager: WallpaperManager
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            // No accessibility modifiers here: the canvas builds its own AppKit
            // accessibility tree (sections and split lines), and a SwiftUI label
            // would flatten it into a single opaque element.
            CanvasView(manager: manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                manager.setStatus(error.localizedDescription, error: true)
            }
        }
    }

    private var canAdjustSplits: Bool {
        manager.sourceImage != nil && manager.layout.arrangement != .grid && !manager.isLoading
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Open Image…") { showFilePicker = true }
                .help("Open a panoramic image (⌘O)")
                .accessibilityHint("Choose a wide image to span across your displays")

            Button("Reset Splits") { manager.resetFractions() }
                .disabled(!canAdjustSplits)
                .help("Evenly re-space the split lines (⌘R)")
                .accessibilityLabel("Reset split lines")
                .accessibilityHint("Spaces the split lines evenly across the image")

            Spacer()

            Toggle("Reapply on display change", isOn: $manager.autoReapply)
                .toggleStyle(.checkbox)
                .help("Automatically re-apply the wallpaper when displays are connected, disconnected, or rearranged")
                .accessibilityHint("When on, the wallpaper is re-applied automatically after the display arrangement changes")

            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(manager.isLoading ? "Opening image" : "Applying wallpaper")
            }

            Button("Apply Wallpaper") { manager.applyWallpapers() }
                .buttonStyle(.borderedProminent)
                .disabled(manager.sourceImage == nil || manager.isBusy)
                .help("Render and set the wallpaper on every display (⌘↩)")
                .accessibilityHint("Renders each display's slice and sets it as the desktop picture")
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
                // The icon carries the same success/failure meaning as the colour,
                // so the state does not depend on distinguishing red from grey.
                Label(manager.statusMessage,
                      systemImage: manager.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
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
        // Read as one coherent sentence rather than two disconnected fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        var parts: [String] = []
        if manager.statusMessage.isEmpty {
            parts.append(displaySummary)
        } else {
            parts.append(manager.isError ? "Error. \(manager.statusMessage)" : manager.statusMessage)
        }
        if manager.sourceImage != nil { parts.append(hintText) }
        return parts.joined(separator: ". ")
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
