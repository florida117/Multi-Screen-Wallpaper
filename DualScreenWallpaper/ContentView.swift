import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = WallpaperManager()
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CanvasView(manager: manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Dual Screen Wallpaper")
                .font(.headline)
            Spacer()
            Button("Open Image…") { showFilePicker = true }
                .keyboardShortcut("o")
            Button("Apply Wallpaper") { manager.applyWallpapers() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(manager.sourceImage == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusBar: some View {
        HStack {
            if manager.statusMessage.isEmpty {
                let count = NSScreen.screens.count
                Text("\(count) display\(count == 1 ? "" : "s") detected")
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
                Text("Drag split lines to adjust · ⌘↩ to apply")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
    }
}
