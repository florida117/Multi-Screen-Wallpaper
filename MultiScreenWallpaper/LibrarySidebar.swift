import SwiftUI
import ImageIO

/// The left-hand library: open an image, and the saved presets as cards with a
/// thumbnail of each one's image.
struct LibrarySidebar: View {
    @ObservedObject var manager: WallpaperManager
    let openImage: () -> Void
    let savePreset: () -> Void

    @StateObject private var thumbnails = PresetThumbnails()
    @State private var renaming: WallpaperPreset?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openImage) {
                Label("Open Image…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Open a panoramic image (⌘O)")

            Text("Presets")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)

            if manager.presets.isEmpty {
                Text("Save the current image, splits and framing to come back to them later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.presets) { preset in
                            card(for: preset)
                        }
                    }
                    .padding(2)   // room for the selection ring
                }
            }

            Spacer(minLength: 0)

            Button(action: savePreset) {
                Text("Save Current as Preset…")
                    .frame(maxWidth: .infinity)
            }
            .disabled(manager.sourceImage == nil)
            .help("Save the current image, splits and framing (⌘S)")
        }
        .padding(16)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $renaming) { preset in renameSheet(for: preset) }
    }

    // MARK: Preset card

    private func card(for preset: WallpaperPreset) -> some View {
        let isActive = preset.id == manager.activePresetID
        let isAvailable = preset.isAvailable

        return Button {
            manager.loadPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail(for: preset, isAvailable: isAvailable)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(preset.name)
                    .font(isActive ? .body.weight(.semibold) : .body)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAvailable ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isActive ? Color.accentColor : Color(nsColor: .separatorColor),
                                  style: StrokeStyle(lineWidth: isActive ? 2 : 1,
                                                     dash: isAvailable ? [] : [4, 3]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(manager.isBusy)
        .contextMenu {
            Button("Rename…") {
                renameText = preset.name
                renaming = preset
            }
            Button("Delete", role: .destructive) { manager.deletePreset(preset) }
        }
        .onAppear { thumbnails.request(path: preset.imagePath) }
        .accessibilityLabel(preset.name)
        .accessibilityValue(isActive ? "Current" : (isAvailable ? "" : "Image missing"))
        .accessibilityHint(isAvailable ? "Loads this preset's image, splits and framing" : "")
    }

    @ViewBuilder
    private func thumbnail(for preset: WallpaperPreset, isAvailable: Bool) -> some View {
        if let image = thumbnails.images[preset.imagePath] {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(nsColor: .quaternaryLabelColor)
                if !isAvailable {
                    Text("Image missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Rename

    private func renameSheet(for preset: WallpaperPreset) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Preset")
                .font(.headline)
            TextField("Preset name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { commitRename(preset) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename(preset) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private func commitRename(_ preset: WallpaperPreset) {
        manager.renamePreset(preset, to: renameText)
        renaming = nil
    }
}

/// Small thumbnails of preset images, made off the main thread with ImageIO
/// (which reads only what it needs from the file) and kept for the session.
@MainActor
final class PresetThumbnails: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var requested: Set<String> = []

    func request(path: String) {
        guard !requested.contains(path) else { return }
        requested.insert(path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let url = URL(fileURLWithPath: path) as CFURL
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
                kCGImageSourceThumbnailMaxPixelSize: 480
            ]
            guard let source = CGImageSourceCreateWithURL(url, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                // Missing or unreadable: allow a retry if the file reappears later.
                DispatchQueue.main.async { self?.requested.remove(path) }
                return
            }
            DispatchQueue.main.async { self?.images[path] = image }
        }
    }
}
