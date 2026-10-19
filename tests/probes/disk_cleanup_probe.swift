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
        try candidatesAndTraversal()
        try identityAndScope()
        try selectionCancellationAndFailure()
        try limitsAndInvalidRoots()
        print("Disk cleanup fixtures passed: metadata candidates; recent/hidden/package/cloud/project exclusions; no symlink traversal; identity/parent/marker changes; exact subset; cancellation; partial failure; bounded scan and no-op. All Trash actions were injected moves inside owned temporary fixtures.")
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
}
