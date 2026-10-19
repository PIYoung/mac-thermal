import AppKit
import QuartzCore

/// Native status button: cached text and bounded raster work at eight fps.
final class MenuBarContent: NSObject {
    static let imageSize = NSSize(width: 336, height: 22)
    private weak var button: NSStatusBarButton?
    private var sample = Snapshot.pending
    private var baseImage: CGImage?
    private var ink = NSColor.labelColor.cgColor
    private var scale: CGFloat = 2
    private var timer: Timer?
    private var appearanceObservation: NSKeyValueObservation?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var systemSleeping = false
    private var displaySleeping = false
    private var cpuPhase = 0.0
    private var gpuPhase = 0.0
    private var uploadPhase = 0.0
    private var downloadPhase = 0.0
    private var diskPhase = 0.0
    private var lastTick: TimeInterval?
    private var previewAppearance: NSAppearance?
    private var textSignature = ""
    private var displayWidth: CGFloat = 18
    private struct GroupLayout {
        let metric: MenuBarMetric
        let origin: CGFloat
        let width: CGFloat
        let textOffset: CGFloat
        let textWidth: CGFloat
    }
    private var layout: [GroupLayout] = []
    private var orderedMetrics: [MenuBarMetric] { MenuBarMetric.allCases.filter(preferences.visibleMetrics.contains) }
    private var canvasSize: NSSize { NSSize(width: displayWidth, height: Self.imageSize.height) }

    var preferences = MenuBarPreferences.load() {
        didSet {
            guard preferences != oldValue else { return }
            lastTick = nil
            if preferences.visibleMetrics != oldValue.visibleMetrics {
                textSignature = ""
                rebuildBase()
            }
            updateAccessibility()
            configureAnimation()
            displayFrame()
        }
    }

    init(frame: NSRect) {
        super.init()
        observe(.default, .appLanguageDidChange) { [weak self] _ in
            self?.appearanceChanged()
            self?.updateAccessibility()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in self?.appearanceChanged() }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.systemSleeping = true; self?.configureAnimation() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.systemSleeping = false; self?.lastTick = nil; self?.configureAnimation() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.displaySleeping = true; self?.configureAnimation() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.displaySleeping = false; self?.lastTick = nil; self?.appearanceChanged() }
        observe(.default, NSWindow.didChangeBackingPropertiesNotification) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.button?.window else { return }
            self.appearanceChanged()
        }
        observe(.default, NSWindow.didChangeOcclusionStateNotification) { [weak self] notification in
            guard let self, let window = notification.object as? NSWindow, window === self.button?.window else { return }
            self.configureAnimation()
        }
    }

    deinit {
        stop()
        appearanceObservation?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: action)))
    }

    func attach(to button: NSStatusBarButton) {
        stop()
        self.button = button
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.imageHugsTitle = true
        appearanceObservation?.invalidate()
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in self?.appearanceChanged() }
        appearanceChanged()
    }

    var contentWidth: CGFloat { ceil((button?.image?.size.width ?? displayWidth) + 6) }

    func update(sample: Snapshot) {
        self.sample = sample
        let lines = labels
        let signature = lines.joined(separator: "|") + "|\(sample.thermal.level)"
        if signature != textSignature || baseImage == nil {
            textSignature = signature
            rebuildBase(labels: lines)
        }
        updateAccessibility()
        configureAnimation()
        displayFrame()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastTick = nil
    }

    private var motionAllowed: Bool {
        preferences.motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var hasActivity: Bool {
        (preferences.visibleMetrics.contains(.cpu) && (validPercentage(sample.cpuUsage) ?? 0) > 0) ||
        (preferences.visibleMetrics.contains(.gpu) && (validPercentage(sample.resources.gpu.utilizationPercent) ?? 0) > 0) ||
        (preferences.visibleMetrics.contains(.ssd) && [sample.resources.disk.readBytesPerSecond, sample.resources.disk.writeBytesPerSecond].contains { (validRate($0) ?? 0) > 0 }) ||
        (preferences.visibleMetrics.contains(.network) && [sample.upload, sample.download].contains { (validRate($0) ?? 0) > 0 })
    }

    private func configureAnimation() {
        guard let window = button?.window, window.isVisible, !systemSleeping, !displaySleeping, motionAllowed, hasActivity else {
            stop()
            displayFrame()
            return
        }
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 8, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let window = button?.window, window.isVisible, !systemSleeping, !displaySleeping, motionAllowed, hasActivity else {
            configureAnimation()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, min(0.5, now - (lastTick ?? now)))
        lastTick = now
        let load = validPercentage(sample.cpuUsage) ?? 0
        let intensity = max(0.75, min(1.5, preferences.intensity))
        if preferences.visibleMetrics.contains(.cpu), load > 0 {
            cpuPhase = (cpuPhase + elapsed / max(0.8, (3.9 - load * 0.029) / intensity)).truncatingRemainder(dividingBy: 100)
        }
        if preferences.visibleMetrics.contains(.gpu), let gpuLoad = validPercentage(sample.resources.gpu.utilizationPercent), gpuLoad > 0 {
            gpuPhase = (gpuPhase + elapsed / Self.gpuWavePeriod(load: gpuLoad, intensity: intensity)).truncatingRemainder(dividingBy: 1)
        }
        if preferences.visibleMetrics.contains(.network), let upload = validRate(sample.upload), upload > 0 { uploadPhase = (uploadPhase + elapsed / flowPeriod(upload, intensity: intensity)).truncatingRemainder(dividingBy: 1) }
        if preferences.visibleMetrics.contains(.network), let download = validRate(sample.download), download > 0 { downloadPhase = (downloadPhase + elapsed / flowPeriod(download, intensity: intensity)).truncatingRemainder(dividingBy: 1) }
        let diskActivity = (validRate(sample.resources.disk.readBytesPerSecond) ?? 0) + (validRate(sample.resources.disk.writeBytesPerSecond) ?? 0)
        if preferences.visibleMetrics.contains(.ssd), diskActivity > 0 {
            let period = diskActivity < 100_000 ? 5.0 : diskActivity < 5_000_000 ? 3.0 : diskActivity < 50_000_000 ? 1.6 : 1.0
            diskPhase = (diskPhase + elapsed / max(0.9, period / sqrt(intensity))).truncatingRemainder(dividingBy: 1)
        }
        displayFrame()
    }

    private func appearanceChanged() {
        baseImage = nil
        rebuildBase()
        configureAnimation()
        displayFrame()
    }

    private var labels: [String] {
        orderedMetrics.flatMap { metric -> [String] in
            switch metric {
            case .cpu:
                let cpu = validPercentage(sample.cpuUsage).map { String(format: "%.0f%%", $0) } ?? "—%"
                return ["CPU " + cpu, sample.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—"]
            case .gpu:
                let gpu = validPercentage(sample.resources.gpu.utilizationPercent).map { String(format: "%.0f%%", $0) } ?? "—%"
                return ["GPU " + gpu, sample.resources.gpu.coreCount.flatMap { $0 > 0 ? L10n.format("%d코어", $0) : nil } ?? "—"]
            case .ssd:
                return ["R " + rateLabel(sample.resources.disk.readBytesPerSecond), "W " + rateLabel(sample.resources.disk.writeBytesPerSecond)]
            case .network:
                return ["↑ " + rateLabel(sample.upload), "↓ " + rateLabel(sample.download)]
            }
        }
    }

    private var ssdUsedPercent: Double? {
        guard let total = sample.resources.disk.totalBytes, let available = sample.resources.disk.availableBytes,
              total.isFinite, available.isFinite, total > 0, available >= 0 else { return nil }
        return max(0, min(100, (total - available) / total * 100))
    }

    private func validPercentage(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private func validRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func rateLabel(_ value: Double?) -> String {
        guard var value = validRate(value) else { return "—" }
        let units = ["B", "K", "M", "G", "T", "P", "E"]
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 { value /= 1_000; unit += 1 }
        if value >= 999.5 { return ">999E/s" }
        return String(format: unit > 0 && value < 100 ? "%.1f" : "%.0f", value) + units[unit] + "/s"
    }

    private func flowPeriod(_ bytes: Double, intensity: Double) -> Double {
        let kb = bytes / 1_000
        let period = kb < 100 ? 3.1 : kb < 1_000 ? 2.1 : kb < 5_000 ? 1.5 : kb < 20_000 ? 1.1 : 0.9
        return max(0.8, period / sqrt(intensity))
    }

    private var accessibilityLines: [String] {
        var lines = orderedMetrics.flatMap { metric -> [String] in
            switch metric {
            case .cpu:
                let percent = validPercentage(sample.cpuUsage).map { String(format: "%.0f%%", $0) } ?? L10n.text("측정 중")
                return [L10n.format("CPU %@ · 사용률 %@", temperature(sample.cpuTemperature), percent)]
            case .gpu:
                let percent = validPercentage(sample.resources.gpu.utilizationPercent).map { String(format: "%.0f%%", $0) } ?? L10n.text("확인 불가")
                return [L10n.format("GPU 사용률 %@", percent)]
            case .ssd:
                let used = ssdUsedPercent.map { String(format: "%.0f%%", $0) } ?? L10n.text("확인 불가")
                return [L10n.format("SSD 읽기 %@ · 쓰기 %@", rateLabel(sample.resources.disk.readBytesPerSecond), rateLabel(sample.resources.disk.writeBytesPerSecond)),
                        L10n.format("SSD 사용 용량 %@ · 온도 %@", used, temperature(sample.ssdTemperature))]
            case .network:
                return [L10n.format("업로드 %@ · 다운로드 %@", rateLabel(sample.upload), rateLabel(sample.download))]
            }
        }
        if lines.isEmpty { lines = [L10n.text("표시 항목 없음 · 아이콘을 눌러 패널 열기")] }
        return lines
    }

    private func updateAccessibility() {
        guard let button else { return }
        let lines = accessibilityLines
        button.toolTip = L10n.format("Mac Thermal · %@\n%@\n클릭하면 패널과 메뉴바 설정", sample.thermal.title, lines.joined(separator: "\n"))
        button.setAccessibilityLabel(L10n.format("Mac Thermal, 열 상태 %@, %@, 클릭하면 패널과 메뉴바 설정", sample.thermal.title, lines.joined(separator: ", ")))
    }

    private func context() -> CGContext? {
        let width = Int(canvasSize.width * scale)
        let height = Int(Self.imageSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func rebuildBase(labels preparedLabels: [String]? = nil) {
        scale = max(1, button?.window?.backingScaleFactor ?? 2)
        let appearance = previewAppearance ?? button?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            let color = sample.thermal.level > 0 ? sample.thermal.color : NSColor.labelColor
            ink = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            let lines = preparedLabels ?? labels
            // Measure each selected group's actual two-line text once per sample.
            // No hidden slot or fixed-width storage tail is retained between groups.
            layout = []
            var cursor: CGFloat = 2
            for (index, metric) in orderedMetrics.enumerated() {
                let top = (lines[index * 2] as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.3, weight: .medium)]).width
                let bottom = (lines[index * 2 + 1] as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.6, weight: .medium)]).width
                let offset: CGFloat = metric == .ssd ? 18 : metric == .network ? 20 : 29
                let cap: CGFloat = metric == .cpu || metric == .gpu ? 52 : 55
                let textWidth = min(cap, ceil(max(top, bottom)))
                let width = offset + textWidth
                layout.append(GroupLayout(metric: metric, origin: cursor, width: width, textOffset: offset, textWidth: textWidth))
                cursor += width + 7
            }
            displayWidth = layout.isEmpty ? 18 : ceil(cursor - 7 + 2)
            guard let context = context() else { baseImage = nil; return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if layout.isEmpty { drawText("MT", at: NSPoint(x: 3, y: 5.5), width: 12, size: 9.3, color: color) }
            for (index, group) in layout.enumerated() {
                let x = group.origin + group.textOffset
                drawText(lines[index * 2], at: NSPoint(x: x, y: 10.4), width: group.textWidth, size: 9.3, color: color)
                drawText(lines[index * 2 + 1], at: NSPoint(x: x, y: 0.2), width: group.textWidth, size: 8.6, color: color)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(color.withAlphaComponent(0.17).cgColor)
            for group in layout.dropLast() {
                context.fill(CGRect(x: group.origin + group.width + 3.25, y: 5, width: 0.5, height: 12))
            }
            baseImage = context.makeImage()
        }
    }

    private func drawText(_ value: String, at point: NSPoint, width: CGFloat, size: CGFloat, color: NSColor) {
        var fontSize = size
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium), .foregroundColor: color]
        while (value as NSString).size(withAttributes: attributes).width > width && fontSize > 7.5 {
            fontSize -= 0.2
            attributes[.font] = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        }
        (value as NSString).draw(at: point, withAttributes: attributes)
    }

    private func displayFrame() {
        guard let button, let image = composite() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.image = image
        CATransaction.commit()
    }

    private func composite() -> NSImage? {
        if baseImage == nil { rebuildBase() }
        guard let context = context(), let baseImage else { return nil }
        context.draw(baseImage, in: CGRect(origin: .zero, size: canvasSize))
        let animated = motionAllowed && !systemSleeping && !displaySleeping && hasActivity
        for group in layout {
            context.saveGState()
            context.translateBy(x: group.origin, y: 0)
            switch group.metric {
            case .cpu: drawCPU(in: context, phase: animated ? cpuPhase : 0)
            case .gpu: drawGPU(in: context, phase: animated ? gpuPhase : 0, animated: animated)
            case .ssd: drawCapacity(in: context, phase: animated ? diskPhase : 0, animated: animated)
            case .network:
                drawFlow(in: context, x: 0, bytes: sample.upload, phase: animated ? uploadPhase : 0.45, upward: true, animated: animated)
                drawFlow(in: context, x: 9, bytes: sample.download, phase: animated ? downloadPhase : 0.45, upward: false, animated: animated)
            }
            context.restoreGState()
        }
        let width = displayWidth
        guard let image = context.makeImage()?.cropping(to: CGRect(x: 0, y: 0, width: width * scale, height: Self.imageSize.height * scale)) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: Self.imageSize.height))
    }

    private func drawCPU(in context: CGContext, phase: Double) {
        let load = validPercentage(sample.cpuUsage) ?? 0
        let phase = load > 0 ? phase : 0
        context.setFillColor(ink)
        if preferences.style == .rhythm {
            let amplitude = min(0.48, 0.025 + load * 0.0034 * preferences.intensity)
            let ratios = [0.74, 0.94, 0.83, 1.0]
            for index in 0..<4 {
                let angle = (phase * [1.0, 1.13, 0.91, 1.06][index] + Double(index) * 0.23) * .pi * 4
                let wave = (sin(angle) + 0.28 * sin(angle * 2 + Double(index))) / 1.28
                let height = (3 + load * 0.12 * ratios[index]) * (1 + amplitude * wave)
                let rect = CGRect(x: 3 + Double(index) * 6, y: 11 - height / 2, width: 3, height: height)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                context.fillPath()
            }
        } else {
            let active = Int(ceil(load / 12.5))
            for index in 0..<8 {
                let angle = (Double(index) / 8 + phase) * .pi * 2
                let alpha = sample.cpuUsage == nil ? 0.25 : (index < active ? 0.35 + 0.65 * Double(index + 1) / Double(max(active, 1)) : 0.18)
                context.setFillColor(ink.copy(alpha: alpha) ?? ink)
                context.fillEllipse(in: CGRect(x: 12 + cos(angle) * 7.5 - 1.6, y: 11 + sin(angle) * 7.5 - 1.6, width: 3.2, height: 3.2))
            }
        }
    }

    /// Twelve visual steps represent utilization, independently of the GPU core count.
    static func gpuTileCount(for value: Double?) -> Int? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return Int(ceil(value * 12 / 100))
    }

    static func gpuWavePeriod(load: Double, intensity: Double) -> Double {
        max(1.3, (4.3 - load * 0.027) / sqrt(intensity))
    }

    private func drawGPU(in context: CGContext, phase: Double, animated: Bool) {
        let active = Self.gpuTileCount(for: sample.resources.gpu.utilizationPercent)
        for index in 0..<12 {
            let column = index % 4
            let row = index / 4
            let alpha: Double
            if let active, index < active {
                // A restrained diagonal highlight changes brightness, never tile position.
                let wave = animated ? (cos((phase - Double(column + row) * 0.12) * .pi * 2) + 1) / 2 : 0.5
                alpha = 0.82 + wave * 0.18
            } else {
                alpha = active == nil ? 0.12 : 0.18
            }
            context.setFillColor(ink.copy(alpha: alpha) ?? ink)
            let rect = CGRect(x: 3 + Double(column) * 5.5, y: 3.5 + Double(row) * 5.5, width: 4, height: 4)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
            context.fillPath()
        }
    }

    private func drawCapacity(in context: CGContext, phase: Double, animated: Bool) {
        let rect = CGRect(x: 0, y: 2, width: 13, height: 18)
        let outline = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.setFillColor(ink.copy(alpha: 0.15) ?? ink)
        context.addPath(outline)
        context.fillPath()
        guard let percent = ssdUsedPercent, percent > 0 else { return }
        let surface = rect.minY + rect.height * percent / 100
        let activity = (validRate(sample.resources.disk.readBytesPerSecond) ?? 0) + (validRate(sample.resources.disk.writeBytesPerSecond) ?? 0)
        let amplitude = animated && activity > 0 ? min(1.15, min(surface - rect.minY, rect.maxY - surface) * 0.6) : 0
        context.saveGState()
        context.addPath(outline)
        context.clip()
        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: rect.minX, y: rect.minY))
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        for step in 0...24 {
            let fraction = Double(step) / 24
            let x = rect.maxX - rect.width * fraction
            let y = surface + sin((fraction - phase) * .pi * 2) * amplitude
            fill.addLine(to: CGPoint(x: x, y: y))
        }
        fill.closeSubpath()
        context.setFillColor(ink)
        context.addPath(fill)
        context.fillPath()
        context.restoreGState()
    }

    private func drawFlow(in context: CGContext, x: CGFloat, bytes: Double?, phase: Double, upward: Bool, animated: Bool) {
        context.setFillColor(ink.copy(alpha: 0.14) ?? ink)
        context.fill(CGRect(x: x + 1, y: 2, width: 1.5, height: 18))
        guard let rate = validRate(bytes), rate > 0 else { return }
        context.saveGState()
        context.clip(to: CGRect(x: x, y: 2, width: 4, height: 18))
        let length: CGFloat = rate < 100_000 ? 4 : rate < 5_000_000 ? 6 : 8
        for index in 0..<(animated ? 3 : 1) {
            let amount = (phase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let y = upward ? -7 + amount * 35 : 21 - amount * 35
            for segment in 0..<4 {
                let fraction = CGFloat(segment) / 4
                let tailY = upward ? y - fraction * length : y + fraction * length
                context.setFillColor(ink.copy(alpha: 1 - fraction * 0.8) ?? ink)
                context.fill(CGRect(x: x + 0.6, y: tailY, width: 2.3, height: length / 4 + 0.5))
            }
        }
        context.restoreGState()
    }

    /// Offscreen fixtures exercise the same painter without changing the menu bar.
    static func preview(sample: Snapshot, preferences: MenuBarPreferences, dark: Bool, phase: Double, sleeping: Bool = false) -> NSImage? {
        previewRenderer(sample: sample, preferences: preferences, dark: dark, sleeping: sleeping)(phase, nil)
    }

    /// Keep one painter alive to exercise successive frames and sample invalidation.
    /// The optional sample follows the same update path as the live status button.
    static func previewRenderer(sample: Snapshot, preferences: MenuBarPreferences, dark: Bool, sleeping: Bool = false) -> (Double, Snapshot?) -> NSImage? {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        content.systemSleeping = sleeping
        content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.rebuildBase()
        return { phase, replacement in
            if let replacement { content.update(sample: replacement) }
            content.cpuPhase = phase
            content.gpuPhase = phase
            content.uploadPhase = phase
            content.downloadPhase = phase
            content.diskPhase = phase
            return content.composite()
        }
    }

    static func previewPreferenceChange(sample: Snapshot, from old: MenuBarPreferences,
                                        to new: MenuBarPreferences, dark: Bool, phase: Double) -> NSImage? {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = old
        content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.rebuildBase()
        content.preferences = new
        content.cpuPhase = phase
        content.gpuPhase = phase
        content.uploadPhase = phase
        content.downloadPhase = phase
        content.diskPhase = phase
        return content.composite()
    }

    /// Inspect the cached layout and activity gate without adding a status item.
    static func previewLayout(sample: Snapshot, preferences: MenuBarPreferences) -> [MenuBarMetric: CGRect] {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        content.rebuildBase()
        return Dictionary(uniqueKeysWithValues: content.layout.map {
            ($0.metric, CGRect(x: $0.origin, y: 0, width: $0.width, height: Self.imageSize.height))
        })
    }

    static func previewHasActivity(sample: Snapshot, preferences: MenuBarPreferences) -> Bool {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        return content.hasActivity
    }

    static func previewAccessibility(sample: Snapshot, preferences: MenuBarPreferences) -> String {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        return content.accessibilityLines.joined(separator: "\n")
    }
}
