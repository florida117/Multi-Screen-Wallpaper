# Multi Screen Wallpaper

A native Apple Silicon Mac app that spans a panoramic image across multiple displays.

## Installation

Download the [**latest MultiScreenWallpaper.dmg**](../../releases/latest/download/MultiScreenWallpaper.dmg), open it, and drag **MultiScreenWallpaper** to your Applications folder. See all versions on the [Releases](../../releases) page.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac (arm64)

## Features

- **Panorama spanning** — load a single wide image and distribute it across one or more displays
- **Any arrangement** — horizontal rows, vertical columns, and grids are all handled: rows/columns get draggable split lines, while grids map each display to the image region matching its physical position
- **Draggable split lines** — adjust exactly where the image is divided between screens with N−1 interactive split lines for N displays
- **Keyboard & VoiceOver control** — select a split line and nudge it with the arrow keys (⇧ for larger steps); split lines are exposed to VoiceOver as adjustable sliders
- **Per-screen center crop** — each display's slice is independently cropped to that screen's exact aspect ratio from the centre, so every screen gets a clean fill regardless of resolution or size differences
- **Live crop preview** — the canvas dims the margins each screen will trim, so what you see in the preview is exactly what lands on the wall
- **Live display tracking** — connecting, disconnecting, or rotating a display updates the split lines, labels, and crop preview immediately
- **Reapply on display change** — optionally re-apply the wallpaper automatically when displays are connected, disconnected, or rearranged (macOS drops spanned wallpapers on such changes)
- **Session restore** — the last image and split positions are remembered across launches
- **Wide-gamut aware** — Display P3 sources are written at 16-bit to avoid banding
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

1. The source image is loaded via `CIImage` with EXIF orientation applied — the on-screen preview uses the same pipeline, so it matches the applied result exactly
2. The connected displays are classified as a **row**, **column**, or **grid** (`WallpaperGeometry.analyzeLayout`). Rows and columns divide the image by the split lines; grids map each display to the image region matching its physical position
3. For each screen, the corresponding slice (or grid cell) of the image is extracted
4. Each slice is center-cropped to that screen's exact pixel aspect ratio; the canvas previews this by dimming the margins that will be trimmed
5. The result is scaled to the screen's native pixel dimensions
6. The processed image is written to a PNG in the app's Application Support directory (16-bit for wide-gamut sources, 8-bit otherwise)
7. `NSWorkspace.setDesktopImageURL(_:for:options:)` applies it per display

Output files are named `<OriginalFilename>_Screen1.png`, `<OriginalFilename>_Screen2.png`, etc.
Previously generated wallpaper files are cleaned up after each successful apply.

### Architecture

| File | Role |
|---|---|
| `MultiScreenWallpaperApp.swift` | App entry point, window configuration |
| `ContentView.swift` | Main SwiftUI layout — toolbar, canvas, status bar |
| `CanvasNSView.swift` | Interactive NSView canvas — image preview, draggable split lines, keyboard/VoiceOver control, drag-and-drop |
| `WallpaperManager.swift` | State and logic — image loading, cropping, wallpaper application, persistence |
| `WallpaperGeometry.swift` | Pure, AppKit-free geometry — arrangement detection, slicing, cropping (unit-tested) |

### Key technical decisions

- **Not sandboxed** — required for `NSWorkspace.setDesktopImageURL` to apply wallpapers reliably
- **Hardened Runtime enabled** — required for distribution
- **`CIImage` pipeline** — thread-safe, GPU-accelerated, produces correctly-oriented PNGs without manual coordinate flipping
- **Background render, main-thread apply** — image processing stays off the UI thread, while the AppKit wallpaper API is called on the main thread
- **`CGImage.cropping(to:)`** — zero-copy crop (adjusts pixel offset only); the only real work is the final scale pass

## Building

```bash
open MultiScreenWallpaper.xcodeproj
```

Set your Development Team in **Signing & Capabilities**, then build with **⌘B**.

No third-party dependencies — only AppKit, SwiftUI, and CoreImage from the macOS SDK.

## Testing

The pure geometry (`WallpaperGeometry.swift`) is covered by unit tests in a
standalone Swift package that symlinks the same source file, so there is a single
source of truth:

```bash
cd GeometryPackage && swift test
```

## Distribution

The app is distributed as a notarized DMG for direct installation — no App Store required.

### Requirements

- Paid Apple Developer Program membership
- A **Developer ID Application** certificate (create in Xcode → Settings → Accounts → Manage Certificates)

### Steps

**1. Archive**

In Xcode, select **Product → Archive**. Once complete the Organizer window opens.

**2. Export**

In Organizer, select the archive and click **Distribute App → Direct Distribution**. Accept the defaults — Xcode will sign, notarize, and staple automatically. Save the exported `.app` to a convenient location (e.g. Desktop).

**3. Package as DMG**

```bash
brew install create-dmg imagemagick

# Create arrow background
magick -size 540x380 \
  gradient:"#e8e8e8-#f5f5f5" \
  -fill none -stroke "#999999" -strokewidth 3 \
  -draw "path 'M 220,190 L 320,190'" \
  -fill "#999999" -stroke none \
  -draw "polygon 320,183 335,190 320,197" \
  /tmp/dmg-background.png

# Build DMG
create-dmg \
  --volname "Multi Screen Wallpaper" \
  --background /tmp/dmg-background.png \
  --window-pos 200 120 \
  --window-size 540 380 \
  --icon-size 100 \
  --icon "MultiScreenWallpaper.app" 130 185 \
  --app-drop-link 410 185 \
  --hide-extension "MultiScreenWallpaper.app" \
  ~/Desktop/MultiScreenWallpaper.dmg \
  /path/to/MultiScreenWallpaper.app

brew uninstall create-dmg imagemagick
```

The resulting `MultiScreenWallpaper.dmg` can be shared directly (AirDrop, USB, etc.). Recipients open the DMG, drag the app to Applications, and launch — no security warnings.

### Key distribution decisions

- **Developer ID signed** — allows distribution outside the Mac App Store
- **Notarized** — passes Gatekeeper on recipients' Macs without any security prompts
- **Not sandboxed** — required for `NSWorkspace.setDesktopImageURL` to work; precludes Mac App Store distribution
