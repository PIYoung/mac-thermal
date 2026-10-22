import Foundation
import Darwin

enum FanRootFiles {
    static let folder = "/Library/Application Support/Mac Thermal/FanControl"
    static let config = folder + "/config.json"
    static let recovery = folder + "/lease.json"
    static let maintenance = folder + "/maintenance"

    static func verifyParents(_ path: String) throws {
        var current = ""
        for component in URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents where component != "/" {
            current += "/" + component
            var info = stat()
            guard lstat(current, &info) == 0, info.st_uid == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR, info.st_mode & 0o022 == 0 else { throw CocoaError(.fileReadNoPermission) }
        }
    }
    static func read(_ path: String, missingOK: Bool = false) throws -> Data? {
        try verifyParents(path)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { if missingOK && errno == ENOENT { return nil }; throw CocoaError(.fileReadNoPermission) }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= 16_384 else { throw CocoaError(.fileReadNoPermission) }
        var result = Data(count: Int(info.st_size))
        let ok = result.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            var extra: UInt8 = 0
            return Darwin.read(fd, &extra, 1) == 0
        }
        guard ok else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    static func syncFolder() throws {
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class FanRootRecoveryStore: FanRecoveryStore {
    func load() throws -> FanRecoveryRecord? {
        guard let data = try FanRootFiles.read(FanRootFiles.recovery, missingOK: true) else { return nil }
        return try JSONDecoder().decode(FanRecoveryRecord.self, from: data)
    }
    func save(_ record: FanRecoveryRecord) throws {
        try FanRootFiles.verifyParents(FanRootFiles.recovery)
        let data = try JSONEncoder().encode(record)
        let temporary = FanRootFiles.folder + "/.lease-" + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = Darwin.close(fd); _ = unlink(temporary) }
        guard fchown(fd, 0, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        guard written, rename(temporary, FanRootFiles.recovery) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try FanRootFiles.syncFolder()
    }
    func clear() throws {
        try FanRootFiles.verifyParents(FanRootFiles.recovery)
        guard unlink(FanRootFiles.recovery) == 0 || errno == ENOENT else { throw CocoaError(.fileWriteNoPermission) }
        try FanRootFiles.syncFolder()
    }
}
