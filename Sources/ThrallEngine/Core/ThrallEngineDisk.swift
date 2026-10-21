import Foundation

enum ThrallEngineConfigError: Error, Equatable, CustomStringConvertible {
    case missingImageFile(String)
    case invalidMACAddress(String)
    case invalidConfiguration(String)

    var description: String {
        switch self {
        case .missingImageFile(let path):
            return "The engine image is incomplete: \(path) does not exist. Run scripts/build-engine-image.sh."
        case .invalidMACAddress(let value):
            return "The saved MAC address \"\(value)\" is not valid. Delete ~/.thrall/vm/mac to regenerate it."
        case .invalidConfiguration(let reason):
            return "The VM configuration is invalid: \(reason)"
        }
    }
}

/// File preparation that runs before each boot.
enum ThrallEngineDisk {
    /// Fails if any image file is missing.
    static func checkImage(_ paths: ThrallEnginePaths, fileManager: FileManager = .default) throws {
        for file in paths.requiredImageFiles where !fileManager.fileExists(atPath: file.path) {
            throw ThrallEngineConfigError.missingImageFile(file.path)
        }
    }

    /// Creates the data disk as a sparse file, or grows it to `size`.
    ///
    /// **Never shrinks.** Truncating an ext4 image below its filesystem size
    /// destroys whatever lived past the cut, and that is the user's volumes.
    static func prepareDataDisk(at url: URL, size: UInt64, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if try handle.seekToEnd() < size {
            try handle.truncate(atOffset: size)
        }
    }

    /// Moves the previous boot's console log to `console.log.1` and returns a
    /// handle for the new one, so one bad boot is still readable after the
    /// restart that follows it.
    static func openConsoleLog(at url: URL, fileManager: FileManager = .default) throws -> FileHandle {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = url.appendingPathExtension("1")
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: previous)
            try fileManager.moveItem(at: url, to: previous)
        }
        fileManager.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }
}
