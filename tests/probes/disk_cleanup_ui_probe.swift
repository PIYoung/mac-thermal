import AppKit
import Foundation

enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static func state() -> State { State(enabled: false, requiresApproval: false, title: "Fixture") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
}

private final class EntryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0
    private var expectedScopes = 0
    private var executions = 0
    var counts: (Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (scans, expectedScopes, executions) }
    func recordScan(expected: Bool) { lock.lock(); scans += 1; if expected { expectedScopes += 1 }; lock.unlock() }
    func recordExecution() { lock.lock(); executions += 1; lock.unlock() }
}

private final class ExecutionFixture: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedIDs = Set<UUID>()
    var ids: Set<UUID> { lock.lock(); defer { lock.unlock() }; return storedIDs }
    func record(_ ids: Set<UUID>) { lock.lock(); storedIDs = ids; lock.unlock() }
}

@main
enum DiskCleanupUIProbe {
    private static func waitUntil(line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "A synthetic cleanup job did not complete (caller line \(line))")
    }
    private static func visibleLabels(_ node: NSView) -> [String] {
        guard !node.isHidden else { return [] }
        return ((node as? NSTextField).map { [$0.stringValue] } ?? []) + node.subviews.flatMap(visibleLabels)
    }
    private static func checkBounds(_ node: NSView) {
        for child in node.subviews where !child.isHidden {
            precondition(node.bounds.insetBy(dx: -0.5, dy: -0.5).contains(child.frame),
                "Cleanup content escapes fixed parent: \(type(of: child)) \(child.frame) in \(node.bounds)")
            if !(child is NSControl), !(child is NSScrollView) { checkBounds(child) }
        }
    }
    private static func checkPolicyTextFits(_ node: NSView) {
        guard !node.isHidden else { return }
        if let field = node as? NSTextField, field.maximumNumberOfLines > 1, !field.stringValue.isEmpty {
            let content = NSAttributedString(string: field.stringValue,
                attributes: [.font: field.font ?? NSFont.systemFont(ofSize: 9)])
            let measured = content.boundingRect(with: NSSize(width: max(1, field.frame.width - 4), height: 1_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            precondition(ceil(measured.height) <= field.frame.height + 1,
                "Safety and result text must fit without hiding a line: \(field.stringValue), \(measured.height) > \(field.frame.height)")
        }
        if !(node is NSControl), !(node is NSScrollView) { node.subviews.forEach(checkPolicyTextFits) }
    }

    private static func automaticEntryChecks() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/MacThermalAutoEntry-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for name in ["Installer.dmg", "Installer.pkg", "Large.bin"] {
            let url = root.appendingPathComponent(name)
            try Data("Disposable automatic entry fixture".utf8).write(to: url)
            if name == "Large.bin" {
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 125_000_000)
                try handle.close()
            }
        }
        let future = Date().addingTimeInterval(45 * 86_400)
        let plan = try DiskCleanup.scan(rootURL: root, cancellation: DiskCleanupCancellation(), now: future)
        let installers = Set(plan.candidates.filter { $0.reason == .oldInstaller }.map(\.id))
        precondition(plan.candidates.count == 3 && installers.count == 2)
        let suite = "local.mac-thermal.auto-entry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let homeFixture = EntryFixture()
        var homeOperations = DiskCleanupViewOperations(scan: { _, _, _, _ in
            preconditionFailure("Home entry must not use selected-folder scanning")
        }, execute: { _, _, _, _ in
            homeFixture.recordExecution(); return DiskCleanupResult(items: [], cancelled: false)
        })
        homeOperations.scanHome = { _, progress in
            homeFixture.recordScan(expected: false)
            progress(DiskCleanupProgress(visitedCount: 3, candidateCount: 3, completedCount: 0, totalCount: 0))
            return plan
        }
        let homeView = DiskCleanupView(frame: NSRect(x: 0, y: 0, width: 308, height: 277), operations: homeOperations, defaults: defaults)
        precondition(homeFixture.counts.0 == 0)
        homeView.onEntry(); homeView.onEntry()
        precondition(homeView.probeStage == "ready" && homeView.probeAutomaticHome && homeFixture.counts.0 == 0,
            "Opening the cleanup page must only explain the home scope, never inspect it")
        let initialLanguage = L10n.language
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults); homeView.refreshLanguage(); homeView.layoutSubtreeIfNeeded()
            checkBounds(homeView); checkPolicyTextFits(homeView)
            precondition(homeView.probePrimaryTitle == L10n.text("자동 검사"))
        }
        L10n.setLanguage(initialLanguage, defaults: defaults)
        homeView.probePressPrimary()
        waitUntil { homeView.probeStage == "review" }
        precondition(homeFixture.counts.0 == 1 && homeFixture.counts.2 == 0)
        precondition(homeView.probeCandidateCount == 3 && homeView.probeSelectedIDs.isEmpty && homeView.probeRecommendedIDs.isEmpty,
            "Automatic home scans must never precheck even old installers")
        precondition(!homeView.probePrimaryEnabled && homeView.probeBanner.contains(L10n.text("자동 선택 없음 · 정리할 파일을 직접 선택하세요")))
        homeView.onEntry()
        precondition(homeFixture.counts.0 == 1)
        homeView.probeToggleCandidate(at: 0); homeView.probePressPrimary()
        precondition(homeView.probeStage == "confirmation" && homeView.probeConfirmedIDs.count == 1 && homeFixture.counts.2 == 0,
            "Selecting a file only prepares review; it must not execute a Trash operation")
        let newHomeView = DiskCleanupView(frame: homeView.frame, operations: homeOperations, defaults: defaults)
        newHomeView.onEntry()
        precondition(newHomeView.probeStage == "ready" && newHomeView.probeSelectedIDs.isEmpty && homeFixture.counts.0 == 1,
            "A later home view must neither reuse a file confirmation nor scan automatically")

        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        var stoppingOperations = homeOperations
        stoppingOperations.scanHome = { cancellation, _ in
            started.signal(); _ = finish.wait(timeout: .now() + 2)
            precondition(cancellation.isCancelled)
            return plan
        }
        let stopping = DiskCleanupView(frame: homeView.frame, operations: stoppingOperations, defaults: defaults)
        stopping.onEntry(); stopping.probePressPrimary()
        precondition(started.wait(timeout: .now() + 2) == .success)
        stopping.probePressSecondary(); finish.signal()
        waitUntil { stopping.probeStage == "review" }
        precondition(stopping.probeSelectedIDs.isEmpty && stopping.probeBanner.contains(L10n.text("검사를 중지해 일부 항목만 표시합니다")))
        print("Home cleanup UI passed: four-language scope disclosure before explicit scan, injectable scanner only, no prechecked files, exact review, cancellation, no launch/reopen scans and no Trash calls")

        let fixture = EntryFixture()
        let operations = DiskCleanupViewOperations(scan: { _, expected, _, _ in
            fixture.recordScan(expected: expected != nil)
            return plan
        }, execute: { _, _, _, _ in
            fixture.recordExecution()
            return DiskCleanupResult(items: [], cancelled: false)
        })
        let view = DiskCleanupView(frame: NSRect(x: 0, y: 0, width: 308, height: 277), operations: operations, defaults: defaults)
        precondition(fixture.counts.0 == 0, "Constructing the view must never scan")
        view.onEntry()
        precondition(fixture.counts.0 == 0, "Entry prepares home scope without reading it or opening a picker")
        waitUntil { view.probeStage == "ready" }
        view.probeAcceptFolder(root)
        view.onEntry()
        view.onEntry()
        waitUntil { view.probeStage == "review" }
        precondition(fixture.counts.0 == 1 && fixture.counts.2 == 0, "Repeated entry must not duplicate a running scan or execute Trash")
        precondition(view.probeRecommendedIDs == installers && view.probeSelectedIDs == installers,
            "Only old installers may be automatically recommended and checked")
        precondition(!view.probeSelectedIDs.contains(plan.candidates.first { $0.reason == .oldLargeFile }!.id))
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults)?.rootURL == plan.rootURL)
        let selectedRow = plan.candidates.firstIndex { $0.id == installers.first! }!
        view.probeToggleCandidate(at: selectedRow)
        let edited = view.probeSelectedIDs
        view.onEntry()
        precondition(fixture.counts.0 == 1 && view.probeSelectedIDs == edited,
            "Returning to review must not erase manual deselection")
        view.probePressPrimary()
        precondition(view.probeStage == "confirmation" && view.probeConfirmedIDs == edited && fixture.counts.2 == 0)
        view.onEntry()
        precondition(view.probeConfirmedIDs == edited && fixture.counts.0 == 1)
        let reopened = DiskCleanupView(frame: view.frame, operations: operations, defaults: defaults)
        precondition(fixture.counts.0 == 1, "Application construction must not scan a remembered folder")
        reopened.onEntry()
        waitUntil { reopened.probeStage == "review" }
        precondition(fixture.counts.0 == 2 && fixture.counts.1 == 1 && fixture.counts.2 == 0,
            "Explicit entry must pass remembered scope to the scanner")
        precondition(reopened.probeSelectedIDs == installers, "Checkbox state must not persist across new views")
        reopened.probeForgetFolder()
        precondition(DiskCleanup.restoreRememberedFolder(defaults: defaults) == nil)
        reopened.onEntry()
        precondition(reopened.probeStage == "ready" && reopened.probeAutomaticHome && fixture.counts.0 == 2, "Switching to home must remove the bookmark and wait for an explicit scan")

        let partial = try DiskCleanup.scan(rootURL: root, cancellation: DiskCleanupCancellation(),
            limits: DiskCleanupLimits(maximumEntries: 20_000, maximumCandidates: 1, maximumDepth: 20, maximumSeconds: 8), now: future)
        let cancellation = DiskCleanupCancellation()
        let stopped = try DiskCleanup.scan(rootURL: root, cancellation: cancellation, now: future) { _ in cancellation.cancel() }
        for incomplete in [partial, stopped] {
            let state = EntryFixture()
            let incompleteOperations = DiskCleanupViewOperations(scan: { _, _, _, _ in state.recordScan(expected: false); return incomplete },
                execute: { _, _, _, _ in state.recordExecution(); return DiskCleanupResult(items: [], cancelled: false) })
            let review = DiskCleanupView(frame: view.frame, operations: incompleteOperations, defaults: defaults)
            review.probeAcceptFolder(root)
            waitUntil { review.probeStage == "review" }
            precondition(review.probeSelectedIDs.isEmpty && review.probeRecommendedIDs.isEmpty,
                "Incomplete scans must not precheck candidates")
            review.onEntry()
            precondition(state.counts.0 == 1 && state.counts.2 == 0, "Stopped scans must stay stopped on reentry")
            DiskCleanup.forgetRememberedFolder(defaults: defaults)
        }
        let remaining = try manager.contentsOfDirectory(atPath: root.path)
        precondition(remaining.count == 3)
        print("Automatic cleanup entry passed: one-time folder approval, stable remembered scope, no launch scan/fallback, old-installer recommendations only, manual edits/confirmation retained, incomplete scans unselected, explicit forget and no Trash calls")
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("mac-thermal-cleanup-ui-probe-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        // Only disposable synthetic files are inspected. No Trash API is invoked.
        for index in 0..<12 {
            try Data("Disposable installer fixture \(index)".utf8).write(to: root.appendingPathComponent("Fixture \(index).dmg"))
        }
        let plan = try DiskCleanup.scan(rootURL: root, cancellation: DiskCleanupCancellation(),
            now: Date().addingTimeInterval(45 * 24 * 60 * 60))
        precondition(plan.candidates.count == 12)
        let partialPlan = try DiskCleanup.scan(rootURL: root, cancellation: DiskCleanupCancellation(),
            limits: DiskCleanupLimits(maximumEntries: 20_000, maximumCandidates: 2, maximumDepth: 20, maximumSeconds: 8),
            now: Date().addingTimeInterval(45 * 24 * 60 * 60))
        precondition(partialPlan.truncated && partialPlan.candidates.count == 2)
        let suite = "local.mac-thermal.cleanup-ui.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try automaticEntryChecks()
        let originalLanguage = L10n.language
        defer { L10n.setLanguage(originalLanguage, defaults: defaults) }

        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let execution = ExecutionFixture()
            var operations = DiskCleanupViewOperations(scan: { _, _, _, _ in plan }, execute: { confirmedPlan, ids, cancellation, _ in
                execution.record(ids)
                execution.started.signal()
                _ = execution.finish.wait(timeout: .now() + 3)
                let chosen = confirmedPlan.candidates.filter { ids.contains($0.id) }
                let items = chosen.enumerated().map { index, item in
                    DiskCleanupItemResult(candidateID: item.id, originalURL: item.url, trashURL: nil,
                        status: cancellation.isCancelled ? .skipped : (index == 0 ? .moved : .failed),
                        reason: cancellation.isCancelled ? .cancelled : (index == 0 ? nil : .permissionDenied))
                }
                return DiskCleanupResult(items: items, cancelled: cancellation.isCancelled)
            })
            operations.availableBytes = { _ in 2_000_000_000 }
            let view = DiskCleanupView(frame: NSRect(x: 0, y: 0, width: 308, height: 277), operations: operations, defaults: defaults)
            view.probeSetPlan(partialPlan)
            view.layoutSubtreeIfNeeded()
            precondition(visibleLabels(view).contains(where: { $0.contains(L10n.text("검사 한도에 도달해 일부 항목만 표시합니다")) }),
                "A nonempty partial scan must show its limit warning without requiring a tooltip")
            view.probeSetPlan(plan)
            view.layoutSubtreeIfNeeded()
            checkBounds(view)
            checkPolicyTextFits(view)
            precondition(view.probeHeaderHeight <= 45 && view.probeListHeight >= 130,
                "Removing the duplicate title must reclaim list space")
            precondition(!visibleLabels(view).contains(L10n.text("디스크 정리")),
                "Cleanup must not repeat the title inside its subpage")
            precondition(view.probeStage == "review" && view.probeCandidateCount == 12)
            precondition(view.probeSelectedIDs.isEmpty && !view.probePrimaryEnabled,
                "No candidate may be selected automatically")
            view.probePressPrimary()
            precondition(view.probeStage == "review", "Empty selection must not reach confirmation")
            view.probeToggleCandidate(at: 0)
            view.probeToggleCandidate(at: 3)
            let expected = Set([plan.candidates[0].id, plan.candidates[3].id])
            precondition(view.probeSelectedIDs == expected && view.probePrimaryEnabled)
            view.probePressPrimary()
            precondition(view.probeStage == "confirmation" && view.probeConfirmedIDs == expected)
            precondition(view.probePrimaryTitle == L10n.format("%d개 휴지통으로 이동", 2))
            view.probeToggleCandidate(at: 1)
            precondition(view.probeConfirmedIDs == expected, "Confirmation must freeze the exact selected files")
            view.probePressSecondary()
            precondition(view.probeStage == "review" && view.probeSelectedIDs == expected)
            view.probePressPrimary()
            view.probePressPrimary()
            precondition(view.probeStage == "executing")
            waitUntil { execution.ids == expected }
            precondition(execution.ids == expected)
            if language == .japanese { view.probePressSecondary() }
            execution.finish.signal()
            waitUntil { view.probeStage == "result" }
            let expectedSummary = language == .japanese
                ? L10n.format("이동 %d · 건너뜀 %d · 실패 %d", 0, 2, 0)
                : L10n.format("이동 %d · 건너뜀 %d · 실패 %d", 1, 0, 1)
            precondition(view.probeSummary == expectedSummary, "Partial failure and cancellation counts must be accurate")
            precondition(visibleLabels(view).contains(where: { $0.contains("2.0 GB") }),
                "Current available space must be reported separately from moved bytes")
            view.layoutSubtreeIfNeeded()
            checkBounds(view)
            checkPolicyTextFits(view)
            precondition(view.frame.size == NSSize(width: 308, height: 277))
        }

        defaults.set("ssd", forKey: "dashboardSelectedResourceTabV4")
        L10n.setLanguage(.korean, defaults: defaults)
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        precondition(panel.probeDiskCleanupView == nil, "App/panel construction must not create or scan cleanup")
        let initialFrame = window.frame
        panel.probeOpenDiskCleanup()
        let cleanup = panel.probeDiskCleanupView!
        waitUntil { cleanup.probeStage == "ready" }
        cleanup.probeSetPlan(plan)
        precondition(cleanup.probeStage == "review" && cleanup.probeCandidateCount == 12)
        cleanup.probeToggleCandidate(at: 2)
        let expected = cleanup.probeSelectedIDs
        panel.probeSelectTab(0)
        panel.probeToggleSettings()
        panel.probeToggleSettings()
        panel.probeSelectTab(3)
        panel.probeSetVisible(false)
        panel.probeSetVisible(true)
        precondition(cleanup.probeSelectedIDs == expected, "Tab, settings and panel closure must retain review state")
        panel.probeCloseDiskCleanup()
        panel.probeOpenDiskCleanup()
        precondition(panel.probeDiskCleanupView === cleanup && cleanup.probeSelectedIDs == expected)
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            precondition(panel.probeDiskCleanupButtonTitle == L10n.text("디스크 정리"))
            panel.view.layoutSubtreeIfNeeded()
            checkBounds(cleanup)
            checkPolicyTextFits(cleanup)
        }
        precondition(window.frame == initialFrame && PanelController.surfaceSize == NSSize(width: 340, height: 420))
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: root.path)
        precondition(remainingFiles.count == 12,
            "UI probes must never move or remove their fixture files")
        print("Disk cleanup UI checks passed: 4 languages, unchecked defaults, exact frozen selection, explicit confirmation, partial results/cancel, state retention and fixed panel bounds; no live Trash calls")
    }
}
