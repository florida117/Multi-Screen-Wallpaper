# Multi Screen Wallpaper

A native Apple Silicon Mac app that spans a panoramic image across multiple displays.

## Installation

Download the [**latest MultiScreenWallpaper.dmg**](../../releases/latest/download/MultiScreenWallpaper.dmg) — currently **v1.5** — open it, and drag **MultiScreenWallpaper** to your Applications folder. See all versions on the [Releases](../../releases) page.

The download is Developer ID signed, notarized and stapled, so it opens without security prompts.

## What's new in 1.5

- **Desk preview** — the main window shows every display where it sits in System Settings › Displays, each showing exactly the part of the image an apply will give it, drawn with the device's own artwork when macOS has it (Studio Display, Pro Display XDR, the Mac's built-in panel)
- **Preset library** — presets appear as thumbnail cards in a sidebar, with rename and delete
- **Staggered displays count as a row** — a laptop sitting below or beside its external displays gets split lines instead of grid mapping
- **Grid crops keep one scale** — every display in a grid samples the image at the same rate, so features crossing a seam stay continuous
- **Wallpaper refreshes reliably** — each apply gets fresh files, so re-applying after moving a split always takes effect, and other Spaces keep their wallpaper
- **Auto-reapply survives a relaunch** — and only ever re-applies the image that is actually on the wall, never one you have opened but not applied
- **Cleaner seams and more formats** — no faint line at the join between displays, and greyscale and CMYK images now apply correctly
- **⌘= zooms in** as well as ⌘+

See the [v1.5 release notes](../../releases/tag/v1.5) for the full list, or the [v1.4 notes](../../releases/tag/v1.4) for proportional splits, arrangement-aware cropping, zoom and presets.

## Requirements

- macOS 13 Ventura or later
- Apple Silicon Mac (arm64)

## Features

- **Panorama spanning** — load a single wide image and distribute it across one or more displays
- **Any arrangement** — horizontal rows (including staggered ones, such as a laptop below its monitors), vertical columns, and grids are all handled: rows/columns get draggable split lines, while grids map each display to the image region matching its physical position
- **Desk preview** — see each display where it physically sits, showing exactly what an apply will put on it
- **Draggable split lines** — adjust exactly where the image is divided between screens with N−1 interactive split lines for N displays; they start out proportional to each display's size, so a wide screen beside a narrow one gets a correspondingly wider slice and the image stays continuous across the seam
- **Zoom and reposition** — zoom into the image and drag it to choose exactly which part gets spanned, instead of always taking the centre. Pinch or use ⌘+ / ⌘− and ⌘0, drag the image or nudge it with ⌥ arrows. Panning is bounded so every display always shows real image, never blank margin
- **Presets** — save an image together with its split positions, zoom and position, and reload it later from the sidebar or the Presets menu (⌘S to save)
- **Keyboard & VoiceOver control** — every action has a menu command and shortcut; split lines are exposed to VoiceOver as adjustable sliders and each display's slice as a described section, so grid layouts are navigable too
- **Accessibility preferences** — Increase Contrast, Reduce Transparency and the system text size all change how the canvas draws; status changes and display reconfigurations are announced to VoiceOver
- **Follows your macOS display arrangement** — each display's slice is cropped to that screen's exact aspect ratio and positioned to match where the display physically sits in System Settings › Displays › Arrange. Mount one monitor higher than its neighbour and the image steps up with it, so a horizon crossing the bezel stays level. Displays that sit level with each other crop from the centre, exactly as before
- **Live crop preview** — the canvas dims the margins each screen will trim, so what you see in the preview is exactly what lands on the wall
- **Live display tracking** — connecting, disconnecting, or rotating a display updates the split lines, labels, and crop preview immediately
- **Reapply on display change** — optionally re-apply the wallpaper automatically when displays are connected, disconnected, or rearranged (macOS drops spanned wallpapers on such changes). This works across relaunches while the app is running, and only re-applies the image that is currently set
- **Session restore** — the last image, split positions, zoom and position are remembered across launches
- **Wide-gamut aware** — Display P3 sources are written at 16-bit to avoid banding
- **Multi-display support** — works with any number of connected displays, including mixed resolutions and sizes
- **Drag and drop** — drag an image directly onto the canvas, or use ⌘O to open
- **Fill Screen mode** — wallpapers are applied using macOS Fill Screen scaling
- **Light & dark mode** — the canvas adapts to the system appearance

## How to Use

1. Open the app
2. Load a panoramic image via **⌘O**, the **Open Image…** button, or drag and drop onto the source canvas
3. The desk preview at the top shows what each display will get; the source canvas below shows the image with split lines dividing it between your displays. Each display starts with a share proportional to its size, so the image stays at one scale across the seams
4. Drag any split line to adjust where the image is divided, and zoom (pinch, ⌘+ / ⌘−) and drag the image to choose which part is spanned. Dimmed areas are trimmed to fit each display's shape
5. Press **Apply to N Displays** (⌘↩) to set the wallpaper on every display
6. Optionally save the setup as a preset (⌘S) to come back to it later

### Keyboard

| Shortcut | Action |
|---|---|
| ⌘O | Open an image |
| ⌘↩ | Apply the wallpaper to every display |
| ⌘S | Save the current setup as a preset |
| ⌘R | Reset the split lines to proportional spacing |
| ⌘+ or ⌘= / ⌘− | Zoom in / out |
| ⌘0 | Fit the whole image again |
| ⌥ + arrows | Move the zoomed image |
| ←/→ or ↑/↓ | Move the selected split line (⇧ for larger steps) |
| Cross-axis arrows | Select the previous / next split line |
| Home / End | Move the selected split line to its limit |
| ⎋ | Clear the split line selection |
| ⇥ | Move focus out of the canvas |

Under VoiceOver, each split line is a slider adjustable with Control-Option-arrow,
and each display's slice reports which part of the image it shows and how much is
trimmed to fit.

## How It Works

### Image pipeline

All image processing runs on a background thread to keep the UI responsive:

1. The source image is loaded via `CIImage` with EXIF orientation applied — the on-screen preview uses the same pipeline, so it matches the applied result exactly
2. The connected displays are classified as a **row**, **column**, or **grid** (`WallpaperGeometry.analyzeLayout`). Rows and columns divide the image by the split lines; grids map each display to the image region matching its physical position
3. Zoom and pan pick the visible part of the image, which is then divided into one slice (or grid cell) per display
4. Each slice is cropped to that screen's exact pixel aspect ratio, positioned to match where the display sits in the arrangement (`WallpaperGeometry.arrangedCrop`), so a display mounted higher shows a higher band of the image. Displays that sit level crop from the centre
5. The result is scaled to the screen's native pixel dimensions
6. The processed image is written to a PNG in the app's Application Support directory (16-bit for wide-gamut sources, 8-bit otherwise)
7. `NSWorkspace.setDesktopImageURL(_:for:options:)` applies it per display

Steps 2–4 are a single function, `WallpaperGeometry.displayCrops`, which the desk preview calls too, so the preview cannot disagree with the result.

Each apply writes to its own folder, `Rendered/<timestamp>/<OriginalFilename>_Screen1.png` and so on, because the wallpaper agent caches by URL and can ignore a re-apply to a path it already shows. The five most recent sets are kept: `setDesktopImageURL` changes only the current Space, so other Spaces may still point at an earlier set.

### Architecture

| File | Role |
|---|---|
| `MultiScreenWallpaperApp.swift` | App entry point, window, menu bar commands and shortcuts |
| `ContentView.swift` | Main window layout — sidebar, desk preview, source canvas, action bar, save-preset sheet |
| `LibrarySidebar.swift` | Open button and preset cards with thumbnails, rename and delete |
| `DeskPreviewView.swift` | "On your desk" preview — each display drawn where it sits, with device artwork when macOS has it |
| `CanvasNSView.swift` | Interactive NSView canvas — image preview, draggable split lines, pinch/pan, keyboard/VoiceOver control, drag-and-drop |
| `WallpaperManager.swift` | State and logic (main actor) — image loading, framing, display tracking, rendering, applying, persistence |
| `WallpaperPreset.swift` | Preset model and its JSON store in Application Support (unit-tested) |
| `WallpaperGeometry.swift` | Pure, AppKit-free geometry — arrangement detection, slicing, cropping (unit-tested) |
| `Accessibility.swift` | System accessibility preferences, VoiceOver announcements, preferred-size fonts |

### Key technical decisions

- **Not sandboxed** — required for `NSWorkspace.setDesktopImageURL` to apply wallpapers reliably
- **Hardened Runtime enabled** — required for distribution
- **`CIImage` pipeline** — thread-safe, GPU-accelerated, produces correctly-oriented PNGs without manual coordinate flipping
- **Background render, main-thread apply** — image processing stays off the UI thread, while the AppKit wallpaper API is called on the main thread
- **`CGImage.cropping(to:)`** — zero-copy crop (adjusts pixel offset only); the only real work is the final scale pass
- **Image loading off the main thread** — opening a file can block (a cloud-backed file has to be materialised, and an unsandboxed app hitting a protected folder waits on the system permission prompt), so neither session restore nor an explicit open ever stalls the UI
- **One apply at a time** — the prune after each apply would race a concurrent one, so applies are coalesced rather than run concurrently; display-change bursts are debounced so a single apply runs against the settled arrangement
- **Main-actor state** — `WallpaperManager` is `@MainActor`; decoding and rendering run in `nonisolated static` helpers that touch none of its state
- **Cached preview raster** — the preview is drawn from a flat bitmap regenerated only when the image, canvas size, or backing scale changes, so dragging a split line does not re-render the full-resolution image through Core Image on every frame

## Building

```bash
open MultiScreenWallpaper.xcodeproj
```

Set your Development Team in **Signing & Capabilities**, then build with **⌘B**.

No third-party dependencies — only AppKit, SwiftUI, and CoreImage from the macOS SDK.

## Testing

The AppKit-free code — the geometry (`WallpaperGeometry.swift`) and the preset
store (`WallpaperPreset.swift`) — is covered by unit tests in a standalone Swift
package that symlinks the same source files, so there is a single source of truth:

```bash
cd GeometryPackage && swift test
```

GitHub Actions runs these tests and an unsigned build of the app on every push to
`main` and every pull request (`.github/workflows/ci.yml`).

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

Notarize and staple the DMG itself as well (Xcode only notarizes the app), then attach it to a GitHub release rather than committing it — `*.dmg` is ignored by git.

The resulting `MultiScreenWallpaper.dmg` can be shared directly (AirDrop, USB, etc.). Recipients open the DMG, drag the app to Applications, and launch — no security warnings.

### Key distribution decisions

- **Developer ID signed** — allows distribution outside the Mac App Store
- **Notarized** — passes Gatekeeper on recipients' Macs without any security prompts
- **Not sandboxed** — required for `NSWorkspace.setDesktopImageURL` to work; precludes Mac App Store distribution

## License

[MIT](LICENSE) © Kurtis Bell
