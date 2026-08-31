import SwiftUI

@main
struct MultiScreenWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Owned here rather than in ContentView so the menu commands can reflect the
    // same enabled/disabled state as the toolbar buttons. ⌘N is removed below, so
    // there is only ever one window and therefore one manager.
    @StateObject private var manager = WallpaperManager()

    /// Nothing to zoom, pan or save a preset from until an image is open.
    private var noImage: Bool { manager.sourceImage == nil }

    /// One nudge moves the view by this fraction of the visible area.
    private let panStep: CGFloat = 0.05

    var body: some Scene {
        WindowGroup("Multi Screen Wallpaper") {
            ContentView(manager: manager)
                .frame(minWidth: 800, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 960, height: 580)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Image…") {
                    NotificationCenter.default.post(name: .openImageRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Every action also lives in the menu bar, so nothing depends on
            // seeing or reaching the toolbar buttons.
            CommandMenu("Wallpaper") {
                Button("Apply Wallpaper") { manager.applyWallpapers() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(manager.sourceImage == nil || manager.isBusy)

                Divider()

                Button("Reset Split Lines") { manager.resetFractions() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(manager.sourceImage == nil || manager.layout.arrangement == .grid
                              || manager.isLoading)

                Divider()

                // Zoom and pan are available from the menu as well as the canvas,
                // so neither depends on a trackpad gesture or a mouse drag.
                Button("Zoom In") { manager.nudgeZoom(1.25) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(noImage || manager.zoom >= WallpaperManager.maxZoom)

                Button("Zoom Out") { manager.nudgeZoom(1 / 1.25) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(noImage || manager.zoom <= WallpaperManager.minZoom)

                Button("Fit Image") { manager.resetFraming() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(noImage || !manager.isFramed)

                Menu("Move Image") {
                    Button("Left")  { manager.nudgePan(dx: -panStep, dy: 0) }
                        .keyboardShortcut(.leftArrow, modifiers: .option)
                    Button("Right") { manager.nudgePan(dx:  panStep, dy: 0) }
                        .keyboardShortcut(.rightArrow, modifiers: .option)
                    Button("Up")    { manager.nudgePan(dx: 0, dy:  panStep) }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("Down")  { manager.nudgePan(dx: 0, dy: -panStep) }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                }
                .disabled(noImage || !manager.canPan)

                Divider()

                Toggle("Reapply on Display Change", isOn: $manager.autoReapply)
            }

            CommandMenu("Presets") {
                Button("Save Current…") {
                    NotificationCenter.default.post(name: .savePresetRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(noImage)

                if manager.presets.isEmpty {
                    Text("No saved presets")
                } else {
                    Divider()
                    ForEach(manager.presets) { preset in
                        Button(preset.isAvailable ? preset.name : "\(preset.name) (missing)") {
                            manager.loadPreset(preset)
                        }
                        .disabled(manager.isBusy)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
