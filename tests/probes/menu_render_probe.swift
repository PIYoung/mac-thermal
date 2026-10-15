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

        var sample: Snapshot {
            let total = capacityUsed == nil ? nil : 1_000_000_000_000.0
            let available = capacityUsed.map { (100 - $0) / 100 * 1_000_000_000_000 }
            let disk = DiskSnapshot(totalBytes: total, availableBytes: available,
                readBytesPerSecond: read, writeBytesPerSecond: write, deviceCount: total == nil ? 0 : 1)
            return Snapshot(cpuTemperature: cpuTemperature, ssdTemperature: total == nil ? nil : 54,
                cpuUsage: cpu, upload: upload, download: download, interfaces: 1,
                cpuSensors: cpuTemperature == nil ? 0 : 1, ssdSensors: total == nil ? 0 : 1,
                thermal: ThermalStatus(thermalState), time: Date(timeIntervalSince1970: 0), uptime: 7_200,
                resources: ResourceSnapshot(memory: .pending, processes: .pending, disk: disk))
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
                       phase: Double, motion: Bool = true, output: URL? = nil,
                       region: CGRect? = nil, expectedSize: NSSize? = nil,
                       reportSize: ((NSSize) -> Void)? = nil) throws -> Data {
        let preferences = MenuBarPreferences(style: style, motionEnabled: motion, intensity: 1.2)
        guard let image = MenuBarContent.preview(sample: sample, preferences: preferences, dark: dark, phase: phase) else {
            throw ProbeError.failed("preview returned nil")
        }
        try check((220...264).contains(image.size.width) && image.size.height == 22,
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
            let expected = MenuBarPreferences(style: style, motionEnabled: false, intensity: 0.95)
            expected.save(defaults: defaults)
            try check(MenuBarPreferences.load(defaults: defaults) == expected, "preference roundtrip failed for \(style)")
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
        print("PASS isolated preferences: rhythm default, roundtrip, invalid values, finite/clamped intensity")
    }

    static func contactSheet(in directory: URL) throws {
        let rows = [("rhythm", "idle-empty"), ("rhythm", "mixed"), ("rhythm", "serious-max-labels"),
                    ("orbit", "mixed"), ("orbit", "busy-full"), ("orbit", "very-large")]
        guard let context = CGContext(data: nil, width: 1200, height: rows.count * 90,
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
                let x: CGFloat = dark ? 600 : 0
                context.setFillColor(NSColor(calibratedWhite: dark ? 0.12 : 0.94, alpha: 1).cgColor)
                context.fill(CGRect(x: x, y: y, width: 600, height: 90))
                let appearance = dark ? "dark" : "light"
                let name = "\(appearance)-\(row.0)-\(row.1)"
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
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
