import AppKit
import Foundation

@main
struct MenuRenderProbe {
    enum ProbeError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { switch self { case .failed(let message): return message } }
    }
    static let all: Set<MenuBarMetric> = [.cpu, .gpu, .ssd, .network]
    static var combinations: [Set<MenuBarMetric>] {
        (0..<16).map { mask in
            Set(MenuBarMetric.allCases.filter { $0 != .codex }.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ProbeError.failed(message) }
    }
    static func sample(cpu: Double? = 37, gpu: Double? = 50, read: Double? = 4_600_000,
                       write: Double? = 19_500, upload: Double? = 7_000, download: Double? = 26_000,
                       temperature: Double? = 74, ssdTemperature: Double? = 54, gpuTemperature: Double? = nil, memoryTemperature: Double? = nil, cores: Int? = 20,
                       thermal: ProcessInfo.ThermalState = .nominal) -> Snapshot {
        Snapshot(cpuTemperature: temperature, ssdTemperature: ssdTemperature, cpuUsage: cpu,
            upload: upload, download: download, interfaces: 1, cpuSensors: 1, ssdSensors: 1,
            thermal: ThermalStatus(thermal), time: Date(timeIntervalSince1970: 0), uptime: 7_200,
            resources: ResourceSnapshot(memory: .pending, processes: .pending,
                disk: DiskSnapshot(totalBytes: 1_000_000_000_000, availableBytes: 390_000_000_000,
                    readBytesPerSecond: read, writeBytesPerSecond: write, deviceCount: 1),
                gpu: GPUSnapshot(utilizationPercent: gpu, model: "Apple M4 Pro", coreCount: cores)), gpuTemperature: gpuTemperature, memoryProximityTemperature: memoryTemperature)
    }
    static func cgImage(_ image: NSImage) throws -> CGImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProbeError.failed("image has no pixels")
        }
        return cg
    }
    static func pixels(_ image: NSImage, region: CGRect? = nil) throws -> Data {
        let cg = try cgImage(image)
        guard let source = cg.dataProvider?.data else { throw ProbeError.failed("missing pixel data") }
        let data = source as Data
        let area = region.map { CGRect(x: $0.minX * 2, y: $0.minY * 2, width: $0.width * 2, height: $0.height * 2) }
            ?? CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        try check(CGRect(x: 0, y: 0, width: cg.width, height: cg.height).contains(area), "region outside image")
        var result = Data()
        for row in Int(area.minY)..<Int(area.maxY) {
            let start = row * cg.bytesPerRow + Int(area.minX) * 4
            result.append(data.subdata(in: start..<(start + Int(area.width) * 4)))
        }
        return result
    }
    static func render(_ sample: Snapshot, visible: Set<MenuBarMetric> = all,
                       style: MenuBarAnimationStyle = .rhythm, dark: Bool = false,
                       phase: Double = 0.08, motion: Bool = true, sleeping: Bool = false,
                       output: URL? = nil) throws -> NSImage {
        let preferences = MenuBarPreferences(style: style, motionEnabled: motion, visibleMetrics: visible)
        guard let image = MenuBarContent.preview(sample: sample, preferences: preferences, dark: dark,
            phase: phase, sleeping: sleeping) else { throw ProbeError.failed("preview returned nil") }
        try check((18...336).contains(image.size.width) && image.size.height == 22, "invalid compact dimensions: \(image.size)")
        let cg = try cgImage(image)
        try check(cg.width == Int(image.size.width * 2) && cg.height == 44, "invalid 2x raster dimensions")
        if let output {
            guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                throw ProbeError.failed("PNG encoding failed")
            }
            try png.write(to: output, options: .atomic)
        }
        return image
    }
    static func preferenceChecks() throws {
        let name = "local.mac-thermal.menu-render-probe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw ProbeError.failed("isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        try check(MenuBarPreferences.load(defaults: defaults) == MenuBarPreferences(), "fresh preferences mismatch")
        try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all.union([.codex]), "fresh launch includes Codex")
        for (old, expected) in [(0, Set<MenuBarMetric>([.cpu, .ssd, .network, .codex])),
                                (1, Set<MenuBarMetric>([.gpu, .ssd, .network, .codex])), (2, all.union([.codex])), (-1, all.union([.codex])), (1234, all.union([.codex]))] {
            defaults.set(old, forKey: "menuBarPrimaryMetricV1")
            try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == expected, "legacy selection migration failed: \(old)")
        }
        for selected in combinations {
            defaults.set(selected.map(\.rawValue), forKey: "menuBarVisibleMetricsV1")
            try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == selected.union([.codex]), "upgrade lost resource choices or Codex default")
        }
        defaults.removeObject(forKey: "menuBarVisibleMetricsV1")
        for style in MenuBarAnimationStyle.allCases {
            for visible in combinations + combinations.map({ $0.union([.codex]) }) {
                let expected = MenuBarPreferences(style: style, motionEnabled: false, intensity: 0.95, visibleMetrics: visible)
                expected.save(defaults: defaults)
                try check(MenuBarPreferences.load(defaults: defaults) == expected, "visibility preference roundtrip failed")
                try check(defaults.stringArray(forKey: "menuBarVisibleMetricsV2") == MenuBarMetric.allCases.filter(visible.contains).map(\.rawValue),
                    "saved visibility array has unstable order")
            }
        }
        defaults.set(0, forKey: "menuBarPrimaryMetricV1")
        defaults.set([], forKey: "menuBarVisibleMetricsV2")
        try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics.isEmpty, "explicit empty selection was lost to legacy migration")
        for invalid: Any in ["gpu", 12, ["cpu", "unknown"], [true]] {
            defaults.set(invalid, forKey: "menuBarVisibleMetricsV2")
            try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all.union([.codex]), "malformed visibility did not fall back to all")
        }
        defaults.set(1234, forKey: "menuBarAnimationStyleV2")
        defaults.set(Double.infinity, forKey: "menuBarMotionIntensityV2")
        let invalid = MenuBarPreferences.load(defaults: defaults)
        try check(invalid.style == .rhythm && invalid.intensity == 1.2, "invalid animation values did not fall back")
        defaults.set(-100.0, forKey: "menuBarMotionIntensityV2")
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 0.75, "low intensity not clamped")
        defaults.set(100.0, forKey: "menuBarMotionIntensityV2")
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 1.5, "high intensity not clamped")
        MenuBarPreferences(intensity: .nan).save(defaults: defaults)
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 1.2, "nonfinite save not normalized")
        print("PASS preferences: five selected by default, legacy selection migration, 32 selections including empty, ordered persistence, invalid values")
    }
    static func layoutChecks(in directory: URL) throws {
        let fixtures: [(String, Snapshot)] = [
            ("mixed", sample()),
            ("idle", sample(cpu: 0, gpu: 0, read: 0, write: 0, upload: 0, download: 0)),
            ("pending", sample(cpu: nil, gpu: nil, read: nil, write: nil, upload: nil, download: nil, temperature: nil, cores: nil)),
            ("invalid", sample(cpu: .nan, gpu: .infinity, read: -1, write: .nan, upload: .infinity, download: -.infinity)),
            ("full", sample(cpu: 100, gpu: 100, read: 999_400_000_000, write: 999_900_000_000,
                upload: 999_400_000_000, download: 999_900_000_000, temperature: 130, cores: 4096, thermal: .serious)),
            ("huge", sample(read: Double.greatestFiniteMagnitude, write: Double.greatestFiniteMagnitude,
                upload: Double.greatestFiniteMagnitude, download: Double.greatestFiniteMagnitude))
        ]
        var count = 0
        for dark in [false, true] {
            for (mask, visible) in combinations.enumerated() {
                for (name, fixture) in fixtures {
                    let preferences = MenuBarPreferences(visibleMetrics: visible)
                    let layout = MenuBarContent.previewLayout(sample: fixture, preferences: preferences)
                    try check(Set(layout.keys) == visible, "hidden metric retains a layout slot")
                    let ordered = MenuBarMetric.allCases.compactMap { layout[$0] }
                    for (left, right) in zip(ordered, ordered.dropFirst()) {
                        try check(right.minX - left.maxX == 7, "group gap does not equal compact 7pt")
                    }
                    let a = try render(fixture, visible: visible, dark: dark, phase: 0.08,
                        output: name == "mixed" ? directory.appendingPathComponent("\(dark ? "dark" : "light")-selection-\(mask).png") : nil)
                    let b = try render(fixture, visible: visible, dark: dark, phase: 0.39)
                    try check(a.size == b.size, "animation phase changed selected menu width")
                    if let last = ordered.last {
                        try check(last.maxX + 2 == a.size.width, "trailing placeholder or crop detected")
                        try check(ordered.first?.minX == 2, "leading hidden placeholder detected")
                    } else {
                        try check(a.size == NSSize(width: 18, height: 22), "all-off mode is not a tiny clickable glyph")
                        try check(try pixels(a).contains(where: { $0 != 0 }), "all-off glyph is invisible")
                    }
                    for metric in visible {
                        guard let frame = layout[metric] else { throw ProbeError.failed("missing selected layout") }
                        let single = try render(fixture, visible: [metric], dark: dark, phase: 0.08)
                        let singleLayout = MenuBarContent.previewLayout(sample: fixture,
                            preferences: MenuBarPreferences(visibleMetrics: [metric]))
                        try check(singleLayout[metric]?.width == frame.width, "group text measurement depends on neighboring slots")
                        let left = try pixels(a, region: frame)
                        let right = try pixels(single, region: CGRect(x: 2, y: 0, width: frame.width, height: 22))
                        try check(left == right, "selected group pixels overlap, crop, or change with neighbors: \(metric)")
                    }
                    count += 1
                }
            }
        }
        // Actual SSD text controls the next group's position; no old 59pt tail remains.
        let small = MenuBarContent.previewLayout(sample: sample(read: 0, write: 0), preferences: MenuBarPreferences())
        let large = MenuBarContent.previewLayout(sample: sample(read: 999_400_000, write: 999_400_000), preferences: MenuBarPreferences())
        try check((small[.ssd]?.width ?? 0) < (large[.ssd]?.width ?? 0), "SSD text width is still reserved at a fixed maximum")
        try check((small[.network]?.minX ?? 0) < (large[.network]?.minX ?? 0), "network did not follow the compact SSD text edge")
        print("PASS \(count) layout fixtures: all 16 combinations, visible groups match standalone pixels, 7pt gaps, no placeholders/crops, 18...336x22pt")
    }
    static func motionChecks() throws {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                for visible in combinations {
                    let preferences = MenuBarPreferences(style: style, visibleMetrics: visible)
                    try check(MenuBarContent.previewHasActivity(sample: sample(), preferences: preferences) == !visible.isEmpty,
                        "all-off selection keeps activity alive")
                    let activeA = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.08)
                    let activeB = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.39)
                    let moving = !visible.isEmpty && !reduceMotion
                    try check(moving ? try pixels(activeA) != pixels(activeB) : try pixels(activeA) == pixels(activeB),
                        "selected activity phase comparison failed")
                    for sleeping in [false, true] {
                        let a = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.08, motion: false, sleeping: sleeping)
                        let b = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.39, motion: false, sleeping: sleeping)
                        try check(try pixels(a) == pixels(b), "motion-off/sleep changed selected menu pixels")
                    }
                    let sleepA = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.08, sleeping: true)
                    let sleepB = try render(sample(), visible: visible, style: style, dark: dark, phase: 0.39, sleeping: true)
                    try check(try pixels(sleepA) == pixels(sleepB), "sleep did not freeze selected metrics")
                    for active in MenuBarMetric.allCases {
                        let fixture = sample(cpu: active == .cpu ? 37 : 0, gpu: active == .gpu ? 50 : 0,
                            read: active == .ssd ? 4_600_000 : 0, write: 0,
                            upload: active == .network ? 7_000 : 0, download: 0)
                        try check(MenuBarContent.previewHasActivity(sample: fixture, preferences: preferences) == visible.contains(active),
                            "hidden activity keeps animation timer alive: \(active)")
                        let a = try render(fixture, visible: visible, style: style, dark: dark, phase: 0.08)
                        let b = try render(fixture, visible: visible, style: style, dark: dark, phase: 0.39)
                        let expectedMotion = visible.contains(active) && !reduceMotion
                        try check(expectedMotion ? try pixels(a) != pixels(b) : try pixels(a) == pixels(b),
                            "hidden or inactive metric animates: \(active)")
                    }
                }
            }
        }
        print("PASS motion: only visible activity animates or keeps timer gate alive; idle, all-off, user-off, Reduce Motion, sleep remain static")
    }
    static func cacheAndAccessibilityChecks() throws {
        for dark in [false, true] {
            for visible in combinations {
                let before = MenuBarPreferences(visibleMetrics: all)
                let after = MenuBarPreferences(visibleMetrics: visible)
                guard let changed = MenuBarContent.previewPreferenceChange(sample: sample(), from: before, to: after, dark: dark, phase: 0.17) else {
                    throw ProbeError.failed("preference change preview unavailable")
                }
                let fresh = try render(sample(), visible: visible, dark: dark, phase: 0.17)
                try check(changed.size == fresh.size && (try pixels(changed)) == pixels(fresh), "visibility change did not immediately rebuild cached text/layout")
                let painter = MenuBarContent.previewRenderer(sample: sample(), preferences: after, dark: dark)
                for fixture in [sample(), sample(cpu: 100, gpu: 100), sample(cpu: nil, gpu: nil, read: nil, upload: nil), sample()] {
                    guard let updated = painter(0.17, fixture) else { throw ProbeError.failed("cached renderer unavailable") }
                    let expected = try render(fixture, visible: visible, dark: dark, phase: 0.17)
                    try check(updated.size == expected.size && (try pixels(updated)) == pixels(expected), "sample update left stale text/layout pixels")
                }
                let text = MenuBarContent.previewAccessibility(sample: sample(), preferences: after)
                for (metric, marker) in [(MenuBarMetric.cpu, "CPU"), (.gpu, "GPU"), (.ssd, "SSD"), (.network, L10n.text("업로드 %@ · 다운로드 %@").components(separatedBy: "%@")[0])] {
                    try check(text.contains(marker) == visible.contains(metric), "hidden metric announced to accessibility: \(metric)")
                }
            }
        }
        for (value, count) in [(0.0, 0), (1, 1), (50, 6), (100, 12)] {
            try check(MenuBarContent.gpuTileCount(for: value) == count, "GPU tile steps incorrect")
        }
        for value in [Double.nan, .infinity, -1, 101] { try check(MenuBarContent.gpuTileCount(for: value) == nil, "invalid GPU value accepted") }
        try check(MenuBarContent.gpuTileCount(for: nil) == nil, "missing GPU value accepted")
        try check(MenuBarContent.gpuWavePeriod(load: 1, intensity: 1.2) > MenuBarContent.gpuWavePeriod(load: 100, intensity: 1.2), "GPU wave does not speed up with load")
        print("PASS cache and accessibility: immediate selection/sample updates, only visible metrics announced, GPU tile boundaries")
    }
    static func codexChecks(in directory: URL) throws {
        let now = sample().time
        let started = now.addingTimeInterval(-3600)
        func record(_ age: TimeInterval = 0, tokens: Int64 = 123_456) -> CodexMonitorSnapshot {
            CodexMonitorSnapshot(appStartedAt: started, connection: .connected, recordsEnabled: true,
                recordsCount: 12, lastRecordAt: now.addingTimeInterval(-age), dailyTokens: tokens, updatedAt: now)
        }
        var state = CodexMenuActivity()
        state.receive(record(), now: now, uptime: 10)
        try check(!state.isAnimating(at: 10), "initial scan animated as fresh activity")
        try check(state.frameInterval(at: 10) == 0.75, "running app must idle slowly before a new record")
        try check(state.frame(at: 12) == state.frame(at: 12.7) && state.frame(at: 12) != state.frame(at: 12.75), "idle pose cadence is not 0.75 seconds")
        var next = record(tokens: 123_457)
        next.lastRecordAt = now.addingTimeInterval(1)
        state.receive(next, now: now.addingTimeInterval(1), uptime: 11)
        try check(state.isAnimating(at: 11) && !state.isAnimating(at: 21), "activity must stop after 10s without another record")
        try check(state.frameInterval(at: 11) == 0.125 && state.frameInterval(at: 21) == 0.75, "activity must speed up then return to idle")
        try check(state.frame(at: 12) != state.frame(at: 12.125), "active poses must advance at eight fps")
        state.receive(next, now: now.addingTimeInterval(2), uptime: 12)
        try check(state.gestureEndsAt == 21, "duplicate snapshot restarted gesture")
        var newer = next
        newer.lastRecordAt = now.addingTimeInterval(8)
        newer.dailyTokens = 123_458
        state.receive(newer, now: now.addingTimeInterval(8), uptime: 18)
        try check(state.isAnimating(at: 25) && !state.isAnimating(at: 28), "fresh records must renew the finite activity window")
        state.cancelGesture()
        var old = newer
        old.lastRecordAt = now.addingTimeInterval(9)
        old.dailyTokens = 123_459
        state.receive(old, now: now.addingTimeInterval(90), uptime: 90)
        try check(!state.isAnimating(at: 90), "old catch-up records animate")
        var off = record(); off.recordsEnabled = false
        state.receive(off, now: now, uptime: 100)
        try check(state.tokens == nil && !state.isAnimating(at: 100), "OFF exposes stale usage")
        try check(state.isVisible && state.frame(at: 102) != state.frame(at: 102.75), "record reading OFF must retain the running-app idle cycle")
        state.receive(record(), now: now, uptime: 101)
        try check(!state.isAnimating(at: 101), "re-enable replayed catch-up gesture")
        var closed = record(); closed.appStartedAt = nil
        state.receive(closed, now: now, uptime: 102)
        try check(!state.isVisible && state.tokens == nil, "closed Codex must not retain a menu slot")
        try check(state.frame(at: 102) == 0 && state.frame(at: 102.75) == 0, "closed app still changes poses")
        let quiet = sample(cpu: 0, gpu: 0, read: 0, write: 0, upload: 0, download: 0)
        let onlyCodex = MenuBarPreferences(visibleMetrics: [.codex])
        let idleCadence = MenuBarContent.previewCodexCadence(sample: quiet, snapshot: off, preferences: onlyCodex)
        try check(idleCadence.0 && idleCadence.1 == 0.75, "Codex-only idle must keep a low-frequency timer without reading records")
        let stoppedCadence = MenuBarContent.previewCodexCadence(sample: quiet, snapshot: closed, preferences: onlyCodex)
        try check(!stoppedCadence.0, "closed app must not keep the animation timer alive")
        var partial = record(tokens: 0); partial.incomplete = true
        state.receive(partial, now: now, uptime: 103)
        try check(state.tokens == nil, "partial zero presented as confirmed zero")
        partial.dailyTokens = 123_456
        state.receive(partial, now: now, uptime: 104)
        try check(state.tokens == 123_456 && state.snapshot.incomplete, "partial metadata must remain available to the tooltip")
        let suite = "menu-codex-probe-\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        for language in AppLanguage.allCases {
            L10n.setLanguage(language, defaults: isolated)
            for dark in [false, true] {
                for mask in 0..<32 {
                    let visible = Set(MenuBarMetric.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
                    let prefs = MenuBarPreferences(visibleMetrics: visible)
                    let (optionalImage, layout, text) = MenuBarContent.previewCodex(sample: sample(), snapshot: record(), preferences: prefs, dark: dark, frame: 1)
                    try check(Set(layout.keys) == visible, "Codex layout selection mismatch")
                    let image = optionalImage!
                    try check(image.size.width <= 374, "icon-only menu exceeds compact content cap")
                    if let icon = layout[.codex] {
                        try check(icon.minX == 2 && icon.width == 26, "Codex must be a compact leading icon without a text slot")
                        var changed = record(120, tokens: 9_999_999_999)
                        changed.incomplete = true
                        let unchanged = MenuBarContent.previewCodex(sample: sample(), snapshot: changed, preferences: prefs, dark: dark, frame: 0).0!
                        let idle = MenuBarContent.previewCodex(sample: sample(), snapshot: record(), preferences: prefs, dark: dark, frame: 0).0!
                        try check(unchanged.size == idle.size && (try pixels(unchanged)) == pixels(idle), "token/age text still leaks into menu pixels or width")
                    }
                    let frames = MenuBarMetric.menuOrder.compactMap { layout[$0] }
                    for (left, right) in zip(frames, frames.dropFirst()) { try check(right.minX - left.maxX == 7, "Codex spacing is not 7pt") }
                    if let end = frames.last { try check(end.maxX + 2 == image.size.width, "Codex leaves a trailing gap") }
                    try check(text.contains("Codex") == visible.contains(.codex), "hidden Codex announced to VoiceOver")
                    let (other, _, _) = MenuBarContent.previewCodex(sample: sample(), snapshot: record(), preferences: prefs, dark: dark, frame: 3)
                    if visible.contains(.codex), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        let frame = layout[.codex]!
                        try check(try pixels(image, region: frame) != pixels(other!, region: frame), "fresh record robot is static")
                    }
                    for disabled in [true, false] {
                        let stoppedPrefs = MenuBarPreferences(motionEnabled: false, visibleMetrics: visible)
                        let a = MenuBarContent.previewCodex(sample: sample(), snapshot: record(), preferences: disabled ? stoppedPrefs : prefs, dark: dark, frame: 1, sleeping: !disabled).0!
                        let b = MenuBarContent.previewCodex(sample: sample(), snapshot: record(), preferences: disabled ? stoppedPrefs : prefs, dark: dark, frame: 3, sleeping: !disabled).0!
                        try check(try pixels(a) == pixels(b), "OFF or sleeping Codex still animates")
                    }
                    if mask == 31, language == .korean {
                        let png = NSBitmapImageRep(cgImage: try cgImage(image)).representation(using: .png, properties: [:])!
                        try png.write(to: directory.appendingPathComponent("codex-\(dark ? "dark" : "light").png"))
                    }
                }
                for fixture in [off, closed, partial, record(120), record(7200), record(172800)] {
                    let (image, layout, text) = MenuBarContent.previewCodex(sample: sample(), snapshot: fixture, preferences: MenuBarPreferences(), dark: dark)
                    try check(image != nil && (layout[.codex] != nil) == (fixture.appStartedAt != nil), "Codex runtime visibility fallback failed")
                    if !fixture.recordsEnabled { try check(!text.contains("123456"), "OFF tooltip leaked a stale token count") }
                    if fixture.appStartedAt != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        let a = MenuBarContent.previewCodex(sample: quiet, snapshot: fixture, preferences: onlyCodex, dark: dark, frame: 1).0!
                        let b = MenuBarContent.previewCodex(sample: quiet, snapshot: fixture, preferences: onlyCodex, dark: dark, frame: 3).0!
                        try check(try pixels(a) != pixels(b), "idle robot is static without fresh records")
                    }
                }
            }
        }
        L10n.setLanguage(.korean, defaults: isolated)
        print("PASS Codex menu: 32 selections × four languages × two appearances, slow running-app idle, 8fps fresh-record burst/expiry, low idle-only timer cadence, no catch-up/re-enable burst, OFF/sleep gates")
    }
    static func quotaChecks(in directory: URL) throws {
        let time = sample().time
        var local = CodexMonitorSnapshot(appStartedAt: time.addingTimeInterval(-120), connection: .connected)
        let painter = MenuBarContent.previewCodexUpdater(sample: sample())
        let (baseline, baselineLayout) = painter(local)
        for state in [CodexQuotaConnection.connected, .connecting, .unavailable, .needsLogin, .disconnected] {
            local.quota = CodexQuotaSnapshot(connection: state, windows: [
                CodexQuotaWindow(slot: 1, usedPercent: 95, durationMinutes: 10080, resetsAt: time.addingTimeInterval(86400))
            ], fetchedAt: time, blocked: true)
            let (image, layout) = painter(local)
            try check(layout[.codex]?.width == 26 && image!.size == baseline!.size, "Panel-only quota must not reserve menu width")
            try check(try pixels(image!) == pixels(baseline!), "Account quota state must not change menu pixels")
            for metric in all { try check(layout[metric] == baselineLayout[metric], "Account quota changed resource spacing") }
            let text = MenuBarContent.previewCodex(sample: sample(), snapshot: local, preferences: MenuBarPreferences(), dark: false).2
            try check(!text.contains(L10n.text("계정 사용 제한")) && !text.contains(L10n.text("계정 한도 확인 중")), "Panel-only quota must not appear in menu accessibility text")
        }
        local.appStartedAt = nil; local.connection = .notRunning
        local.quota.connection = .connected
        try check(painter(local).1[.codex] == nil, "Account-only connection must not create a menu icon")
        print("PASS panel-only quota: account states leave menu pixels, 26pt robot width, resource spacing, accessibility and runtime-based visibility unchanged")
    }

    static func appearanceCacheChecks() throws {
        let painter = MenuBarContent.previewAppearanceRenderer(sample: sample(thermal: .serious))
        let (light, _) = painter(false, nil, false)
        let (dark, initialCount) = painter(true, nil, false)
        guard let light, let dark else { throw ProbeError.failed("appearance cache fixture missing") }
        try check(try pixels(light) != pixels(dark), "appearance cache lost text/icon contrast")
        for _ in 0..<100 {
            let (nextLight, _) = painter(false, nil, false)
            let (nextDark, count) = painter(true, nil, false)
            try check(count == initialCount, "snapshot appearances repeatedly rasterized cached text")
            try check(nextLight === light && nextDark === dark, "same animation frame was repeatedly composited")
            try check(try pixels(nextLight!) == pixels(light), "cached light appearance changed pixels")
            try check(try pixels(nextDark!) == pixels(dark), "cached dark appearance changed pixels")
        }
        let (changed, changedCount) = painter(true, sample(cpu: 99, thermal: .fair), false)
        try check(changedCount > initialCount && (try pixels(changed!)) != pixels(dark), "sample/thermal update left stale text or color")
        let (_, forcedCount) = painter(true, nil, true)
        try check(forcedCount > changedCount, "accessibility/language invalidation reused stale raster")
        let nominal = MenuBarContent.previewAppearanceRenderer(sample: sample())
        let (first, _) = nominal(false, nil, false)
        let (second, nominalCount) = nominal(true, nil, false)
        try check(first != nil && second != nil && (try pixels(first!)) != pixels(second!),
                  "nominal light/dark contrast lost")
        for dark in [true, false, true, false] {
            let (next, count) = nominal(dark, nil, false)
            try check(next === (dark ? second : first) && count == nominalCount,
                      "nominal snapshot repeatedly rasterized its frame")
        }
        let (warning, _) = nominal(false, sample(temperature: 100), false)
        try check(warning?.isTemplate == false, "warning was tinted as a monochrome template")
        try check((try pixels(warning!)) != pixels(first!), "warning transition reused nominal frame")
        let (recovered, _) = nominal(false, sample(), false)
        try check(try pixels(recovered!) == pixels(first!), "warning recovery left a stale colored frame")
        print("PASS appearance cache: 200 alternating snapshots reuse identical pixels and frame objects; light/dark contrast, data, warnings, recovery and forced appearance updates invalidate correctly")
    }

    static func preparationReuseChecks() throws {
        let painter = MenuBarContent.previewPreparationCounts(sample: sample())
        _ = painter(false, nil, false)
        let baseline = painter(true, nil, false)
        for _ in 0..<100 {
            _ = painter(false, nil, false)
            let current = painter(true, nil, false)
            try check(current.0 == baseline.0 && current.1 == baseline.1,
                      "snapshot appearance repeated label formatting or color resolution")
        }
        let changed = painter(true, sample(temperature: 100), false)
        try check(changed.0 > baseline.0 && changed.1 > baseline.1, "fresh warning sample did not refresh prepared inputs")
        let forced = painter(true, nil, true)
        try check(forced.0 > changed.0 && forced.1 > changed.1, "forced language/contrast invalidation retained prepared inputs")
        print("PASS prepared inputs: 200 snapshot appearances reuse labels/signature/resolved colors; fresh samples and forced changes refresh them")
    }

    static func isolatedWarningChecks() throws {
        for dark in [false, true] {
            for motion in [false, true] {
                let prefs = MenuBarPreferences(motionEnabled: motion)
                let baseline = sample(temperature: 88)
                let base = MenuBarContent.preview(sample: baseline, preferences: prefs, dark: dark, phase: 0.3)!
                let baseFrames = MenuBarContent.previewLayout(sample: baseline, preferences: prefs)
                let system = MenuBarContent.preview(sample: sample(temperature: 88, thermal: .critical), preferences: prefs, dark: dark, phase: 0.3)!
                try check(try pixels(system) == pixels(base), "System thermal pressure must not color unrelated metrics")
                for (changed, metric) in [(sample(temperature: 98), MenuBarMetric.cpu),
                                          (sample(temperature: 88, ssdTemperature: 74), .ssd),
                                          (sample(temperature: 88, gpuTemperature: 100), .gpu)] {
                    let image = MenuBarContent.preview(sample: changed, preferences: prefs, dark: dark, phase: 0.3)!
                    let frames = MenuBarContent.previewLayout(sample: changed, preferences: prefs)
                    for sibling in MenuBarMetric.allCases {
                        guard let frame = frames[sibling], let baseFrame = baseFrames[sibling] else { continue }
                        let equal = try pixels(image, region: frame) == pixels(base, region: baseFrame)
                        try check(equal == (sibling != metric), "Warning leaked or missing: \(metric), sibling \(sibling), dark \(dark), motion \(motion)")
                    }
                    let tooltip = MenuBarContent.previewAccessibility(sample: changed, preferences: prefs)
                    try check(tooltip.contains(metric == .cpu ? "CPU" : metric == .gpu ? "GPU" : "SSD"), "Warning source absent from tooltip")
                }
            }
        }
        try check(TemperatureWarning.cpu(nil) == .normal && TemperatureWarning.cpu(.nan) == .normal, "Unknown is not overheating")
        try check(TemperatureWarning.cpu(89.9) == .normal && TemperatureWarning.cpu(90) == .warm && TemperatureWarning.cpu(100) == .hot, "CPU warning boundaries")
        try check(TemperatureWarning.ssd(59.9) == .normal && TemperatureWarning.ssd(60) == .warm && TemperatureWarning.ssd(70) == .hot, "SSD warning boundaries")
        let prefs = MenuBarPreferences()
        let menu = MenuBarContent.previewRenderer(sample: sample(), preferences: prefs, dark: false)
        let nominal = try pixels(menu(0.3, nil)!)
        let warning = try pixels(menu(0.3, sample(gpuTemperature: 100))!)
        try check(warning != nominal, "GPU warning must invalidate the cached menu even when visible text is unchanged")
        try check(try pixels(menu(0.3, sample())!) == nominal, "GPU warning recovery must clear cached color")
        try check(try pixels(menu(0.3, sample(memoryTemperature: 85))!) == nominal, "Memory proximity warning must not color any menu item")
        try check(TemperatureWarning.gpu(90) == .warm && TemperatureWarning.gpu(100) == .hot, "GPU thresholds")
        try check(TemperatureWarning.memoryProximity(74.9) == .normal && TemperatureWarning.memoryProximity(75) == .warm && TemperatureWarning.memoryProximity(85) == .hot, "Memory proximity thresholds")
        print("PASS isolated warnings: only affected CPU/GPU/SSD text and shapes change; sibling metrics remain byte identical in light/dark and motion on/off")
    }

    static func benchmark() throws {
        let frames = 1_000
        for visible in [all, Set<MenuBarMetric>([.ssd, .network]), []] {
            let painter = MenuBarContent.previewRenderer(sample: sample(), preferences: MenuBarPreferences(visibleMetrics: visible), dark: false)
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<frames { _ = painter(Double(index % 100) / 100, nil) }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames) / 1_000
            print(String(format: "BENCH %d visible: %.3f us/frame (%d frames)", visible.count, micros, frames))
        }
        let painter = MenuBarContent.previewAppearanceRenderer(sample: sample())
        _ = painter(false, nil, false); _ = painter(true, nil, false)
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<2_000 { _ = painter(index.isMultiple(of: 2), nil, false) }
        let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / 2_000 / 1_000
        print(String(format: "BENCH cached snapshot: %.3f us/appearance (2000 snapshots)", micros))
    }
    static func contactSheet(in directory: URL) throws {
        guard let context = CGContext(data: nil, width: 1500, height: 16 * 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProbeError.failed("contact sheet context unavailable")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (mask, visible) in combinations.enumerated() {
            let y = CGFloat((15 - mask) * 80)
            for dark in [false, true] {
                let x: CGFloat = dark ? 750 : 0
                context.setFillColor(NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: y, width: 750, height: 80))
                let title = visible.isEmpty ? "MT" : MenuBarMetric.allCases.filter(visible.contains).map(\.title).joined(separator: " + ")
                (title as NSString).draw(at: NSPoint(x: x + 12, y: y + 58), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14), .foregroundColor: dark ? NSColor.white : NSColor.black])
                let image = try render(sample(), visible: visible, dark: dark)
                let cg = try cgImage(image)
                context.draw(cg, in: CGRect(x: x + 12, y: y + 7, width: CGFloat(cg.width), height: CGFloat(cg.height)))
            }
        }
        guard let cg = context.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ProbeError.failed("contact sheet encoding failed")
        }
        try png.write(to: directory.appendingPathComponent("contact-sheet.png"), options: .atomic)
    }
    static func main() {
        do {
            let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/menu-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try preferenceChecks()
            try layoutChecks(in: directory)
            try motionChecks()
            try cacheAndAccessibilityChecks()
            try codexChecks(in: directory)
            try quotaChecks(in: directory)
            try appearanceCacheChecks()
            try preparationReuseChecks()
            try isolatedWarningChecks()
            if CommandLine.arguments.contains("--benchmark") { try benchmark() }
            try contactSheet(in: directory)
            print("OUTPUT \(directory.path)")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
