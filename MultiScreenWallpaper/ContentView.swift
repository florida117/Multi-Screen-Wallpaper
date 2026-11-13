import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let openImageRequested = Notification.Name("openImageRequested")
    static let savePresetRequested = Notification.Name("savePresetRequested")
}

/// The main window: a preset library on the left; on the right, the desk
/// preview of what each display will show, the source image with its split
/// lines beneath it, and the framing and apply controls along the bottom.
struct ContentView: View {
    @ObservedObject var manager: WallpaperManager
    @State private var showFilePicker = false
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var zoomKeyMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar(manager: manager,
                           openImage: { showFilePicker = true },
                           savePreset: beginSavingPreset)
            Divider()
            VStack(spacing: 0) {
                deskSection
                sourceSection
                Divider()
                actionBar
            }
        }
        .navigationSubtitle(displaySummary)
        .onAppear(perform: installZoomInAlias)
        .onDisappear {
            if let monitor = zoomKeyMonitor { NSEvent.removeMonitor(monitor) }
            zoomKeyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .openImageRequested)) { _ in
            showFilePicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .savePresetRequested)) { _ in
            beginSavingPreset()
        }
        .sheet(isPresented: $showSavePreset) { savePresetSheet }
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

    /// The Zoom In menu item shows ⌘+, but AppKit matches it only with Shift
    /// held, since + is Shift-= on most layouts. Accept a plain ⌘= too, as
    /// other Mac apps do, so zooming in does not need a different chord from
    /// zooming out.
    private func installZoomInAlias() {
        guard zoomKeyMonitor == nil else { return }
        zoomKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [manager] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "=",
                  manager.sourceImage != nil,
                  manager.zoom < WallpaperManager.maxZoom else { return event }
            manager.nudgeZoom(1.25)
            return nil
        }
    }

    // MARK: Desk

    private var deskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("On your desk")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(manager.sourceImage == nil
                     ? "Open an image to see it on your displays"
                     : "Laid out as arranged in Displays settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DeskPreviewView(manager: manager)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Source

    private var sourceSection: some View {
        // No spacing: the canvas's own 10pt shadow inset separates it from the header.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(manager.sourceFileName.map { "Source · \($0)" } ?? "Source")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(sourceHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Reset Splits") { manager.resetFractions() }
                    .controlSize(.small)
                    .disabled(!canAdjustSplits)
                    .help("Re-space the split lines to match your displays (⌘R)")
                    .accessibilityLabel("Reset split lines")
                    .accessibilityHint("Gives each display a share of the image proportional to its size")
            }
            // No accessibility modifiers here: the canvas builds its own AppKit
            // accessibility tree (sections and split lines), and a SwiftUI label
            // would flatten it into a single opaque element.
            // 220 high: the canvas insets the image by 10pt on each side for its
            // shadow, so the image itself still gets 200pt.
            CanvasView(manager: manager)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, -10)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }

    private var sourceHint: String {
        guard manager.sourceImage != nil else { return "Drop an image here, or open one with ⌘O" }
        switch manager.layout.arrangement {
        case .grid:
            return "Each display shows the region matching its position"
        case .row, .column:
            return manager.canPan
                ? "Drag a split to rebalance · drag the image to reposition"
                : "Drag a split to rebalance · dimmed areas are trimmed"
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            Text("Zoom")
                .accessibilityHidden(true)   // the slider carries its own label
            Slider(value: $manager.zoom,
                   in: WallpaperManager.minZoom...WallpaperManager.maxZoom)
                .frame(width: 140)
                .disabled(manager.sourceImage == nil)
                .accessibilityLabel("Zoom")
                .accessibilityValue(zoomLabel)
                .help("Zoom into the image (⌘+ / ⌘−)")
            Text(zoomLabel)
                .monospacedDigit()
                .frame(width: 42, alignment: .leading)
                .accessibilityHidden(true)
            Button("Fit") { manager.resetFraming() }
                .disabled(!manager.isFramed)
                .help("Show the whole image again (⌘0)")
                .accessibilityHint("Resets zoom and position to show the whole image")

            Toggle("Reapply on display change", isOn: $manager.autoReapply)
                .toggleStyle(.checkbox)
                .help("Automatically re-apply the wallpaper when displays are connected, disconnected, or rearranged")

            status
                .frame(maxWidth: .infinity, alignment: .trailing)

            if manager.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(manager.isLoading ? "Opening image" : "Applying wallpaper")
            }

            Button {
                manager.applyWallpapers()
            } label: {
                Text(applyTitle)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(manager.sourceImage == nil || manager.isBusy)
            .help("Render and set the wallpaper on every display (⌘↩)")
            .accessibilityHint("Renders each display's slice and sets it as the desktop picture")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var status: some View {
        if !manager.statusMessage.isEmpty {
            // The icon carries the same success/failure meaning as the colour,
            // so the state does not depend on distinguishing red from grey.
            Label(manager.statusMessage,
                  systemImage: manager.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(manager.isError ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(manager.statusMessage)
                .accessibilityLabel(manager.isError ? "Error. \(manager.statusMessage)" : manager.statusMessage)
        } else {
            Color.clear.frame(height: 1).accessibilityHidden(true)
        }
    }

    private var applyTitle: String {
        let n = max(manager.displayCount, 1)
        return "Apply to \(n) Display\(n == 1 ? "" : "s")"
    }

    private var zoomLabel: String {
        "\(Int((manager.zoom * 100).rounded()))%"
    }

    private var displaySummary: String {
        let count = manager.displayCount
        let noun = "\(count) display\(count == 1 ? "" : "s")"
        switch manager.layout.arrangement {
        case .row where count > 1:    return "\(noun) · row"
        case .column:                 return "\(noun) · column"
        case .grid:                   return "\(noun) · grid"
        default:                      return noun
        }
    }

    // MARK: Save preset

    private func beginSavingPreset() {
        guard manager.sourceImage != nil else { return }
        presetName = manager.suggestedPresetName
        showSavePreset = true
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Preset")
                .font(.headline)
            Text("Stores the current image, split positions, zoom and position. Saving over an existing name replaces it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Preset name", text: $presetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .accessibilityLabel("Preset name")
                .onSubmit(commitPreset)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showSavePreset = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commitPreset)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    private func commitPreset() {
        manager.savePreset(named: presetName)
        showSavePreset = false
    }
}
