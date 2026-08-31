import SwiftUI
import Combine
import UniformTypeIdentifiers

extension Notification.Name {
    static let openImageRequested = Notification.Name("openImageRequested")
    static let savePresetRequested = Notification.Name("savePresetRequested")
}

struct ContentView: View {
    @ObservedObject var manager: WallpaperManager
    @State private var showFilePicker = false
    @State private var showSavePreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if manager.sourceImage != nil {
                framingBar
                Divider()
            }
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button("Open Image…") { showFilePicker = true }
                .help("Open a panoramic image (⌘O)")
                .accessibilityHint("Choose a wide image to span across your displays")

            presetsMenu

            Button("Reset Splits") { manager.resetFractions() }
                .disabled(!canAdjustSplits)
                .help("Re-space the split lines to match your displays (⌘R)")
                .accessibilityLabel("Reset split lines")
                .accessibilityHint("Gives each display a share of the image proportional to its size")

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

    // MARK: Presets

    private var presetsMenu: some View {
        Menu {
            Button("Save Current…") { beginSavingPreset() }
                .disabled(manager.sourceImage == nil)

            if !manager.presets.isEmpty {
                Divider()
                Section("Load") {
                    ForEach(manager.presets) { preset in
                        Button { manager.loadPreset(preset) } label: {
                            // A preset whose image has moved is kept but marked,
                            // so it can still be renamed or deleted rather than
                            // silently vanishing.
                            Text(preset.isAvailable ? preset.name : "\(preset.name) (missing)")
                        }
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(manager.presets) { preset in
                        Button(preset.name) { manager.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Text("Presets")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save the current image, splits and framing, or load a saved one")
        .accessibilityLabel("Presets")
        .accessibilityHint("Save the current arrangement, or load a previously saved one")
    }

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

    // MARK: Framing

    private var framingBar: some View {
        HStack(spacing: 12) {
            Text("Zoom")
                .font(.caption)
                .foregroundColor(.secondary)

            Slider(value: $manager.zoom,
                   in: WallpaperManager.minZoom...WallpaperManager.maxZoom)
                .frame(width: 180)
                .accessibilityLabel("Zoom")
                .accessibilityValue(zoomLabel)
                .help("Zoom into the image (⌘+ / ⌘−)")

            Text(zoomLabel)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 46, alignment: .leading)
                .accessibilityHidden(true)   // the slider already reports this

            Button("Fit") { manager.resetFraming() }
                .disabled(!manager.isFramed)
                .help("Show the whole image again (⌘0)")
                .accessibilityHint("Resets zoom and position to show the whole image")

            Spacer()

            if manager.canPan {
                Text("Drag the image to reposition · ⌥ arrows")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)   // duplicated by the canvas help text
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var zoomLabel: String {
        "\(Int((manager.zoom * 100).rounded()))%"
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
