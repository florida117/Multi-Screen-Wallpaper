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

    /// Named in the message shown when the image is missing, so the user knows
    /// which file to put back.
    var imageName: String { imageURL.lastPathComponent }
}

/// The app's own folder in Application Support, created on first use. Holds the
/// preset file and the rendered wallpapers.
enum AppSupport {
    static func directory() throws -> URL {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("MultiScreenWallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Presets on disk, as JSON in the app's Application Support directory.
///
/// Safe from the rendered-wallpaper pruning in `WallpaperManager`, which removes
/// only apply folders under `Rendered/` and loose `png`/`heic` files.
enum PresetStore {
    static let filename = "presets.json"

    /// Saved presets, plus where an unreadable file was moved to, if there was one.
    struct LoadResult {
        var presets: [WallpaperPreset]
        var setAside: URL?
    }

    static func load() -> LoadResult {
        guard let dir = try? AppSupport.directory() else { return LoadResult(presets: []) }
        return load(in: dir)
    }

    /// Read the presets in `directory`.
    ///
    /// A file that exists but cannot be decoded (damaged, or written by a newer
    /// version) must not stop the app launching, so the user starts from an empty
    /// list. It is renamed out of the way first: otherwise the next save would
    /// overwrite it and the presets would be lost for good.
    static func load(in directory: URL) -> LoadResult {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return LoadResult(presets: []) }
        do {
            let data = try Data(contentsOf: url)
            return LoadResult(presets: try JSONDecoder().decode([WallpaperPreset].self, from: data))
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directory.appendingPathComponent("presets.unreadable-\(stamp).json")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                return LoadResult(presets: [], setAside: backup)
            } catch {
                return LoadResult(presets: [])
            }
        }
    }

    @discardableResult
    static func save(_ presets: [WallpaperPreset]) -> Error? {
        do {
            return save(presets, in: try AppSupport.directory())
        } catch {
            return error
        }
    }

    @discardableResult
    static func save(_ presets: [WallpaperPreset], in directory: URL) -> Error? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(presets).write(to: directory.appendingPathComponent(filename), options: .atomic)
            return nil
        } catch {
            return error
        }
    }
}
