import AppKit
import Foundation

@main
struct MenuRenderProbe {
    enum ProbeError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { switch self { case .failed(let message): return message } }
    }
    static let all = Set(MenuBarMetric.allCases)
    static var combinations: [Set<MenuBarMetric>] {
        (0..<16).map { mask in
            Set(MenuBarMetric.allCases.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        }
    }
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw ProbeError.failed(message) }
    }
    static func sample(cpu: Double? = 37, gpu: Double? = 50, read: Double? = 4_600_000,
                       write: Double? = 19_500, upload: Double? = 7_000, download: Double? = 26_000,
                       temperature: Double? = 74, cores: Int? = 20,
                       thermal: ProcessInfo.ThermalState = .nominal) -> Snapshot {
        Snapshot(cpuTemperature: temperature, ssdTemperature: 54, cpuUsage: cpu,
            upload: upload, download: download, interfaces: 1, cpuSensors: 1, ssdSensors: 1,
            thermal: ThermalStatus(thermal), time: Date(timeIntervalSince1970: 0), uptime: 7_200,
            resources: ResourceSnapshot(memory: .pending, processes: .pending,
                disk: DiskSnapshot(totalBytes: 1_000_000_000_000, availableBytes: 390_000_000_000,
                    readBytesPerSecond: read, writeBytesPerSecond: write, deviceCount: 1),
                gpu: GPUSnapshot(utilizationPercent: gpu, model: "Apple M4 Pro", coreCount: cores)))
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
        try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all, "fresh launch must show all four metrics")
        for (old, expected) in [(0, Set<MenuBarMetric>([.cpu, .ssd, .network])),
                                (1, Set<MenuBarMetric>([.gpu, .ssd, .network])), (2, all), (-1, all), (1234, all)] {
            defaults.set(old, forKey: "menuBarPrimaryMetricV1")
            try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == expected, "legacy selection migration failed: \(old)")
        }
        for style in MenuBarAnimationStyle.allCases {
            for visible in combinations {
                let expected = MenuBarPreferences(style: style, motionEnabled: false, intensity: 0.95, visibleMetrics: visible)
                expected.save(defaults: defaults)
                try check(MenuBarPreferences.load(defaults: defaults) == expected, "visibility preference roundtrip failed")
                try check(defaults.stringArray(forKey: "menuBarVisibleMetricsV1") == MenuBarMetric.allCases.filter(visible.contains).map(\.rawValue),
                    "saved visibility array has unstable order")
            }
        }
        defaults.set(0, forKey: "menuBarPrimaryMetricV1")
        defaults.set([], forKey: "menuBarVisibleMetricsV1")
        try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics.isEmpty, "explicit empty selection was lost to legacy migration")
        for invalid: Any in ["gpu", 12, ["cpu", "unknown"], [true]] {
            defaults.set(invalid, forKey: "menuBarVisibleMetricsV1")
            try check(MenuBarPreferences.load(defaults: defaults).visibleMetrics == all, "malformed visibility did not fall back to all")
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
        print("PASS preferences: four visible by default, legacy CPU/GPU/both migration, 16 selections including empty, ordered persistence, invalid values")
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
    static func benchmark() throws {
        let frames = 1_000
        for visible in [all, Set<MenuBarMetric>([.ssd, .network]), []] {
            let painter = MenuBarContent.previewRenderer(sample: sample(), preferences: MenuBarPreferences(visibleMetrics: visible), dark: false)
            let start = DispatchTime.now().uptimeNanoseconds
            for index in 0..<frames { _ = painter(Double(index % 100) / 100, nil) }
            let micros = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(frames) / 1_000
            print(String(format: "BENCH %d visible: %.3f us/frame (%d frames)", visible.count, micros, frames))
        }
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
            if CommandLine.arguments.contains("--benchmark") { try benchmark() }
            try contactSheet(in: directory)
            print("OUTPUT \(directory.path)")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
