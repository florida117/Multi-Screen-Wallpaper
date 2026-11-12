// swift-tools-version:5.9
import PackageDescription

// Standalone package that compiles the app's AppKit-free sources — the geometry
// and the preset store — via symlinks into Sources/, so they can be unit-tested
// with `swift test` without depending on the Xcode app target.
// Run: `cd GeometryPackage && swift test`.
let package = Package(
    name: "WallpaperGeometry",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WallpaperGeometry"),
        .testTarget(name: "WallpaperGeometryTests", dependencies: ["WallpaperGeometry"]),
    ]
)
