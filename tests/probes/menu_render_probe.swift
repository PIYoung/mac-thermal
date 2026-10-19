import AppKit
import Foundation

@main
struct MenuRenderProbe {
    struct Fixture {
        let name: String
        let cpu: Double?
        let cpuTemperature: Double?
        let capacityUsed: Double?
        let read: Double?
        let write: Double?
        let upload: Double?
        let download: Double?
        var thermalState: ProcessInfo.ThermalState = .nominal
        var gpu: Double? = nil
        var gpuCoreCount: Int? = nil

        var sample: Snapshot {
            let total = capacityUsed == nil ? nil : 1_000_000_000_000.0
            let available = capacityUsed.map { (100 - $0) / 100 * 1_000_000_000_000 }
            let disk = DiskSnapshot(totalBytes: total, availableBytes: available,
                readBytesPerSecond: read, writeBytesPerSecond: write, deviceCount: total == nil ? 0 : 1)
            return Snapshot(cpuTemperature: cpuTemperature, ssdTemperature: total == nil ? nil : 54,
                cpuUsage: cpu, upload: upload, download: download, interfaces: 1,
                cpuSensors: cpuTemperature == nil ? 0 : 1, ssdSensors: total == nil ? 0 : 1,
                thermal: ThermalStatus(thermalState), time: Date(timeIntervalSince1970: 0), uptime: 7_200,
                resources: ResourceSnapshot(memory: .pending, processes: .pending, disk: disk,
                    gpu: GPUSnapshot(utilizationPercent: gpu, model: "Apple M4 Pro", coreCount: gpuCoreCount)))
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { switch self { case .failed(let message): return message } }
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeError.failed(message) }
    }

    static func render(_ sample: Snapshot, style: MenuBarAnimationStyle, dark: Bool,
                       phase: Double, motion: Bool = true, primary: MenuBarPrimaryMetric = .cpu,
                       sleeping: Bool = false, output: URL? = nil,
                       region: CGRect? = nil, expectedSize: NSSize? = nil,
                       reportSize: ((NSSize) -> Void)? = nil) throws -> Data {
        let preferences = MenuBarPreferences(style: style, motionEnabled: motion, intensity: 1.2, primaryMetric: primary)
        guard let image = MenuBarContent.preview(sample: sample, preferences: preferences, dark: dark, phase: phase, sleeping: sleeping) else {
            throw ProbeError.failed("preview returned nil")
        }
        let shift: CGFloat = primary == .cpuAndGPU ? 72 : 0
        try check(((220 + shift)...(264 + shift)).contains(image.size.width) && image.size.height == 22,
            "logical image size outside compact bounds: \(image.size)")
        if let expectedSize { try check(image.size == expectedSize, "image size changed across phases: \(expectedSize) -> \(image.size)") }
        reportSize?(image.size)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProbeError.failed("preview has no CGImage")
        }
        try check(cgImage.width == Int(image.size.width * 2) && cgImage.height == 44,
            "wrong raster dimensions: \(cgImage.width)x\(cgImage.height)")
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ProbeError.failed("PNG encoding failed")
        }
        if let output { try png.write(to: output, options: .atomic) }
        guard let bytes = cgImage.dataProvider?.data else { throw ProbeError.failed("missing pixel data") }
        let source = bytes as Data
        let pixelRegion = region.map {
            CGRect(x: $0.minX * 2, y: $0.minY * 2, width: $0.width * 2, height: $0.height * 2)
        } ?? CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        try check(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height).contains(pixelRegion),
            "pixel region outside image")
        try check(cgImage.bitsPerPixel == 32, "unexpected bitmap pixel depth")
        var pixels = Data()
        for row in Int(pixelRegion.minY)..<Int(pixelRegion.maxY) {
            let start = row * cgImage.bytesPerRow + Int(pixelRegion.minX) * 4
            pixels.append(source.subdata(in: start..<(start + Int(pixelRegion.width) * 4)))
        }
        return pixels
    }

    static func preferenceChecks() throws {
        let name = "local.mac-thermal.menu-render-probe.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw ProbeError.failed("isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.removePersistentDomain(forName: name)
        try check(MenuBarPreferences.load(defaults: defaults) == MenuBarPreferences(), "default preferences mismatch")
        for style in MenuBarAnimationStyle.allCases {
            for primary in MenuBarPrimaryMetric.allCases {
                let expected = MenuBarPreferences(style: style, motionEnabled: false, intensity: 0.95, primaryMetric: primary)
                expected.save(defaults: defaults)
                try check(MenuBarPreferences.load(defaults: defaults) == expected, "preference roundtrip failed for \(style)/\(primary)")
            }
        }
        defaults.removeObject(forKey: "menuBarPrimaryMetricV1")
        try check(MenuBarPreferences.load(defaults: defaults).primaryMetric == .cpuAndGPU, "missing preference did not default to CPU + GPU")
        for invalidMetric: Any in [1234, -1, "gpu", 0.5, Double.infinity] {
            defaults.set(invalidMetric, forKey: "menuBarPrimaryMetricV1")
            try check(MenuBarPreferences.load(defaults: defaults).primaryMetric == .cpuAndGPU, "invalid primary metric did not fall back")
        }
        defaults.set(1234, forKey: "menuBarAnimationStyleV2")
        defaults.set(Double.infinity, forKey: "menuBarMotionIntensityV2")
        let invalid = MenuBarPreferences.load(defaults: defaults)
        try check(invalid.style == .rhythm && invalid.intensity == 1.2, "invalid values did not fall back")
        defaults.set(-100.0, forKey: "menuBarMotionIntensityV2")
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 0.75, "low intensity not clamped")
        defaults.set(100.0, forKey: "menuBarMotionIntensityV2")
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 1.5, "high intensity not clamped")
        MenuBarPreferences(style: .orbit, motionEnabled: true, intensity: .nan).save(defaults: defaults)
        try check(MenuBarPreferences.load(defaults: defaults).intensity == 1.2, "nonfinite save not normalized")
        print("PASS isolated preferences: CPU + GPU/rhythm defaults, preserved stored CPU/GPU choices, three-mode roundtrip, invalid values, finite/clamped intensity")
    }

    static func gpuChecks(in directory: URL, reduceMotion: Bool) throws {
        let cases: [(String, Double?, Int?)] = [
            ("idle", 0, 0), ("one", 1, 1), ("half", 50, 6), ("full", 100, 12),
            ("pending", nil, nil), ("nan", .nan, nil), ("negative", -1, nil),
            ("over", 101, nil), ("infinite", .infinity, nil)
        ]
        for (name, value, expected) in cases {
            try check(MenuBarContent.gpuTileCount(for: value) == expected, "GPU tile count incorrect for \(name)")
        }
        try check(MenuBarContent.gpuWavePeriod(load: 1, intensity: 1.2) > MenuBarContent.gpuWavePeriod(load: 100, intensity: 1.2),
            "GPU brightness wave did not speed up with load")
        func fixture(_ value: Double?) -> Snapshot {
            Fixture(name: "GPU", cpu: 37, cpuTemperature: 74, capacityUsed: 61,
                read: 4_600_000, write: 19_500, upload: 7_000, download: 26_000,
                gpu: value, gpuCoreCount: 20).sample
        }
        let region = CGRect(x: 0, y: 0, width: 26, height: 22)
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                var expectedSize = NSSize.zero
                _ = try render(fixture(50), style: style, dark: dark, phase: 0.08, reportSize: { expectedSize = $0 })
                for (name, value, _) in cases {
                    let prefix = "gpu-\(dark ? "dark" : "light")-\(style.rawValue)-\(name)"
                    let a = try render(fixture(value), style: style, dark: dark, phase: 0.08, primary: .gpu,
                        output: directory.appendingPathComponent(prefix + ".png"), region: region, expectedSize: expectedSize)
                    let b = try render(fixture(value), style: style, dark: dark, phase: 0.39, primary: .gpu,
                        region: region, expectedSize: expectedSize)
                    let active = MenuBarContent.gpuTileCount(for: value).map { $0 > 0 } ?? false
                    try check(active && !reduceMotion ? a != b : a == b,
                        "GPU active/static phase comparison failed for \(prefix)")
                    let offA = try render(fixture(value), style: style, dark: dark, phase: 0.08, motion: false,
                        primary: .gpu, region: region, expectedSize: expectedSize)
                    let offB = try render(fixture(value), style: style, dark: dark, phase: 0.39, motion: false,
                        primary: .gpu, region: region, expectedSize: expectedSize)
                    try check(offA == offB, "GPU motion-off failed for \(prefix)")
                }
                let sleepA = try render(fixture(50), style: style, dark: dark, phase: 0.08, primary: .gpu, sleeping: true)
                let sleepB = try render(fixture(50), style: style, dark: dark, phase: 0.39, primary: .gpu, sleeping: true)
                try check(sleepA == sleepB, "sleeping did not freeze GPU/SSD/network")
                let switches = MenuBarPrimaryMetric.allCases.flatMap { old in
                    MenuBarPrimaryMetric.allCases.filter { $0 != old }.map { (old, $0) }
                }
                for (old, new) in switches {
                    let before = MenuBarPreferences(style: style, primaryMetric: old)
                    let after = MenuBarPreferences(style: style, primaryMetric: new)
                    guard let changed = MenuBarContent.previewPreferenceChange(sample: fixture(50), from: before,
                              to: after, dark: dark, phase: 0.17),
                          let fresh = MenuBarContent.preview(sample: fixture(50), preferences: after, dark: dark, phase: 0.17),
                          let changedCG = changed.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let freshCG = fresh.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let changedBytes = changedCG.dataProvider?.data,
                          let freshBytes = freshCG.dataProvider?.data else {
                        throw ProbeError.failed("GPU preference invalidation preview unavailable")
                    }
                    try check(changed.size == fresh.size && changedBytes as Data == freshBytes as Data,
                        "CPU/GPU setting did not immediately invalidate cached text")
                }
            }
        }
        print("PASS GPU grid: 0/1/50/100 and invalid values, load-based speed, light/dark, active/off/reduced/sleep motion, unchanged dimensions")
        print("PASS immediate CPU/GPU/CPU + GPU preference switching: fresh text and matching raster without a new sample")
    }

    static func simultaneousChecks(in directory: URL, reduceMotion: Bool) throws {
        let active = Fixture(name: "both", cpu: 37, cpuTemperature: 74, capacityUsed: 61,
            read: 4_600_000, write: 19_500, upload: 7_000, download: 26_000,
            gpu: 50, gpuCoreCount: 20).sample
        let regions: [(String, CGRect)] = [
            ("CPU", CGRect(x: 0, y: 0, width: 26, height: 22)),
            ("GPU", CGRect(x: 76, y: 0, width: 26, height: 22)),
            ("SSD", CGRect(x: 160, y: 0, width: 13, height: 22)),
            ("network", CGRect(x: 253, y: 0, width: 15, height: 22))
        ]
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                var singleSize = NSSize.zero
                _ = try render(active, style: style, dark: dark, phase: 0.08, primary: .cpu,
                    reportSize: { singleSize = $0 })
                let bothSize = NSSize(width: singleSize.width + 72, height: singleSize.height)
                let prefix = "both-\(dark ? "dark" : "light")-\(style.rawValue)"
                _ = try render(active, style: style, dark: dark, phase: 0.08, primary: .cpuAndGPU,
                    output: directory.appendingPathComponent(prefix + ".png"), expectedSize: bothSize)
                for (name, region) in regions {
                    let a = try render(active, style: style, dark: dark, phase: 0.08, primary: .cpuAndGPU,
                        region: region, expectedSize: bothSize)
                    let b = try render(active, style: style, dark: dark, phase: 0.39, primary: .cpuAndGPU,
                        region: region, expectedSize: bothSize)
                    try check(reduceMotion ? a == b : a != b, "simultaneous \(name) phase comparison failed")
                    let offA = try render(active, style: style, dark: dark, phase: 0.08, motion: false,
                        primary: .cpuAndGPU, region: region, expectedSize: bothSize)
                    let offB = try render(active, style: style, dark: dark, phase: 0.39, motion: false,
                        primary: .cpuAndGPU, region: region, expectedSize: bothSize)
                    try check(offA == offB, "simultaneous \(name) motion-off failed")
                }
                // Existing SSD/network pixels must only shift, never overlap or change.
                let rates = CGRect(x: 88, y: 0, width: singleSize.width - 88, height: 22)
                let singleRates = try render(active, style: style, dark: dark, phase: 0.17,
                    primary: .cpu, region: rates)
                let bothRates = try render(active, style: style, dark: dark, phase: 0.17,
                    primary: .cpuAndGPU, region: rates.offsetBy(dx: 72, dy: 0))
                try check(singleRates == bothRates, "simultaneous mode changed or cropped SSD/network content")
                for (cpu, gpu) in [(0.0, 0.0), (37, 0), (0, 50)] {
                    let fixture = Fixture(name: "isolated", cpu: cpu, cpuTemperature: 74, capacityUsed: 0,
                        read: 0, write: 0, upload: 0, download: 0, gpu: gpu, gpuCoreCount: 20).sample
                    for (name, region) in regions.prefix(2) {
                        let a = try render(fixture, style: style, dark: dark, phase: 0.08,
                            primary: .cpuAndGPU, region: region)
                        let b = try render(fixture, style: style, dark: dark, phase: 0.39,
                            primary: .cpuAndGPU, region: region)
                        let moving = (name == "CPU" ? cpu : gpu) > 0 && !reduceMotion
                        try check(moving ? a != b : a == b, "simultaneous isolated activity failed for \(name)")
                    }
                }
                let sleepA = try render(active, style: style, dark: dark, phase: 0.08,
                    primary: .cpuAndGPU, sleeping: true)
                let sleepB = try render(active, style: style, dark: dark, phase: 0.39,
                    primary: .cpuAndGPU, sleeping: true)
                try check(sleepA == sleepB, "sleep did not freeze simultaneous mode")
            }
        }
        print("PASS simultaneous CPU + GPU: both regions animate independently, idle/off/sleep freeze, SSD/network exact shifted pixels, compact width +72pt")
    }

    static func contactSheet(in directory: URL) throws {
        let rows = [("rhythm", "idle-empty"), ("rhythm", "mixed"), ("rhythm", "serious-max-labels"),
                    ("orbit", "mixed"), ("orbit", "busy-full"), ("orbit", "very-large"),
                    ("gpu", "idle"), ("gpu", "one"), ("gpu", "half"), ("gpu", "full"), ("both", "0")]
        guard let context = CGContext(data: nil, width: 1500, height: rows.count * 90,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProbeError.failed("contact sheet context unavailable")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for (index, row) in rows.enumerated() {
            let y = CGFloat((rows.count - 1 - index) * 90)
            for dark in [false, true] {
                let x: CGFloat = dark ? 750 : 0
                context.setFillColor(NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: y, width: 750, height: 90))
                let appearance = dark ? "dark" : "light"
                let name = row.0 == "both" ? "both-\(appearance)-\(row.1)" : row.0 == "gpu" ? "gpu-\(appearance)-0-\(row.1)" : "\(appearance)-\(row.0)-\(row.1)"
                (name as NSString).draw(at: NSPoint(x: x + 12, y: y + 61), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: dark ? NSColor.white : NSColor.black])
                guard let image = NSImage(contentsOf: directory.appendingPathComponent(name + ".png")),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw ProbeError.failed("contact sheet fixture missing")
                }
                context.draw(cgImage, in: CGRect(x: x + 12, y: y + 9, width: CGFloat(cgImage.width), height: 44))
            }
        }
        guard let cgImage = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw ProbeError.failed("contact sheet encoding failed")
        }
        try png.write(to: directory.appendingPathComponent("contact-sheet.png"), options: .atomic)
    }

    static func regionMotionChecks(active: Snapshot, idle: Snapshot, reduceMotion: Bool) throws {
        let regions: [(String, CGRect)] = [
            ("CPU", CGRect(x: 0, y: 0, width: 26, height: 22)),
            ("SSD", CGRect(x: 88, y: 0, width: 13, height: 22)),
            ("network", CGRect(x: 181, y: 0, width: 15, height: 22))
        ]
        var failures: [String] = []
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                for (name, region) in regions {
                    let activeA = try render(active, style: style, dark: dark, phase: 0.08, region: region)
                    let activeB = try render(active, style: style, dark: dark, phase: 0.39, region: region)
                    if reduceMotion {
                        if activeA != activeB { failures.append("system reduce motion did not freeze active \(name), dark \(dark), style \(style)") }
                    } else {
                        if activeA == activeB { failures.append("active \(name) did not change at partial load, dark \(dark), style \(style)") }
                    }
                    let idleA = try render(idle, style: style, dark: dark, phase: 0.08, region: region)
                    let idleB = try render(idle, style: style, dark: dark, phase: 0.39, region: region)
                    if idleA != idleB { failures.append("idle \(name) changed at zero activity, dark \(dark), style \(style)") }
                    let staticA = try render(active, style: style, dark: dark, phase: 0.08, motion: false, region: region)
                    let staticB = try render(active, style: style, dark: dark, phase: 0.39, motion: false, region: region)
                    if staticA != staticB { failures.append("motion off did not freeze \(name), dark \(dark), style \(style)") }
                }
            }
        }
        try check(failures.isEmpty, failures.joined(separator: "; "))
        print("PASS region pixels: CPU/SSD/network active motion, zero activity frozen, motion-off frozen")
    }

    static func benchmark(_ sample: Snapshot) throws {
        let frames = 1_000
        let rounds = 5
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                let painter = MenuBarContent.previewRenderer(sample: sample,
                    preferences: MenuBarPreferences(style: style), dark: dark)
                // Reuse a painter exactly as the eight-fps status button does:
                // creating its text raster and observers is outside the timed loop.
                for frame in 0..<100 { _ = painter(Double(frame % 100) / 100, nil) }
                var durations: [Double] = []
                var widths = 0.0
                var failed = false
                for _ in 0..<rounds {
                    let start = DispatchTime.now().uptimeNanoseconds
                    for frame in 0..<frames {
                        autoreleasepool {
                            if let image = painter(Double(frame % 100) / 100, nil) {
                                widths += image.size.width
                            } else { failed = true }
                        }
                    }
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    durations.append(Double(elapsed) / Double(frames) / 1_000)
                }
                try check(!failed && widths > 0, "benchmark frame unavailable")
                let median = durations.sorted()[rounds / 2]
                print(String(format: "BENCH %@ %@: median %.3f us/frame (%d rounds x %d frames)",
                    dark ? "dark" : "light", style == .rhythm ? "rhythm" : "orbit", median, rounds, frames))
            }
        }
    }

    static func sampleInvalidationChecks(_ fixtures: [Fixture]) throws {
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                let preferences = MenuBarPreferences(style: style)
                let painter = MenuBarContent.previewRenderer(sample: fixtures[0].sample,
                    preferences: preferences, dark: dark)
                for fixture in fixtures + fixtures.reversed() {
                    guard let updated = painter(0.17, fixture.sample),
                          let fresh = MenuBarContent.preview(sample: fixture.sample, preferences: preferences,
                            dark: dark, phase: 0.17),
                          let updatedCG = updated.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let freshCG = fresh.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let updatedBytes = updatedCG.dataProvider?.data,
                          let freshBytes = freshCG.dataProvider?.data else {
                        throw ProbeError.failed("sample invalidation renderer unavailable")
                    }
                    try check(updated.size == fresh.size,
                        "cached width did not follow sample changes for \(fixture.name)")
                    try check((updatedBytes as Data) == (freshBytes as Data),
                        "cached text pixels did not follow sample changes for \(fixture.name)")
                }
            }
        }
        print("PASS persistent sample changes: identical text, pixels, and compact width in both directions")
    }

    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let outputPath = CommandLine.arguments.dropFirst().first ?? "build/menu-previews"
        let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try preferenceChecks()

        let fixtures: [Fixture] = [
            Fixture(name: "idle-empty", cpu: 0, cpuTemperature: 38, capacityUsed: 0,
                read: 0, write: 0, upload: 0, download: 0),
            Fixture(name: "busy-full", cpu: 100, cpuTemperature: 118, capacityUsed: 100,
                read: 2_400_000_000, write: 1_100_000_000, upload: 2_400_000_000, download: 12_600_000_000),
            Fixture(name: "mixed", cpu: 37, cpuTemperature: 74, capacityUsed: 61,
                read: 4_600_000, write: 19_500, upload: 7_000, download: 26_000),
            Fixture(name: "pending", cpu: nil, cpuTemperature: nil, capacityUsed: nil,
                read: nil, write: nil, upload: nil, download: nil),
            Fixture(name: "invalid", cpu: .nan, cpuTemperature: nil, capacityUsed: nil,
                read: -.infinity, write: -1, upload: .infinity, download: .nan),
            Fixture(name: "unit-boundaries", cpu: 99.9, cpuTemperature: 99.9, capacityUsed: 49.9,
                read: 999.5, write: 999_500, upload: 999_499, download: 999_500_000),
            Fixture(name: "very-large", cpu: 100, cpuTemperature: 100, capacityUsed: 50,
                read: Double.greatestFiniteMagnitude, write: Double.greatestFiniteMagnitude,
                upload: Double.greatestFiniteMagnitude, download: Double.greatestFiniteMagnitude),
            Fixture(name: "serious-max-labels", cpu: 100, cpuTemperature: 130, capacityUsed: 99,
                read: 999_400_000_000, write: 999_900_000_000,
                upload: 999_400_000_000, download: 999_900_000_000, thermalState: .serious)
        ]
        try sampleInvalidationChecks(fixtures)
        if CommandLine.arguments.contains("--benchmark") { try benchmark(fixtures[2].sample) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try gpuChecks(in: directory, reduceMotion: reduceMotion)
        try simultaneousChecks(in: directory, reduceMotion: reduceMotion)
        try regionMotionChecks(active: fixtures[2].sample, idle: fixtures[0].sample, reduceMotion: reduceMotion)
        var count = 0
        for dark in [false, true] {
            for style in MenuBarAnimationStyle.allCases {
                let prefix = "\(dark ? "dark" : "light")-\(style == .rhythm ? "rhythm" : "orbit")"
                for fixture in fixtures {
                    var fixtureSize = NSSize.zero
                    _ = try render(fixture.sample, style: style, dark: dark, phase: 0.17,
                        output: directory.appendingPathComponent("\(prefix)-\(fixture.name).png"),
                        reportSize: { fixtureSize = $0 })
                    _ = try render(fixture.sample, style: style, dark: dark, phase: 0.61,
                        expectedSize: fixtureSize)
                    count += 1
                }
                let busy = fixtures[1].sample
                let frameA = try render(busy, style: style, dark: dark, phase: 0.17,
                    output: directory.appendingPathComponent("\(prefix)-phase-a.png"))
                let frameB = try render(busy, style: style, dark: dark, phase: 0.61,
                    output: directory.appendingPathComponent("\(prefix)-phase-b.png"))
                if reduceMotion {
                    try check(frameA == frameB, "system reduce motion did not freeze \(prefix)")
                } else {
                    try check(frameA != frameB, "enabled motion frames did not differ for \(prefix)")
                }
                let frozenA = try render(busy, style: style, dark: dark, phase: 0.17, motion: false,
                    output: directory.appendingPathComponent("\(prefix)-motion-off.png"))
                let frozenB = try render(busy, style: style, dark: dark, phase: 0.61, motion: false)
                try check(frozenA == frozenB, "disabled motion changed for \(prefix)")
                count += 3
            }
        }
        try contactSheet(in: directory)
        print("PASS \(count) PNG fixtures: 220...264x22 pt / 2x raster, 2 appearances x 2 styles")
        print("PASS every fixture keeps identical image width across animation phases")
        print("PASS phase changes: \(reduceMotion ? "system reduce motion active; dynamic comparison skipped, static equality verified" : "enabled frames differ; disabled frames equal")")
        print("OUTPUT \(directory.path)")
    }
}
