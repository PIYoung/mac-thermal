import Foundation
import Darwin

private struct Fixture {
    let base: URL
    let root: URL
    let trash: URL
    let outside: URL
    let now = Date()
    let fm = FileManager.default

    init() throws {
        base = URL(fileURLWithPath: "/private/tmp/MacThermalCleanupProbe-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Selected", isDirectory: true)
        trash = base.appendingPathComponent("FixtureTrash", isDirectory: true)
        outside = base.appendingPathComponent("Outside", isDirectory: true)
        for folder in [root, trash, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    func clean() { try? fm.removeItem(at: base) }

    @discardableResult
    func file(_ path: String, in folder: URL? = nil, bytes: UInt64 = 8,
              modifiedDays: Double = 45, createdDays: Double = 45) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        precondition(fm.createFile(atPath: url.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-modifiedDays * 86_400)], ofItemAtPath: url.path)
        try fm.setAttributes([.creationDate: now.addingTimeInterval(-createdDays * 86_400)], ofItemAtPath: url.path)
        return url
    }

    func scan(_ selected: URL? = nil, limits: DiskCleanupLimits = .default,
              cancellation: DiskCleanupCancellation = DiskCleanupCancellation()) throws -> DiskCleanupPlan {
        try DiskCleanup.scan(rootURL: selected ?? root, cancellation: cancellation, limits: limits, now: now)
    }

    func move(_ source: URL) throws -> URL? {
        let destination = trash.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try fm.moveItem(at: source, to: destination)
        return destination
    }
}

@main
struct DiskCleanupProbe {
    static func main() throws {
        try homeScanBoundaries()
        try candidatesAndTraversal()
        try identityAndScope()
        try selectionCancellationAndFailure()
        try limitsAndInvalidRoots()
        try rememberedFolderRoundtrip()
        try rememberedFolderChangedScopes()
        print("Disk cleanup fixtures passed: metadata candidates; recent/hidden/package/cloud/project exclusions; no symlink traversal; identity/parent/marker changes; exact subset; cancellation; partial failure; bounded scan and no-op. All Trash actions were injected moves inside owned temporary fixtures.")
    }

    private static func homeScanBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let expected = ["Downloads/old.dmg", "Documents/archive.bin", "Desktop/old.pkg", "Pictures/raw.bin", "Movies/video.bin", "Music/audio.bin", "Other/old.dmg"]
        for path in expected { try fixture.file(path, bytes: path.hasSuffix(".bin") ? 120_000_000 : 8) }
        for path in ["Library/private.dmg", "System/private.dmg", "Applications/private.dmg", ".ssh/private.dmg", ".vscode/extensions/private.dmg", ".Trash/private.dmg", "CloudStorage/private.dmg", "OneDrive/private.dmg", "Photos.photoslibrary/private.dmg", "node_modules/private.dmg", "Pods/private.dmg", "DerivedData/private.dmg"] {
            try fixture.file(path)
        }
        for marker in [".git", "package.json", "Cargo.toml", "build.gradle", "Package.swift"] {
            let name = marker.replacingOccurrences(of: ".", with: "_")
            try fixture.file("Project-" + name + "/" + marker)
            try fixture.file("Project-" + name + "/asset.dmg")
        }
        let outside = try fixture.file("outside.dmg", in: fixture.outside)
        try fixture.fm.createSymbolicLink(at: fixture.root.appendingPathComponent("Linked"), withDestinationURL: fixture.outside)
        let plan = try DiskCleanup.scanHomeFixture(rootURL: fixture.root, now: fixture.now)
        precondition(plan.isAutomaticHome)
        precondition(Set(plan.candidates.map(\.relativePath)) == Set(expected))
        precondition(!plan.truncated && !plan.cancelled)
        let suite = "local.mac-thermal.home-scope." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(DiskCleanup.rememberFolder(from: plan, defaults: defaults) == nil && defaults.dictionaryRepresentation()["diskCleanupRememberedFolderV1"] == nil,
            "Home plans must not become selected-folder bookmarks")
        let chosen = plan.candidates.first { $0.relativePath == "Desktop/old.pkg" }!
        var moved: [URL] = []
        let result = DiskCleanup.execute(plan: plan, selectedIDs: [chosen.id], cancellation: DiskCleanupCancellation(), trashExecutor: {
            moved.append($0); return try fixture.move($0)
        })
        precondition(moved == [chosen.url] && result.items.count == 1 && result.items[0].status == .moved)
        precondition(fixture.fm.fileExists(atPath: outside.path))
        for candidate in plan.candidates where candidate.id != chosen.id { precondition(fixture.fm.fileExists(atPath: candidate.url.path)) }
        let limited = try DiskCleanup.scanHomeFixture(rootURL: fixture.root,
            limits: DiskCleanupLimits(maximumEntries: 1, maximumCandidates: 500, maximumDepth: 20, maximumSeconds: 8), now: fixture.now)
        precondition(limited.truncated && limited.scannedCount == 1)
        let cancellation = DiskCleanupCancellation()
        let stopped = try DiskCleanup.scanHomeFixture(rootURL: fixture.root, cancellation: cancellation, now: fixture.now) { _ in cancellation.cancel() }
        precondition(stopped.cancelled)
        let again = try DiskCleanup.scanHomeFixture(rootURL: fixture.root, now: fixture.now)
        try fixture.file("Documents/.git")
        let document = again.candidates.first { $0.relativePath == "Documents/archive.bin" }!
        var calls = 0
        let changed = DiskCleanup.execute(plan: again, selectedIDs: [document.id], cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && changed.items.first?.reason == .protectedLocation)
        // Replace the root after review: even an identical pathname must not authorize a move.
        try fixture.fm.moveItem(at: fixture.root, to: fixture.base.appendingPathComponent("OldHome"))
        try fixture.fm.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try fixture.file("Downloads/old.dmg")
        let stale = DiskCleanup.execute(plan: again, selectedIDs: Set(again.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && stale.items.allSatisfy { $0.status == .skipped })
        print("Automatic home scan passed: personal-folder coverage, developer/cloud/hidden/package exclusions, no symlink traversal, exact selection, root/project revalidation, bounded cancellation and no bookmark widening; owned synthetic home only")
    }

    private static func candidatesAndTraversal() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.file("old.dmg")
        try fixture.file("sub/old.pkg")
        try fixture.file("large.bin", bytes: 100_000_000)
        try fixture.file("recent.dmg", modifiedDays: 2, createdDays: 2)
        try fixture.file("new-copy.dmg", modifiedDays: 45, createdDays: 1)
        try fixture.file("small.txt")
        try fixture.file(".hidden.dmg")
        try fixture.file("Ignore.app/Contents/inside.dmg")
        try fixture.file("CloudStorage/inside.dmg")
        try fixture.file("Library/inside.dmg")
        try fixture.file("Project/.git")
        try fixture.file("Project/asset.bin", bytes: 100_000_000)
        let outside = try fixture.file("outside.dmg", in: fixture.outside)
        try fixture.fm.createSymbolicLink(at: fixture.root.appendingPathComponent("linked-file.dmg"), withDestinationURL: outside)
        try fixture.fm.createSymbolicLink(at: fixture.root.appendingPathComponent("linked-folder"), withDestinationURL: fixture.outside)
        let plan = try fixture.scan()
        if Set(plan.candidates.map(\.relativePath)) != ["old.dmg", "sub/old.pkg", "large.bin"] {
            FileHandle.standardError.write(Data("Fixture candidates=\(plan.candidates.map(\.relativePath)), issues=\(plan.issues.map { $0.relativePath + ":" + $0.reason.rawValue })\n".utf8))
        }
        precondition(Set(plan.candidates.map(\.relativePath)) == ["old.dmg", "sub/old.pkg", "large.bin"])
        precondition(plan.candidates.allSatisfy { $0.sizeBytes >= 0 && $0.url.path.hasPrefix(plan.rootURL.path + "/") })
        precondition(plan.candidates.first(where: { $0.relativePath == "large.bin" })?.reason == .oldLargeFile)
        precondition(plan.candidates.first(where: { $0.relativePath == "old.dmg" })?.reason == .oldInstaller)
        precondition(plan.issues.contains { $0.reason == .symbolicLink })
        precondition(plan.issues.contains { $0.reason == .packageDirectory })
        precondition(plan.issues.contains { $0.reason == .cloudLocation })
        precondition(plan.issues.contains { $0.reason == .protectedLocation })
        precondition(!plan.truncated && !plan.cancelled)
        precondition(fixture.fm.fileExists(atPath: outside.path))
        // Selecting a package/project subfolder must not bypass its ancestor.
        for (folder, expected) in [(fixture.root.appendingPathComponent("Ignore.app/Contents"), DiskCleanupIssueReason.packageDirectory),
                                   (fixture.root.appendingPathComponent("Project"), .protectedLocation)] {
            do { _ = try fixture.scan(folder); preconditionFailure("Protected scope accepted") }
            catch let error as DiskCleanupError { precondition(error.reason == expected) }
        }
        try fixture.fm.createDirectory(at: fixture.root.appendingPathComponent("Project/nested"), withIntermediateDirectories: true)
        do { _ = try fixture.scan(fixture.root.appendingPathComponent("Project/nested")); preconditionFailure("Project ancestor accepted") }
        catch let error as DiskCleanupError { precondition(error.reason == .protectedLocation) }
    }

    private static func identityAndScope() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = try fixture.file("changed.dmg")
        var plan = try fixture.scan()
        try fixture.fm.setAttributes([.modificationDate: fixture.now], ofItemAtPath: original.path)
        var calls = 0
        var result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.first?.reason == .changed)

        try fixture.fm.removeItem(at: original)
        let swapped = try fixture.file("same-metadata.dmg")
        plan = try fixture.scan()
        // A replacement can preserve size and timestamps. Inode/ctime must
        // still prevent moving the file that the user never reviewed.
        try fixture.fm.moveItem(at: swapped, to: fixture.outside.appendingPathComponent("kept-original.dmg"))
        try fixture.file("same-metadata.dmg")
        result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.first?.reason == .changed)

        try fixture.fm.removeItem(at: fixture.root.appendingPathComponent("same-metadata.dmg"))
        try fixture.file("parent/child.dmg")
        plan = try fixture.scan()
        try fixture.fm.moveItem(at: fixture.root.appendingPathComponent("parent"), to: fixture.outside.appendingPathComponent("original-parent"))
        try fixture.file("child.dmg", in: fixture.outside)
        try fixture.fm.createSymbolicLink(at: fixture.root.appendingPathComponent("parent"), withDestinationURL: fixture.outside)
        result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.allSatisfy { $0.status == .skipped })
        precondition(fixture.fm.fileExists(atPath: fixture.outside.appendingPathComponent("child.dmg").path))

        try fixture.fm.removeItem(at: fixture.root.appendingPathComponent("parent"))
        try fixture.file("new-project/file.dmg")
        plan = try fixture.scan()
        try fixture.file("new-project/.git")
        result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.first?.reason == .protectedLocation)

        let unrelated = UUID()
        result = DiskCleanup.execute(plan: plan, selectedIDs: [unrelated], cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.count == 1 && result.items[0].reason == .outsideScope)
    }

    private static func selectionCancellationAndFailure() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for name in ["a.dmg", "b.dmg", "c.dmg"] { try fixture.file(name) }
        var plan = try fixture.scan()
        let selected = plan.candidates.first { $0.relativePath == "b.dmg" }!
        var result = DiskCleanup.execute(plan: plan, selectedIDs: [selected.id], cancellation: DiskCleanupCancellation(), trashExecutor: fixture.move)
        precondition(result.items.count == 1 && result.items[0].status == .moved)
        precondition(result.items[0].trashURL != nil && !fixture.fm.fileExists(atPath: selected.url.path))
        precondition(fixture.fm.fileExists(atPath: fixture.root.appendingPathComponent("a.dmg").path))
        precondition(fixture.fm.fileExists(atPath: fixture.root.appendingPathComponent("c.dmg").path))

        plan = try fixture.scan()
        let cancellation = DiskCleanupCancellation()
        var calls = 0
        result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: cancellation, trashExecutor: { url in
            calls += 1
            let destination = try fixture.move(url)
            cancellation.cancel()
            return destination
        })
        precondition(calls == 1 && result.cancelled)
        precondition(result.items.filter { $0.status == .moved }.count == 1)
        precondition(result.items.filter { $0.reason == .cancelled }.count == 1)

        for name in ["failure.dmg", "success.dmg"] { try fixture.file(name) }
        plan = try fixture.scan()
        result = DiskCleanup.execute(plan: plan, selectedIDs: Set(plan.candidates.map(\.id)), cancellation: DiskCleanupCancellation(), trashExecutor: { url in
            if url.lastPathComponent == "failure.dmg" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            return try fixture.move(url)
        })
        precondition(result.items.contains { $0.status == .failed && $0.reason == .permissionDenied })
        precondition(result.items.contains { $0.status == .moved })
        precondition(fixture.fm.fileExists(atPath: fixture.root.appendingPathComponent("failure.dmg").path))

        calls = 0
        result = DiskCleanup.execute(plan: plan, selectedIDs: [], cancellation: DiskCleanupCancellation(), trashExecutor: { _ in calls += 1; return nil })
        precondition(calls == 0 && result.items.isEmpty && !result.cancelled)
    }

    private static func limitsAndInvalidRoots() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for index in 0..<12 { try fixture.file("\(index).dmg") }
        let limited = try fixture.scan(limits: DiskCleanupLimits(maximumEntries: 2, maximumCandidates: 500, maximumDepth: 20, maximumSeconds: 8))
        precondition(limited.truncated && limited.scannedCount <= 2 && limited.candidates.count <= 2)
        let candidates = try fixture.scan(limits: DiskCleanupLimits(maximumEntries: 20_000, maximumCandidates: 2, maximumDepth: 20, maximumSeconds: 8))
        precondition(candidates.truncated && candidates.candidates.count == 2)
        try fixture.file("one/two/hidden.dmg")
        let depth = try fixture.scan(limits: DiskCleanupLimits(maximumEntries: 20_000, maximumCandidates: 500, maximumDepth: 1, maximumSeconds: 8))
        precondition(depth.truncated && !depth.candidates.contains { $0.relativePath == "one/two/hidden.dmg" })
        let cancellation = DiskCleanupCancellation()
        cancellation.cancel()
        let cancelled = try fixture.scan(cancellation: cancellation)
        precondition(cancelled.cancelled && cancelled.scannedCount == 0 && cancelled.candidates.isEmpty)
        for url in [URL(fileURLWithPath: "/"), FileManager.default.homeDirectoryForCurrentUser] {
            do { _ = try fixture.scan(url); preconditionFailure("Broad root accepted") }
            catch let error as DiskCleanupError { precondition(error.reason == .protectedLocation) }
        }
        let link = fixture.base.appendingPathComponent("SelectedLink")
        try fixture.fm.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        do { _ = try fixture.scan(link); preconditionFailure("Symbolic selected root accepted") }
        catch let error as DiskCleanupError { precondition(error.reason == .symbolicLink) }
    }

    private static func rememberedFolderRoundtrip() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let suite = "MacThermal.Cleanup.RememberedProbe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "diskCleanupRememberedFolderV1"
        try fixture.file("reviewed-file-not-persisted.dmg")
        let plan = try fixture.scan()
        guard let remembered = DiskCleanup.rememberFolder(from: plan, defaults: defaults) else {
            preconditionFailure("Valid owned folder must be remembered")
        }
        precondition(remembered.rootURL.path == plan.rootURL.path)
        precondition(Set(defaults.persistentDomain(forName: suite)!.keys) == [key])
        let data = defaults.data(forKey: key)!
        let stored = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
        precondition(Set(stored.keys) == ["version", "rootPath", "bookmark", "ancestors"])
        let ancestors = stored["ancestors"] as! [[String: Any]]
        precondition(ancestors.allSatisfy { Set($0.keys) == ["path", "volumeUUID", "inode", "owner", "kind", "birthSeconds", "birthNanoseconds"] })
        precondition(data.range(of: Data("reviewed-file-not-persisted.dmg".utf8)) == nil)
        precondition(plan.candidates.allSatisfy { data.range(of: Data($0.id.uuidString.utf8)) == nil })
        // Normal directory contents changes must not revoke the remembered scope.
        try fixture.file("fresh-file.dmg", modifiedDays: 1, createdDays: 1)
        let restored = DiskCleanup.restoreRememberedFolder(defaults: defaults)!
        let rescanned = try DiskCleanup.scan(rootURL: restored.rootURL,
            cancellation: DiskCleanupCancellation(), now: fixture.now, expectedFolder: restored)
        precondition(rescanned.candidates.map(\.relativePath) == ["reviewed-file-not-persisted.dmg"])
        precondition(rescanned.candidates.first?.id != plan.candidates.first?.id)
        let cancelled = DiskCleanupCancellation()
        cancelled.cancel()
        let cancelledPlan = try fixture.scan(cancellation: cancelled)
        precondition(DiskCleanup.rememberFolder(from: cancelledPlan, defaults: defaults) == nil)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults)?.rootURL.path == restored.rootURL.path,
            "Cancelled analysis must leave an earlier approved folder intact")
        do {
            _ = try DiskCleanup.scan(rootURL: fixture.outside, cancellation: DiskCleanupCancellation(), expectedFolder: restored)
            preconditionFailure("Remembered scope must not approve another root")
        } catch let error as DiskCleanupError { precondition(error.reason == .changed) }
        DiskCleanup.forgetRememberedFolder(defaults: defaults)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)

        for corrupt: Any in [Data([0, 1, 2]), "not-a-bookmark-record", Data(repeating: 0, count: 131_073)] {
            defaults.set(corrupt, forKey: key)
            precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
            precondition(defaults.object(forKey: key) == nil)
        }
        var altered = stored
        altered["rootPath"] = fixture.outside.path
        defaults.set(try PropertyListSerialization.data(fromPropertyList: altered, format: .binary, options: 0), forKey: key)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil && defaults.object(forKey: key) == nil)
        print("Remembered cleanup scope passed: bookmark/identity roundtrip, content changes, exact-root scan binding, isolated settings, folder-only persistence, explicit forgetting and corrupt-record rejection.")
    }

    private static func rememberedFolderChangedScopes() throws {
        let suite = "MacThermal.Cleanup.ScopeProbe." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "diskCleanupRememberedFolderV1"

        let replaced = try Fixture()
        defer { replaced.clean() }
        try replaced.file("old.dmg")
        let originalPlan = try replaced.scan()
        let originalToken = DiskCleanup.rememberFolder(from: originalPlan, defaults: defaults)!
        try replaced.fm.moveItem(at: replaced.root, to: replaced.outside.appendingPathComponent("moved-root"))
        try replaced.fm.createDirectory(at: replaced.root, withIntermediateDirectories: true)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
        precondition(defaults.object(forKey: key) == nil)
        do {
            _ = try DiskCleanup.scan(rootURL: replaced.root, cancellation: DiskCleanupCancellation(), expectedFolder: originalToken)
            preconditionFailure("Root replacement after restore must not become a newly approved scope")
        } catch let error as DiskCleanupError { precondition(error.reason == .changed) }
        precondition(DiskCleanup.rememberFolder(from: originalPlan, defaults: defaults) == nil)

        let parentSwap = try Fixture()
        defer { parentSwap.clean() }
        let parent = parentSwap.root.appendingPathComponent("Parent")
        let chosen = parent.appendingPathComponent("Chosen")
        try parentSwap.file("old.dmg", in: chosen)
        let plan = try parentSwap.scan(chosen)
        let token = DiskCleanup.rememberFolder(from: plan, defaults: defaults)!
        let movedParent = parentSwap.outside.appendingPathComponent("PreviousParent")
        try parentSwap.fm.moveItem(at: parent, to: movedParent)
        try parentSwap.fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try parentSwap.fm.moveItem(at: movedParent.appendingPathComponent("Chosen"), to: chosen)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
        do {
            _ = try DiskCleanup.scan(rootURL: chosen, cancellation: DiskCleanupCancellation(), expectedFolder: token)
            preconditionFailure("Same root inode under a replaced parent must be rejected")
        } catch let error as DiskCleanupError { precondition(error.reason == .changed) }
        precondition(DiskCleanup.rememberFolder(from: plan, defaults: defaults) == nil)

        let symlink = try Fixture()
        defer { symlink.clean() }
        try symlink.file("old.dmg")
        let symlinkPlan = try symlink.scan()
        let symlinkToken = DiskCleanup.rememberFolder(from: symlinkPlan, defaults: defaults)!
        try symlink.fm.moveItem(at: symlink.root, to: symlink.outside.appendingPathComponent("Original"))
        try symlink.fm.createSymbolicLink(at: symlink.root, withDestinationURL: symlink.outside)
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
        do {
            _ = try DiskCleanup.scan(rootURL: symlink.root, cancellation: DiskCleanupCancellation(), expectedFolder: symlinkToken)
            preconditionFailure("Replaced symbolic root must be rejected")
        } catch is DiskCleanupError {}

        let project = try Fixture()
        defer { project.clean() }
        try project.file("old.dmg")
        let projectPlan = try project.scan()
        precondition(DiskCleanup.rememberFolder(from: projectPlan, defaults: defaults) != nil)
        try project.file(".git")
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
        precondition(defaults.object(forKey: key) == nil)
        precondition(DiskCleanup.rememberFolder(from: projectPlan, defaults: defaults) == nil)
        print("Remembered cleanup changes passed: moved/replaced root, same-root inode under swapped parent, symbolic root, restore-to-scan gap, changed-plan rejection and project marker introduced after scan.")
    }
}
