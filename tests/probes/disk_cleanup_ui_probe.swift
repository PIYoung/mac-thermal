import AppKit
import Foundation

enum LoginItemManager {
    struct State { let enabled: Bool; let requiresApproval: Bool; let title: String }
    static func state() -> State { State(enabled: false, requiresApproval: false, title: "Fixture") }
    static func enable() throws {}
    static func disable() throws {}
    static func openSettings() {}
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
    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(condition(), "A synthetic cleanup job did not complete")
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
        let originalLanguage = L10n.language
        defer { L10n.setLanguage(originalLanguage, defaults: defaults) }

        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: defaults)
            let execution = ExecutionFixture()
            var operations = DiskCleanupViewOperations(scan: { _, _, _ in plan }, execute: { confirmedPlan, ids, cancellation, _ in
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
            let view = DiskCleanupView(frame: NSRect(x: 0, y: 0, width: 344, height: 317), operations: operations)
            view.probeSetPlan(partialPlan)
            view.layoutSubtreeIfNeeded()
            precondition(visibleLabels(view).contains(where: { $0.contains(L10n.text("검사 한도에 도달해 일부 항목만 표시합니다")) }),
                "A nonempty partial scan must show its limit warning without requiring a tooltip")
            view.probeSetPlan(plan)
            view.layoutSubtreeIfNeeded()
            checkBounds(view)
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
            precondition(view.frame.size == NSSize(width: 344, height: 317))
        }

        defaults.set("ssd", forKey: "dashboardSelectedResourceTabV4")
        L10n.setLanguage(.korean, defaults: defaults)
        let panel = PanelController(defaults: defaults)
        let window = DashboardWindow(controller: panel)
        let initialFrame = window.frame
        panel.probeOpenDiskCleanup()
        let cleanup = panel.probeDiskCleanupView!
        cleanup.probeSetPlan(plan)
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
        }
        precondition(window.frame == initialFrame && PanelController.surfaceSize == NSSize(width: 380, height: 468))
        let remainingFiles = try fileManager.contentsOfDirectory(atPath: root.path)
        precondition(remainingFiles.count == 12,
            "UI probes must never move or remove their fixture files")
        print("Disk cleanup UI checks passed: 4 languages, unchecked defaults, exact frozen selection, explicit confirmation, partial results/cancel, state retention and fixed panel bounds; no live Trash calls")
    }
}
