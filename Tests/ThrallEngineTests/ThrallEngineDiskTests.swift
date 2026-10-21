import Foundation
import Testing

@Suite("ThrallEngineDisk")
struct ThrallEngineDiskTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thrall-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func size(_ url: URL) throws -> UInt64 {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
    }

    @Test("the data disk is created at the requested size and grows")
    func createsAndGrows() throws {
        let disk = root.appendingPathComponent("vm/data.img")
        try ThrallEngineDisk.prepareDataDisk(at: disk, size: 1 << 20)
        #expect(try size(disk) == 1 << 20)
        try ThrallEngineDisk.prepareDataDisk(at: disk, size: 4 << 20)
        #expect(try size(disk) == 4 << 20)
    }

    /// Shrinking would cut off the end of the filesystem, which is where the
    /// user's volumes live.
    @Test("the data disk never shrinks")
    func neverShrinks() throws {
        let disk = root.appendingPathComponent("data.img")
        try ThrallEngineDisk.prepareDataDisk(at: disk, size: 4 << 20)
        try ThrallEngineDisk.prepareDataDisk(at: disk, size: 1 << 20)
        #expect(try size(disk) == 4 << 20)
    }

    @Test("a missing image file names its path")
    func missingImageFile() throws {
        let paths = ThrallEnginePaths(root: root)
        try FileManager.default.createDirectory(at: paths.imageDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.kernel.path, contents: Data())
        #expect(throws: ThrallEngineConfigError.missingImageFile(paths.initialRamdisk.path)) {
            try ThrallEngineDisk.checkImage(paths)
        }
    }

    @Test("the previous console log survives one restart")
    func consoleLogRotates() throws {
        let log = root.appendingPathComponent("logs/console.log")
        let first = try ThrallEngineDisk.openConsoleLog(at: log)
        first.write(Data("boot 1".utf8))
        try first.close()
        let second = try ThrallEngineDisk.openConsoleLog(at: log)
        try second.close()
        #expect(try String(contentsOf: log.appendingPathExtension("1"), encoding: .utf8) == "boot 1")
        #expect(try size(log) == 0)
    }

    @Test("the image directory defaults under the root and can be overridden")
    func imageDirectory() {
        #expect(ThrallEnginePaths(root: root).kernel == root.appendingPathComponent("vm/Image"))
        let built = URL(fileURLWithPath: "/repo/build/engine-image")
        let paths = ThrallEnginePaths(root: root, imageDirectory: built)
        #expect(paths.kernel == built.appendingPathComponent("Image"))
        #expect(paths.dataDisk == root.appendingPathComponent("vm/data.img"))
    }
}
