# Multi Screen Wallpaper

A native Apple Silicon Mac app that spans a panoramic image across multiple displays — a modern, arm64-native replacement for [Fresco](https://apps.apple.com/gb/app/fresco/id1251572132?mt=12), which was never updated for Apple Silicon.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac (arm64)
- Xcode 15 or later (to build)

## Features

- **Panorama spanning** — load a single wide image and distribute it across two or more displays
- **Draggable split lines** — adjust exactly where the image is divided between screens with N−1 interactive split lines for N displays
- **Per-screen center crop** — each display's slice is independently cropped to that screen's exact aspect ratio from the centre, so every screen gets a clean fill regardless of resolution or size differences
- **Multi-display support** — works with any number of connected displays, including mixed resolutions and sizes
- **Drag and drop** — drag an image directly onto the canvas, or use ⌘O to open
- **Fill Screen mode** — wallpapers are applied using macOS Fill Screen scaling
- **Light & dark mode** — the canvas adapts to the system appearance

## How to Use

1. Open the app
2. Load a panoramic image via **⌘O** or drag and drop onto the canvas
3. The image is displayed with split lines dividing it between your connected displays (evenly spaced by default)
4. Drag any split line left or right to adjust where the image is divided
5. Press **Apply Wallpaper** (⌘↩) to set the wallpaper on all displays

## How It Works

### Image pipeline

All image processing runs on a background thread to keep the UI responsive:

1. The source image is loaded via `CIImage` with EXIF orientation applied
2. For each screen, the corresponding horizontal slice of the image is extracted
3. Each slice is center-cropped to that screen's exact pixel aspect ratio
4. The result is scaled to the screen's native pixel dimensions
5. The processed image is written to a PNG in the system temp directory
6. `NSWorkspace.setDesktopImageURL(_:for:options:)` applies it per display

Output files are named `<OriginalFilename>_Screen1.png`, `<OriginalFilename>_Screen2.png`, etc.

### Architecture

| File | Role |
|---|---|
| `MultiScreenWallpaperApp.swift` | App entry point, window configuration |
| `ContentView.swift` | Main SwiftUI layout — toolbar, canvas, status bar |
| `CanvasNSView.swift` | Interactive NSView canvas — image preview, draggable split lines, drag-and-drop |
| `WallpaperManager.swift` | State and logic — image loading, cropping, wallpaper application |

### Key technical decisions

- **Not sandboxed** — required for `NSWorkspace.setDesktopImageURL` to apply wallpapers reliably
- **Hardened Runtime enabled** — required for distribution
- **`CIImage` pipeline** — thread-safe, GPU-accelerated, produces correctly-oriented PNGs without manual coordinate flipping
- **`DispatchQueue.global(qos: .default)`** — matches the QoS of the window server's XPC service, avoiding priority inversion warnings
- **`CGImage.cropping(to:)`** — zero-copy crop (adjusts pixel offset only); the only real work is the final scale pass

## Building

```bash
open MultiScreenWallpaper.xcodeproj
```

Set your Development Team in **Signing & Capabilities**, then build with **⌘B**.

No third-party dependencies — only AppKit, SwiftUI, and CoreImage from the macOS SDK.
