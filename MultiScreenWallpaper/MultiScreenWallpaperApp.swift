import SwiftUI

@main
struct MultiScreenWallpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Owned here rather than in ContentView so the menu commands can reflect the
    // same enabled/disabled state as the toolbar buttons. ⌘N is removed below, so
    // there is only ever one window and therefore one manager.
    @StateObject private var manager = WallpaperManager()

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

                Toggle("Reapply on Display Change", isOn: $manager.autoReapply)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
