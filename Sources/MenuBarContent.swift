import AppKit
import QuartzCore

/// Native status button: cached text and bounded raster work at eight fps.
final class MenuBarContent: NSObject {
    static let imageSize = NSSize(width: 264, height: 22)
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
    private var uploadPhase = 0.0
    private var downloadPhase = 0.0
    private var diskPhase = 0.0
    private var lastTick: TimeInterval?
    private var previewAppearance: NSAppearance?
    private var textSignature = ""

    var preferences = MenuBarPreferences.load() {
        didSet {
            guard preferences != oldValue else { return }
            lastTick = nil
            updateAccessibility()
            configureAnimation()
            displayFrame()
        }
    }

    init(frame: NSRect) {
        super.init()
        observe(.default, .appLanguageDidChange) { [weak self] _ in self?.updateAccessibility() }
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

    var contentWidth: CGFloat { ceil((button?.image?.size.width ?? Self.imageSize.width) + 6) }

    func update(sample: Snapshot) {
        self.sample = sample
        let signature = labels.joined(separator: "|") + "|\(sample.thermal.level)"
        if signature != textSignature || baseImage == nil {
            textSignature = signature
            rebuildBase()
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
        (validPercentage(sample.cpuUsage) ?? 0) > 0 ||
        [sample.upload, sample.download, sample.resources.disk.readBytesPerSecond, sample.resources.disk.writeBytesPerSecond].contains { (validRate($0) ?? 0) > 0 }
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
        if load > 0 { cpuPhase = (cpuPhase + elapsed / max(0.8, (3.9 - load * 0.029) / intensity)).truncatingRemainder(dividingBy: 100) }
        if let upload = validRate(sample.upload), upload > 0 { uploadPhase = (uploadPhase + elapsed / flowPeriod(upload, intensity: intensity)).truncatingRemainder(dividingBy: 1) }
        if let download = validRate(sample.download), download > 0 { downloadPhase = (downloadPhase + elapsed / flowPeriod(download, intensity: intensity)).truncatingRemainder(dividingBy: 1) }
        let diskActivity = (validRate(sample.resources.disk.readBytesPerSecond) ?? 0) + (validRate(sample.resources.disk.writeBytesPerSecond) ?? 0)
        if diskActivity > 0 {
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
        let cpu = validPercentage(sample.cpuUsage).map { String(format: "%.0f%%", $0) } ?? "—%"
        return ["CPU " + cpu, sample.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "—",
                "R " + rateLabel(sample.resources.disk.readBytesPerSecond), "W " + rateLabel(sample.resources.disk.writeBytesPerSecond),
                "↑ " + rateLabel(sample.upload), "↓ " + rateLabel(sample.download)]
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

    private func updateAccessibility() {
        guard let button else { return }
        let cpu = validPercentage(sample.cpuUsage).map { String(format: "%.0f%%", $0) } ?? L10n.text("측정 중")
        let used = ssdUsedPercent.map { String(format: "%.0f%%", $0) } ?? L10n.text("확인 불가")
        let read = rateLabel(sample.resources.disk.readBytesPerSecond)
        let write = rateLabel(sample.resources.disk.writeBytesPerSecond)
        button.toolTip = L10n.format("Mac Thermal · %@\nCPU %@ / 사용률 %@\nSSD 읽기 %@ · 쓰기 %@\nSSD 사용 용량 %@ · 온도 %@\n업로드 %@ · 다운로드 %@\n%@ · 클릭하면 패널과 메뉴바 설정",
            sample.thermal.title, temperature(sample.cpuTemperature), cpu, read, write, used,
            temperature(sample.ssdTemperature), rateLabel(sample.upload), rateLabel(sample.download), preferences.style.title)
        button.setAccessibilityLabel(L10n.format("Mac Thermal, CPU %@, 사용률 %@, SSD 읽기 %@, 쓰기 %@, 저장 공간 사용 %@, 업로드 %@, 다운로드 %@, 열 상태 %@, 메뉴바 %@",
            temperature(sample.cpuTemperature), cpu, read, write, used,
            rateLabel(sample.upload), rateLabel(sample.download), sample.thermal.title, preferences.style.title))
    }

    private func context() -> CGContext? {
        let width = Int(Self.imageSize.width * scale)
        let height = Int(Self.imageSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func rebuildBase() {
        scale = max(1, button?.window?.backingScaleFactor ?? 2)
        guard let context = context() else { return }
        let appearance = previewAppearance ?? button?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            let color = sample.thermal.level > 0 ? sample.thermal.color : NSColor.labelColor
            ink = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let lines = labels
            for (index, x, width) in [(0, CGFloat(30), CGFloat(43)), (2, 106, 59), (4, 200, 59)] {
                drawText(lines[index], at: NSPoint(x: x, y: 10.4), width: width, size: 9.3, color: color)
                drawText(lines[index + 1], at: NSPoint(x: x, y: 0.2), width: width, size: 8.6, color: color)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(color.withAlphaComponent(0.17).cgColor)
            context.fill(CGRect(x: 79.5, y: 5, width: 0.5, height: 12))
            context.fill(CGRect(x: 172.5, y: 5, width: 0.5, height: 12))
        }
        baseImage = context.makeImage()
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

    private var displayWidth: CGFloat {
        let lines = labels
        let top = (lines[4] as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.3, weight: .medium)]).width
        let bottom = (lines[5] as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.6, weight: .medium)]).width
        return min(Self.imageSize.width, max(220, ceil(200 + max(top, bottom) + 4)))
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
        context.draw(baseImage, in: CGRect(origin: .zero, size: Self.imageSize))
        let animated = motionAllowed && !systemSleeping && !displaySleeping && hasActivity
        drawCPU(in: context, phase: animated ? cpuPhase : 0)
        drawCapacity(in: context, phase: animated ? diskPhase : 0, animated: animated)
        drawFlow(in: context, x: 181, bytes: sample.upload, phase: animated ? uploadPhase : 0.45, upward: true, animated: animated)
        drawFlow(in: context, x: 190, bytes: sample.download, phase: animated ? downloadPhase : 0.45, upward: false, animated: animated)
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

    private func drawCapacity(in context: CGContext, phase: Double, animated: Bool) {
        let rect = CGRect(x: 88, y: 2, width: 13, height: 18)
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
    static func preview(sample: Snapshot, preferences: MenuBarPreferences, dark: Bool, phase: Double) -> NSImage? {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.cpuPhase = phase
        content.uploadPhase = phase
        content.downloadPhase = phase
        content.diskPhase = phase
        content.rebuildBase()
        return content.composite()
    }
}
