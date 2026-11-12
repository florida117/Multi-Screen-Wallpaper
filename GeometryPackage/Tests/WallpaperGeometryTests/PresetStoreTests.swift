import XCTest
import CoreGraphics
@testable import WallpaperGeometry

/// PresetStore, always against a throwaway directory so the tests never touch
/// the real presets in Application Support.
final class PresetStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var presetsFile: URL { dir.appendingPathComponent(PresetStore.filename) }

    private func sample(_ name: String) -> WallpaperPreset {
        WallpaperPreset(name: name, imagePath: "/tmp/\(name).jpg", splitFractions: [0.3, 0.7],
                        zoom: 1.5, offset: CGSize(width: 0.1, height: -0.05),
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testMissingFileLoadsEmptyWithoutSettingAnythingAside() {
        let result = PresetStore.load(in: dir)
        XCTAssertEqual(result.presets, [])
        XCTAssertNil(result.setAside)
    }

    func testSaveThenLoadRoundTrips() {
        let presets = [sample("Beach"), sample("Mountains")]
        XCTAssertNil(PresetStore.save(presets, in: dir))
        let result = PresetStore.load(in: dir)
        XCTAssertEqual(result.presets, presets)
        XCTAssertNil(result.setAside)
        XCTAssertEqual(result.presets.first?.offset, CGSize(width: 0.1, height: -0.05))
    }

    func testUnreadableFileIsSetAsideNotLost() throws {
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: presetsFile)

        let result = PresetStore.load(in: dir)
        XCTAssertEqual(result.presets, [])
        let backup = try XCTUnwrap(result.setAside)
        XCTAssertEqual(try Data(contentsOf: backup), damaged, "the original bytes must survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: presetsFile.path))
    }

    func testSavingAfterAnUnreadableLoadKeepsTheBackup() throws {
        let damaged = Data("[{\"id\": 42}]".utf8)   // valid JSON, wrong shape
        try damaged.write(to: presetsFile)

        let backup = try XCTUnwrap(PresetStore.load(in: dir).setAside)
        XCTAssertNil(PresetStore.save([sample("Fresh")], in: dir))

        XCTAssertEqual(try Data(contentsOf: backup), damaged)
        XCTAssertEqual(PresetStore.load(in: dir).presets.map(\.name), ["Fresh"])
    }
}
