import Foundation
import Darwin
import UniformTypeIdentifiers

enum DiskCleanupCandidateReason: String {
    case oldInstaller, oldLargeFile
}

enum DiskCleanupIssueReason: String {
    case invalidRoot, protectedLocation, unsupportedVolume, cloudLocation
    case permissionDenied, symbolicLink, aliasFile, packageDirectory, notRegularFile
    case tooRecent, notCandidate, changed, missing, outsideScope, cancelled, scanLimit, trashFailed
}

struct DiskCleanupError: Error {
    let reason: DiskCleanupIssueReason
}

final class DiskCleanupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

struct DiskCleanupLimits {
    var maximumEntries = 20_000
    var maximumCandidates = 500
    var maximumDepth = 20
    var maximumSeconds: TimeInterval = 8
    static let `default` = DiskCleanupLimits()
}

struct DiskCleanupProgress {
    let visitedCount: Int
    let candidateCount: Int
    let completedCount: Int
    let totalCount: Int
}

struct DiskCleanupCandidate: Identifiable {
    let id: UUID
    let url: URL
    let relativePath: String
    let sizeBytes: Int64
    let allocatedBytes: Int64?
    let modifiedAt: Date
    let reason: DiskCleanupCandidateReason
}

struct DiskCleanupIssue {
    let relativePath: String
    let reason: DiskCleanupIssueReason
}

fileprivate struct CleanupNodeIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let kind: mode_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        owner = value.st_uid
        kind = value.st_mode & S_IFMT
    }
}

fileprivate struct CleanupAncestor {
    let url: URL
    let identity: CleanupNodeIdentity
}

fileprivate struct CleanupFileIdentity: Equatable {
    let node: CleanupNodeIdentity
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) {
        node = CleanupNodeIdentity(value)
        size = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}

fileprivate struct CleanupFileRecord {
    let identity: CleanupFileIdentity
    let ancestors: [CleanupAncestor]
}

struct DiskCleanupPlan {
    let rootURL: URL
    let candidates: [DiskCleanupCandidate]
    let scannedCount: Int
    let skippedCount: Int
    let truncated: Bool
    let cancelled: Bool
    let issues: [DiskCleanupIssue]
    fileprivate let rootAncestors: [CleanupAncestor]
    fileprivate let records: [UUID: CleanupFileRecord]
}

fileprivate struct CleanupRememberedAncestor: Codable, Equatable {
    let path: String
    let volumeUUID: String
    let inode: UInt64
    let owner: UInt32
    let kind: UInt16
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

fileprivate struct CleanupRememberedRecord: Codable {
    let version: Int
    let rootPath: String
    let bookmark: Data
    let ancestors: [CleanupRememberedAncestor]
}

/// Only the user-approved folder scope survives across entries. This carries
/// its stable identity into the next scan; it never carries reviewed files,
/// selected IDs, confirmation, or permission to execute a later Trash action.
struct DiskCleanupRememberedFolder {
    let rootURL: URL
    fileprivate let record: CleanupRememberedRecord
}

enum DiskCleanupItemStatus {
    case moved, skipped, failed
}

struct DiskCleanupItemResult {
    let candidateID: UUID
    let originalURL: URL?
    let trashURL: URL?
    let status: DiskCleanupItemStatus
    let reason: DiskCleanupIssueReason?
}

struct DiskCleanupResult {
    let items: [DiskCleanupItemResult]
    let cancelled: Bool
}

/// Explicit, bounded local-folder inspection. No file contents, browser data,
/// cache trees, permissions, startup tasks, or permanent removal are touched.
enum DiskCleanup {
    private static let rememberedFolderKey = "diskCleanupRememberedFolderV1"
    private static let ageThreshold: TimeInterval = 30 * 24 * 60 * 60
    private static let largeFileBytes: Int64 = 100_000_000
    private static let resourceKeys: Set<URLResourceKey> = [
        .isHiddenKey, .isAliasFileKey, .isPackageKey, .isUbiquitousItemKey
    ]

    private static func failureReason(_ error: Error) -> DiskCleanupIssueReason {
        let error = error as NSError
        if (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) ||
            (error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)) {
            return .permissionDenied
        }
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) ||
            (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError) { return .missing }
        return .trashFailed
    }

    private static func statReason() -> DiskCleanupIssueReason {
        switch errno {
        case ENOENT, ENOTDIR: return .missing
        case ELOOP: return .symbolicLink
        case EACCES, EPERM: return .permissionDenied
        default: return .changed
        }
    }

    private static func inside(_ path: String, root: String) -> Bool {
        path.hasPrefix(root + "/")
    }

    private static func physicalURL(_ url: URL) -> URL? {
        guard let path = url.withUnsafeFileSystemRepresentation({ pointer in
            pointer.flatMap { realpath($0, nil) }
        }) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private static func hasProjectMarker(_ descriptor: Int32) -> Bool {
        for name in [".git", ".hg", ".svn"] {
            var marker = stat()
            if fstatat(descriptor, name, &marker, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        }
        return false
    }

    private static func cloudPath(_ url: URL) -> Bool {
        url.pathComponents.contains { component in
            let name = component.lowercased()
            return name == "cloudstorage" || name == "mobile documents" ||
                name == "dropbox" || name.hasPrefix("onedrive") ||
                name == "google drive" || name.hasPrefix("googledrive")
        }
    }

    private static func protectedRoot(_ url: URL) -> Bool {
        let path = url.path
        let home = physicalURL(FileManager.default.homeDirectoryForCurrentUser)?.path ?? NSHomeDirectory()
        let exact = ["/", "/Users", "/private", "/private/tmp", "/private/var", "/private/var/folders", home] +
            ["Documents", "Desktop", "Pictures", "Movies", "Music"].map { home + "/" + $0 }
        if exact.contains(path) { return true }
        let protected = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/Volumes", "/Network",
                         "/private/etc", "/private/var/db", "/private/var/root", "/private/var/vm", "/private/var/log", "/private/var/run",
                         home + "/Library", home + "/.Trash"]
        if protected.contains(where: { path == $0 || inside(path, root: $0) }) { return true }
        if path.hasPrefix("/Users/") && path != home && !inside(path, root: home) { return true }
        return false
    }

    private static func canonicalRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw DiskCleanupError(reason: .invalidRoot) }
        let input = url.standardizedFileURL
        var value = stat()
        guard lstat(input.path, &value) == 0 else { throw DiskCleanupError(reason: statReason()) }
        guard value.st_mode & S_IFMT != S_IFLNK else { throw DiskCleanupError(reason: .symbolicLink) }
        guard value.st_mode & S_IFMT == S_IFDIR else { throw DiskCleanupError(reason: .invalidRoot) }
        // macOS exposes these system aliases in temporary-directory URLs.
        // Other symbolic ancestors are not accepted as a selected scope.
        var normalized = input.path
        for (alias, target) in [("/tmp", "/private/tmp"), ("/var", "/private/var"), ("/etc", "/private/etc")] {
            if normalized == alias || inside(normalized, root: alias) {
                normalized = target + normalized.dropFirst(alias.count)
                break
            }
        }
        guard let canonical = physicalURL(input) else { throw DiskCleanupError(reason: statReason()) }
        guard normalized == canonical.path else { throw DiskCleanupError(reason: .symbolicLink) }
        guard !cloudPath(canonical) else { throw DiskCleanupError(reason: .cloudLocation) }
        guard !protectedRoot(canonical) else { throw DiskCleanupError(reason: .protectedLocation) }
        guard !canonical.pathComponents.dropFirst().contains(where: { $0.hasPrefix(".") }) else {
            throw DiskCleanupError(reason: .protectedLocation)
        }
        guard value.st_uid == getuid() else { throw DiskCleanupError(reason: .protectedLocation) }
        let resources: URLResourceValues
        do { resources = try canonical.resourceValues(forKeys: resourceKeys.union([.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey])) }
        catch { throw DiskCleanupError(reason: failureReason(error)) }
        if resources.isUbiquitousItem == true { throw DiskCleanupError(reason: .cloudLocation) }
        if resources.isAliasFile == true { throw DiskCleanupError(reason: .aliasFile) }
        if resources.isPackage == true { throw DiskCleanupError(reason: .packageDirectory) }
        guard resources.volumeIsLocal == true, resources.volumeIsInternal == true,
              resources.volumeIsReadOnly != true else { throw DiskCleanupError(reason: .unsupportedVolume) }
        return canonical
    }

    private static func ancestorChain(_ root: URL) throws -> [CleanupAncestor] {
        var path = ""
        var result: [CleanupAncestor] = []
        for component in root.pathComponents {
            path = component == "/" ? "/" : (path == "/" ? "/" + component : path + "/" + component)
            var value = stat()
            guard lstat(path, &value) == 0 else { throw DiskCleanupError(reason: statReason()) }
            guard value.st_mode & S_IFMT == S_IFDIR else { throw DiskCleanupError(reason: .symbolicLink) }
            result.append(CleanupAncestor(url: URL(fileURLWithPath: path, isDirectory: true), identity: CleanupNodeIdentity(value)))
        }
        return result
    }

    private static func verifyAncestors(_ ancestors: [CleanupAncestor]) -> DiskCleanupIssueReason? {
        for ancestor in ancestors {
            var current = stat()
            guard lstat(ancestor.url.path, &current) == 0 else { return statReason() }
            guard current.st_mode & S_IFMT == S_IFDIR else { return .changed }
            guard CleanupNodeIdentity(current) == ancestor.identity else { return .changed }
        }
        return nil
    }

    private static func verifySelectedScope(_ ancestors: [CleanupAncestor]) throws {
        for ancestor in ancestors {
            if UTType(filenameExtension: ancestor.url.pathExtension)?.conforms(to: .package) == true {
                throw DiskCleanupError(reason: .packageDirectory)
            }
            let values: URLResourceValues
            do { values = try ancestor.url.resourceValues(forKeys: [.isPackageKey, .isUbiquitousItemKey]) }
            catch { throw DiskCleanupError(reason: failureReason(error)) }
            if values.isPackage == true { throw DiskCleanupError(reason: .packageDirectory) }
            if values.isUbiquitousItem == true { throw DiskCleanupError(reason: .cloudLocation) }
            let descriptor = open(ancestor.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw DiskCleanupError(reason: statReason()) }
            let project = hasProjectMarker(descriptor)
            close(descriptor)
            if project { throw DiskCleanupError(reason: .protectedLocation) }
        }
    }

    private static func stableAncestors(_ ancestors: [CleanupAncestor]) throws -> [CleanupRememberedAncestor] {
        guard !ancestors.isEmpty, ancestors.count <= 64 else { throw DiskCleanupError(reason: .invalidRoot) }
        // Device numbers are useful for one live scan but can change on reboot.
        // The persisted identity uses each ancestor's stable volume UUID instead.
        var volumeUUIDs: [dev_t: String] = [:]
        var result: [CleanupRememberedAncestor] = []
        for ancestor in ancestors {
            var value = stat()
            guard lstat(ancestor.url.path, &value) == 0,
                  CleanupNodeIdentity(value) == ancestor.identity,
                  value.st_mode & S_IFMT == S_IFDIR else { throw DiskCleanupError(reason: .changed) }
            guard value.st_birthtimespec.tv_sec > 0,
                  (0..<1_000_000_000).contains(value.st_birthtimespec.tv_nsec) else {
                throw DiskCleanupError(reason: .unsupportedVolume)
            }
            let volumeUUID: String
            if let cached = volumeUUIDs[value.st_dev] {
                volumeUUID = cached
            } else {
                let values = try ancestor.url.resourceValues(forKeys: [.volumeUUIDStringKey])
                guard let uuid = values.volumeUUIDString.flatMap(UUID.init(uuidString:)) else {
                    throw DiskCleanupError(reason: .unsupportedVolume)
                }
                volumeUUID = uuid.uuidString
                volumeUUIDs[value.st_dev] = volumeUUID
            }
            result.append(CleanupRememberedAncestor(path: ancestor.url.path,
                volumeUUID: volumeUUID, inode: UInt64(value.st_ino), owner: value.st_uid,
                kind: value.st_mode & S_IFMT, birthSeconds: Int64(value.st_birthtimespec.tv_sec),
                birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec)))
        }
        return result
    }

    private static func validateRememberedRecord(_ record: CleanupRememberedRecord,
                                                  root: URL, ancestors: [CleanupAncestor]) throws {
        guard record.version == 1, record.rootPath == root.path,
              record.rootPath.utf8.count <= 4_096,
              record.ancestors.count == ancestors.count,
              record.ancestors.last?.path == root.path,
              !record.bookmark.isEmpty, record.bookmark.count <= 65_536 else {
            throw DiskCleanupError(reason: .changed)
        }
        guard try stableAncestors(ancestors) == record.ancestors else {
            throw DiskCleanupError(reason: .changed)
        }
    }

    static func forgetRememberedFolder(defaults: UserDefaults) {
        defaults.removeObject(forKey: rememberedFolderKey)
    }

    static func rememberFolder(from plan: DiskCleanupPlan,
                               defaults: UserDefaults) -> DiskCleanupRememberedFolder? {
        // Cancelling analysis does not revoke a previously approved folder.
        // A deliberately changed folder is forgotten explicitly by the UI.
        guard !plan.cancelled else { return nil }
        do {
            guard verifyAncestors(plan.rootAncestors) == nil else {
                throw DiskCleanupError(reason: .changed)
            }
            let root = try canonicalRoot(plan.rootURL)
            guard root.path == plan.rootURL.path else { throw DiskCleanupError(reason: .changed) }
            let ancestors = try ancestorChain(root)
            guard ancestors.count == plan.rootAncestors.count,
                  zip(ancestors, plan.rootAncestors).allSatisfy({ current, approved in
                      current.url.path == approved.url.path && current.identity == approved.identity
                  }) else { throw DiskCleanupError(reason: .changed) }
            try verifySelectedScope(ancestors)
            let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw DiskCleanupError(reason: statReason()) }
            defer { close(descriptor) }
            var value = stat()
            guard fstat(descriptor, &value) == 0,
                  CleanupNodeIdentity(value) == plan.rootAncestors.last?.identity else {
                throw DiskCleanupError(reason: .changed)
            }
            let identities = try stableAncestors(ancestors)
            // Ordinary bookmarks record a location. No security-scoped option,
            // access extension, permission request, or bookmark refresh is used.
            let bookmark = try root.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            let record = CleanupRememberedRecord(version: 1, rootPath: root.path,
                bookmark: bookmark, ancestors: identities)
            try validateRememberedRecord(record, root: root, ancestors: ancestors)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(record)
            guard data.count <= 131_072, verifyAncestors(plan.rootAncestors) == nil else {
                throw DiskCleanupError(reason: .changed)
            }
            defaults.set(data, forKey: rememberedFolderKey)
            return DiskCleanupRememberedFolder(rootURL: root, record: record)
        } catch {
            forgetRememberedFolder(defaults: defaults)
            return nil
        }
    }

    static func restoreRememberedFolder(defaults: UserDefaults) -> DiskCleanupRememberedFolder? {
        guard let stored = defaults.object(forKey: rememberedFolderKey) else { return nil }
        do {
            guard let data = stored as? Data, data.count <= 131_072 else {
                throw DiskCleanupError(reason: .invalidRoot)
            }
            let record = try PropertyListDecoder().decode(CleanupRememberedRecord.self, from: data)
            guard record.version == 1, record.rootPath.hasPrefix("/"),
                  record.rootPath.utf8.count <= 4_096,
                  !record.bookmark.isEmpty, record.bookmark.count <= 65_536,
                  !record.ancestors.isEmpty, record.ancestors.count <= 64 else {
                throw DiskCleanupError(reason: .invalidRoot)
            }
            var stale = false
            let resolved = try URL(resolvingBookmarkData: record.bookmark,
                options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw DiskCleanupError(reason: .changed) }
            let root = try canonicalRoot(resolved)
            let ancestors = try ancestorChain(root)
            try verifySelectedScope(ancestors)
            try validateRememberedRecord(record, root: root, ancestors: ancestors)
            return DiskCleanupRememberedFolder(rootURL: root, record: record)
        } catch {
            forgetRememberedFolder(defaults: defaults)
            return nil
        }
    }

    static func scan(rootURL: URL, cancellation: DiskCleanupCancellation,
                     limits: DiskCleanupLimits = .default, now: Date = Date(),
                     expectedFolder: DiskCleanupRememberedFolder? = nil,
                     progress: (DiskCleanupProgress) -> Void = { _ in }) throws -> DiskCleanupPlan {
        let root = try canonicalRoot(rootURL)
        let rootAncestors = try ancestorChain(root)
        try verifySelectedScope(rootAncestors)
        guard let rootIdentity = rootAncestors.last?.identity else { throw DiskCleanupError(reason: .invalidRoot) }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else { throw DiskCleanupError(reason: statReason()) }
        defer { close(rootDescriptor) }
        var openedRoot = stat()
        guard fstat(rootDescriptor, &openedRoot) == 0, CleanupNodeIdentity(openedRoot) == rootIdentity else {
            throw DiskCleanupError(reason: .changed)
        }
        guard !hasProjectMarker(rootDescriptor) else { throw DiskCleanupError(reason: .protectedLocation) }
        if let expectedFolder {
            try validateRememberedRecord(expectedFolder.record, root: root, ancestors: rootAncestors)
        }

        let started = ProcessInfo.processInfo.systemUptime
        var lastProgress = started
        var scanned = 0, skipped = 0
        var candidates: [DiskCleanupCandidate] = []
        var records: [UUID: CleanupFileRecord] = [:]
        var issues: [DiskCleanupIssue] = []
        var truncated = false
        let entryLimit = max(1, min(100_000, limits.maximumEntries))
        let candidateLimit = max(1, min(2_000, limits.maximumCandidates))
        let depthLimit = max(1, min(40, limits.maximumDepth))
        let secondsLimit = limits.maximumSeconds.isFinite ? max(0.001, min(30, limits.maximumSeconds)) : 8

        func issue(_ path: String, _ reason: DiskCleanupIssueReason) {
            skipped += 1
            if issues.count < 100 { issues.append(DiskCleanupIssue(relativePath: path, reason: reason)) }
        }
        func notify(force: Bool = false) {
            let time = ProcessInfo.processInfo.systemUptime
            if force || scanned % 100 == 0 || time - lastProgress >= 0.1 {
                lastProgress = time
                progress(DiskCleanupProgress(visitedCount: scanned, candidateCount: candidates.count, completedCount: 0, totalCount: 0))
            }
        }
        func shouldStop() -> Bool {
            if cancellation.isCancelled { return true }
            if scanned >= entryLimit || candidates.count >= candidateLimit ||
                ProcessInfo.processInfo.systemUptime - started >= secondsLimit {
                truncated = true
                return true
            }
            return false
        }
        func walk(_ descriptor: Int32, directory: URL, ancestors: [CleanupAncestor], depth: Int) {
            guard !shouldStop() else { return }
            let duplicate = dup(descriptor)
            guard duplicate >= 0 else { issue(directory.lastPathComponent, .permissionDenied); return }
            guard let iterator = fdopendir(duplicate) else {
                close(duplicate)
                issue(directory.lastPathComponent, .permissionDenied)
                return
            }
            defer { closedir(iterator) }
            while !shouldStop() {
                errno = 0
                guard let entry = readdir(iterator) else {
                    if errno != 0 { issue(directory.lastPathComponent, .permissionDenied) }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let name, name != ".", name != ".." else { continue }
                scanned += 1
                let url = directory.appendingPathComponent(name)
                let relativePath = String(url.path.dropFirst(root.path.count + 1))
                defer { notify() }
                if name.hasPrefix(".") { issue(relativePath, .protectedLocation); continue }
                if cloudPath(url) { issue(relativePath, .cloudLocation); continue }
                var value = stat()
                guard fstatat(descriptor, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                    issue(relativePath, statReason()); continue
                }
                let kind = value.st_mode & S_IFMT
                if kind == S_IFLNK { issue(relativePath, .symbolicLink); continue }
                guard value.st_dev == rootIdentity.device else { issue(relativePath, .unsupportedVolume); continue }
                guard value.st_uid == getuid() else { issue(relativePath, .protectedLocation); continue }
                if value.st_flags & UInt32(UF_HIDDEN | SF_DATALESS) != 0 {
                    issue(relativePath, value.st_flags & UInt32(SF_DATALESS) != 0 ? .cloudLocation : .protectedLocation); continue
                }
                if let reason = verifyAncestors(ancestors) { issue(relativePath, reason); continue }
                let resources: URLResourceValues
                do { resources = try url.resourceValues(forKeys: resourceKeys) }
                catch { issue(relativePath, failureReason(error)); continue }
                if resources.isUbiquitousItem == true { issue(relativePath, .cloudLocation); continue }
                if resources.isHidden == true { issue(relativePath, .protectedLocation); continue }
                if resources.isAliasFile == true { issue(relativePath, .aliasFile); continue }
                if kind == S_IFDIR {
                    let type = UTType(filenameExtension: url.pathExtension)
                    if resources.isPackage == true || type?.conforms(to: .package) == true {
                        issue(relativePath, .packageDirectory); continue
                    }
                    if ["Library", "System", "Applications"].contains(name) { issue(relativePath, .protectedLocation); continue }
                    if depth >= depthLimit { truncated = true; issue(relativePath, .scanLimit); continue }
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { issue(relativePath, statReason()); continue }
                    var actual = stat()
                    if hasProjectMarker(child) {
                        issue(relativePath, .protectedLocation)
                    } else if fstat(child, &actual) == 0 && CleanupNodeIdentity(actual) == CleanupNodeIdentity(value) {
                        walk(child, directory: url, ancestors: ancestors + [CleanupAncestor(url: url, identity: CleanupNodeIdentity(value))], depth: depth + 1)
                    } else { issue(relativePath, .changed) }
                    close(child)
                    continue
                }
                guard kind == S_IFREG, value.st_size >= 0 else { issue(relativePath, .notRegularFile); continue }
                let modified = Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9)
                let created = Double(value.st_birthtimespec.tv_sec) + Double(value.st_birthtimespec.tv_nsec) / 1e9
                let latest = max(modified.timeIntervalSince1970, created > 0 ? created : modified.timeIntervalSince1970)
                guard now.timeIntervalSince1970 - latest >= ageThreshold else { issue(relativePath, .tooRecent); continue }
                let reason: DiskCleanupCandidateReason
                if ["dmg", "pkg"].contains(url.pathExtension.lowercased()) { reason = .oldInstaller }
                else if value.st_size >= largeFileBytes { reason = .oldLargeFile }
                else { issue(relativePath, .notCandidate); continue }
                let id = UUID()
                let allocation = value.st_blocks.multipliedReportingOverflow(by: 512)
                candidates.append(DiskCleanupCandidate(id: id, url: url, relativePath: relativePath,
                    sizeBytes: value.st_size, allocatedBytes: value.st_blocks >= 0 && !allocation.overflow ? allocation.partialValue : nil,
                    modifiedAt: modified, reason: reason))
                records[id] = CleanupFileRecord(identity: CleanupFileIdentity(value), ancestors: ancestors)
            }
        }
        walk(rootDescriptor, directory: root, ancestors: rootAncestors, depth: 0)
        notify(force: true)
        return DiskCleanupPlan(rootURL: root, candidates: candidates.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending },
            scannedCount: scanned, skippedCount: skipped, truncated: truncated,
            cancelled: cancellation.isCancelled, issues: issues, rootAncestors: rootAncestors, records: records)
    }

    private static func validate(_ candidate: DiskCleanupCandidate, record: CleanupFileRecord,
                                 plan: DiskCleanupPlan) -> DiskCleanupIssueReason? {
        guard inside(candidate.url.path, root: plan.rootURL.path),
              candidate.url.path == plan.rootURL.appendingPathComponent(candidate.relativePath).path else { return .outsideScope }
        if let reason = verifyAncestors(record.ancestors) { return reason }
        let descriptor = open(plan.rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return statReason() }
        defer { close(descriptor) }
        var root = stat()
        guard fstat(descriptor, &root) == 0, CleanupNodeIdentity(root) == plan.rootAncestors.last?.identity else { return .changed }
        let components = candidate.relativePath.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else { return .outsideScope }
        var current = descriptor
        var ownedDescriptors: [Int32] = []
        defer { for value in ownedDescriptors.reversed() { close(value) } }
        for name in components.dropLast() {
            let child = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return statReason() }
            ownedDescriptors.append(child)
            current = child
        }
        var value = stat()
        guard fstatat(current, components.last!, &value, AT_SYMLINK_NOFOLLOW) == 0 else { return statReason() }
        guard value.st_mode & S_IFMT == S_IFREG else { return .changed }
        guard CleanupFileIdentity(value) == record.identity else { return .changed }
        guard value.st_uid == getuid(), value.st_dev == root.st_dev else { return .outsideScope }
        let protectedFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND | SF_DATALESS)
        guard value.st_flags & protectedFlags == 0 else { return .permissionDenied }
        // This final pathname ancestry check precedes the system Trash operation.
        // Uncoordinated concurrent writers can still race any pathname-based API;
        // the app deliberately skips observed changes rather than broadening scope.
        if let reason = verifyAncestors(record.ancestors) { return reason }
        do { try verifySelectedScope(record.ancestors) }
        catch let error as DiskCleanupError { return error.reason }
        catch { return .changed }
        return nil
    }

    static func execute(plan: DiskCleanupPlan, selectedIDs: Set<UUID>, cancellation: DiskCleanupCancellation,
                        progress: (DiskCleanupProgress) -> Void = { _ in },
                        trashExecutor: (URL) throws -> URL? = { url in
                            var destination: NSURL?
                            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                            return destination as URL?
                        }) -> DiskCleanupResult {
        let selected = plan.candidates.filter { selectedIDs.contains($0.id) }
        var items: [DiskCleanupItemResult] = []
        let unknown = selectedIDs.subtracting(Set(selected.map(\.id)))
        for id in unknown.sorted(by: { $0.uuidString < $1.uuidString }) {
            items.append(DiskCleanupItemResult(candidateID: id, originalURL: nil, trashURL: nil, status: .skipped, reason: .outsideScope))
        }
        for candidate in selected {
            let result: DiskCleanupItemResult
            if cancellation.isCancelled {
                result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: nil, status: .skipped, reason: .cancelled)
            } else if let record = plan.records[candidate.id] {
                if let reason = validate(candidate, record: record, plan: plan) {
                    result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: nil, status: .skipped, reason: reason)
                } else if cancellation.isCancelled {
                    result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: nil, status: .skipped, reason: .cancelled)
                } else {
                    do {
                        let destination = try trashExecutor(candidate.url)
                        result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: destination, status: .moved, reason: nil)
                    } catch {
                        result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: nil, status: .failed, reason: failureReason(error))
                    }
                }
            } else {
                result = DiskCleanupItemResult(candidateID: candidate.id, originalURL: candidate.url, trashURL: nil, status: .skipped, reason: .outsideScope)
            }
            items.append(result)
            progress(DiskCleanupProgress(visitedCount: plan.scannedCount, candidateCount: plan.candidates.count, completedCount: items.count, totalCount: selectedIDs.count))
        }
        return DiskCleanupResult(items: items, cancelled: cancellation.isCancelled)
    }
}
