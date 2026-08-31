import CoreGraphics
import Foundation

/// A saved arrangement: which image, where it was cropped from, and how it was
/// divided between displays. Enough to reproduce an apply exactly.
///
/// The image is referenced by path rather than copied. The app is not sandboxed
/// (see MultiScreenWallpaper.entitlements), so a plain path stays readable across
/// launches — the same assumption the session restore already makes. Moving or
/// deleting the original breaks the preset, which `isAvailable` reports.
struct WallpaperPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var imagePath: String
    var splitFractions: [CGFloat]
    var zoom: CGFloat
    /// Stored as components because CGSize is not Codable.
    var offsetX: CGFloat
    var offsetY: CGFloat
    var createdAt: Date

    init(id: UUID = UUID(), name: String, imagePath: String, splitFractions: [CGFloat],
         zoom: CGFloat, offset: CGSize, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.imagePath = imagePath
        self.splitFractions = splitFractions
        self.zoom = zoom
        self.offsetX = offset.width
        self.offsetY = offset.height
        self.createdAt = createdAt
    }

    var imageURL: URL { URL(fileURLWithPath: imagePath) }
    var offset: CGSize { CGSize(width: offsetX, height: offsetY) }

    /// False once the underlying image has been moved or deleted.
    var isAvailable: Bool { FileManager.default.fileExists(atPath: imagePath) }

    /// Shown beneath the name so two presets built from different images are
    /// distinguishable even when named similarly.
    var imageName: String { imageURL.lastPathComponent }
}

/// Presets on disk, as JSON in the app's Application Support directory.
///
/// Deliberately kept beside the rendered wallpapers: `removeGeneratedWallpapers`
/// prunes only `png` and `heic`, so this file is not at risk from that sweep.
enum PresetStore {
    private static let filename = "presets.json"

    static func directory() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("MultiScreenWallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load() -> [WallpaperPreset] {
        do {
            let url = try directory().appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([WallpaperPreset].self, from: data)
        } catch {
            // A corrupt or unreadable preset file must not stop the app launching;
            // the user simply starts from an empty list.
            return []
        }
    }

    @discardableResult
    static func save(_ presets: [WallpaperPreset]) -> Error? {
        do {
            let url = try directory().appendingPathComponent(filename)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: url, options: .atomic)
            return nil
        } catch {
            return error
        }
    }
}
