import AppKit
import QuartzCore

/// Native status button: cached text and bounded raster work at eight fps.
final class MenuBarContent: NSObject {
    static let imageSize = NSSize(width: 336, height: 22)
    private weak var button: NSStatusBarButton?
    private var sample = Snapshot.pending { didSet { invalidateTextInputs() } }
    private var cachedLabels: [String]?
    private var cachedSignature: String?
    private var groupInks: [CGColor] = []
    private var codexActivity = CodexMenuActivity()
    private var codexFrame = 0
    private var baseImage: CGImage?
    private struct AppearanceKey: Hashable {
        let name: String
        let scale: CGFloat
        let increasedContrast: Bool
    }
    private struct BaseRendering {
        let image: CGImage
        let ink: CGColor
        let groupInks: [CGColor]
    }
    // AppKit snapshots the same status button in several appearances. Keep the
    // text raster for each appearance instead of remeasuring/redrawing it at 8fps.
    private var baseRenderings: [AppearanceKey: BaseRendering] = [:]
    private var renderedAppearance: AppearanceKey?
    private var layoutSignature = ""
    private struct FrameKey: Hashable {
        let appearance: AppearanceKey
        let animated: Bool
        let codexPose: Int
    }
    private var frameRenderings: [FrameKey: NSImage] = [:]
    #if MENU_RENDER_PROBE
    private var baseRasterizationCount = 0
    private var labelPreparationCount = 0
    private var colorPreparationCount = 0
    #endif
    private var ink = NSColor.labelColor.cgColor
    private var scale: CGFloat = 2
    private var timer: Timer?
    private var timerInterval: TimeInterval?
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
    private var orderedMetrics: [MenuBarMetric] {
        MenuBarMetric.menuOrder.filter { preferences.visibleMetrics.contains($0) && ($0 != .codex || codexActivity.isVisible) }
    }
    private var canvasSize: NSSize { NSSize(width: displayWidth, height: Self.imageSize.height) }

    var preferences = MenuBarPreferences.load() {
        didSet {
            guard preferences != oldValue else { return }
            lastTick = nil
            frameRenderings.removeAll(keepingCapacity: true)
            if !preferences.motionEnabled || !preferences.visibleMetrics.contains(.codex) { codexActivity.cancelGesture() }
            if preferences.visibleMetrics != oldValue.visibleMetrics {
                textSignature = ""
                invalidateTextInputs()
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
            self?.appearanceChanged(force: true)
            self?.updateAccessibility()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] _ in self?.appearanceChanged(force: true) }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] _ in self?.systemSleeping = true; self?.configureAnimation() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.systemSleeping = false; self?.lastTick = nil; self?.configureAnimation() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in self?.displaySleeping = true; self?.configureAnimation() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] _ in self?.displaySleeping = false; self?.lastTick = nil; self?.appearanceChanged(force: true) }
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
        appearanceChanged(force: true)
    }

    var contentWidth: CGFloat { ceil((button?.image?.size.width ?? displayWidth) + 6) }

    func update(codex: CodexMonitorSnapshot) {
        codexActivity.receive(codex)
        codexFrame = codexActivity.frame(at: ProcessInfo.processInfo.systemUptime)
        if !motionAllowed || systemSleeping || displaySleeping || !preferences.visibleMetrics.contains(.codex) {
            codexActivity.cancelGesture()
        }
        // Metric identities in the signature cover visibility changes; token
        // updates affect the gesture/tooltip without rebuilding icon-only text.
        update(sample: sample)
    }

    func update(sample: Snapshot) {
        frameRenderings.removeAll(keepingCapacity: true)
        self.sample = sample
        let lines = labels
        let signature = signature(for: lines)
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
        timerInterval = nil
        lastTick = nil
    }

    private var motionAllowed: Bool {
        preferences.motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var hasResourceActivity: Bool {
        (preferences.visibleMetrics.contains(.cpu) && (validPercentage(sample.cpuUsage) ?? 0) > 0) ||
        (preferences.visibleMetrics.contains(.gpu) && (validPercentage(sample.resources.gpu.utilizationPercent) ?? 0) > 0) ||
        (preferences.visibleMetrics.contains(.ssd) && [sample.resources.disk.readBytesPerSecond, sample.resources.disk.writeBytesPerSecond].contains { (validRate($0) ?? 0) > 0 }) ||
        (preferences.visibleMetrics.contains(.network) && [sample.upload, sample.download].contains { (validRate($0) ?? 0) > 0 })
    }
    private var hasActivity: Bool {
        hasResourceActivity || (preferences.visibleMetrics.contains(.codex) && codexActivity.isVisible)
    }
    private func animationInterval(at uptime: TimeInterval) -> TimeInterval {
        hasResourceActivity ? CodexMenuActivity.activeFrameInterval : codexActivity.frameInterval(at: uptime)
    }

    private func configureAnimation() {
        if !motionAllowed || systemSleeping || displaySleeping { codexActivity.cancelGesture() }
        guard let window = button?.window, window.isVisible, !systemSleeping, !displaySleeping, motionAllowed, hasActivity else {
            stop()
            displayFrame()
            return
        }
        let interval = animationInterval(at: ProcessInfo.processInfo.systemUptime)
        if timer != nil, timerInterval == interval { return }
        stop()
        timerInterval = interval
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
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
        let nextCodexFrame = codexActivity.frame(at: now)
        if hasResourceActivity || codexFrame != nextCodexFrame { frameRenderings.removeAll(keepingCapacity: true) }
        codexFrame = nextCodexFrame
        if timerInterval != animationInterval(at: now) { configureAnimation() }
        displayFrame()
    }

    private var drawingAppearance: NSAppearance {
        previewAppearance ?? button?.effectiveAppearance ?? NSAppearance.currentDrawing()
    }

    private var appearanceKey: AppearanceKey {
        AppearanceKey(name: drawingAppearance.name.rawValue,
                      scale: max(1, button?.window?.backingScaleFactor ?? 2),
                      increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    private func appearanceChanged(force: Bool = false) {
        // Effective-appearance KVO also fires when the resolved appearance did
        // not change. Do not assign another image and invalidate replicants then.
        guard force || baseImage == nil || renderedAppearance != appearanceKey else { return }
        if force { invalidateTextInputs(); baseRenderings.removeAll(); frameRenderings.removeAll(keepingCapacity: true) }
        rebuildBase()
        configureAnimation()
        displayFrame()
    }

    private func invalidateTextInputs() {
        cachedLabels = nil
        cachedSignature = nil
    }

    private func signature(for lines: [String]) -> String {
        if let cachedSignature { return cachedSignature }
        let value = orderedMetrics.map(\.rawValue).joined(separator: ",") + "|" + lines.joined(separator: "|") + "|\(sample.cpuWarning.rawValue)|\(sample.gpuWarning.rawValue)|\(sample.ssdWarning.rawValue)"
        cachedSignature = value
        return value
    }

    private var labels: [String] {
        if let cachedLabels { return cachedLabels }
        #if MENU_RENDER_PROBE
        labelPreparationCount += 1
        #endif
        let value = orderedMetrics.flatMap { metric -> [String] in
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
            case .codex:
                return ["", ""]
            }
        }
        cachedLabels = value
        return value
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
                return [L10n.format("CPU %@ · 사용률 %@", temperature(sample.cpuTemperature), percent)] + (sample.cpuWarning == .normal ? [] : [sample.cpuWarning.title(for: "CPU")])
            case .gpu:
                let percent = validPercentage(sample.resources.gpu.utilizationPercent).map { String(format: "%.0f%%", $0) } ?? L10n.text("확인 불가")
                return [L10n.format("GPU 사용률 %@", percent), L10n.format("GPU 온도 %@", temperature(TemperatureWarning.valid(sample.gpuTemperature)))] + (sample.gpuWarning == .normal ? [] : [sample.gpuWarning.title(for: "GPU")])
            case .ssd:
                let used = ssdUsedPercent.map { String(format: "%.0f%%", $0) } ?? L10n.text("확인 불가")
                return [L10n.format("SSD 읽기 %@ · 쓰기 %@", rateLabel(sample.resources.disk.readBytesPerSecond), rateLabel(sample.resources.disk.writeBytesPerSecond)),
                        L10n.format("SSD 사용 용량 %@ · 온도 %@", used, temperature(sample.ssdTemperature))] + (sample.ssdWarning == .normal ? [] : [sample.ssdWarning.title(for: "SSD")])
            case .network:
                return [L10n.format("업로드 %@ · 다운로드 %@", rateLabel(sample.upload), rateLabel(sample.download))]
            case .codex:
                let state = codexActivity.tokens.map { L10n.format("%lld 토큰", $0) } ?? L10n.text("확인 불가")
                return [L10n.format("Codex · 오늘 토큰 (UTC) %@ · %@", state, codexActivity.recentLabel(now: sample.time)),
                        L10n.text("이 Mac의 로컬 기록에 남은 UTC 오늘 토큰입니다. 계정 전체 사용량이 아닙니다."),
                        L10n.text("앱 실행 중에는 천천히 움직이고 새 토큰 기록을 감지하면 10초 동안 활발하게 움직입니다. 실시간 토큰 소비·작업 완료 여부는 확인할 수 없습니다.")] +
                        (codexActivity.snapshot.incomplete && codexActivity.canShowUsage ? [L10n.text("일부 로컬 기록만 집계했습니다")] : [])
            }
        }
        if lines.isEmpty { lines = [L10n.text("표시 항목 없음 · 아이콘을 눌러 패널 열기")] }
        return lines
    }

    private func updateAccessibility() {
        guard let button else { return }
        let lines = accessibilityLines
        button.toolTip = L10n.format("Mac Thermal · macOS 열 상태 %@\n%@\n클릭하면 패널과 메뉴바 설정", sample.thermal.title, lines.joined(separator: "\n"))
        button.setAccessibilityLabel(L10n.format("Mac Thermal, macOS 열 상태 %@, %@, 클릭하면 패널과 메뉴바 설정", sample.thermal.title, lines.joined(separator: ", ")))
    }

    private func context() -> CGContext? {
        let width = Int(canvasSize.width * scale)
        let height = Int(Self.imageSize.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        return context
    }

    private func metricColor(_ metric: MenuBarMetric) -> NSColor {
        switch metric {
        case .cpu: return sample.cpuWarning.color
        case .gpu: return sample.gpuWarning.color
        case .ssd: return sample.ssdWarning.color
        default: return .labelColor
        }
    }

    private func rebuildBase(labels preparedLabels: [String]? = nil) {
        let lines = preparedLabels ?? labels
        let signature = signature(for: lines)
        if signature != layoutSignature || layoutSignature.isEmpty {
            layoutSignature = signature
            baseRenderings.removeAll()
            layout = []
            var cursor: CGFloat = 2
            for (index, metric) in orderedMetrics.enumerated() {
                if metric == .codex {
                    let width: CGFloat = 26
                    layout.append(GroupLayout(metric: metric, origin: cursor, width: width, textOffset: width, textWidth: 0))
                    cursor += width + 7
                    continue
                }
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
        }
        let key = appearanceKey
        scale = key.scale
        if let cached = baseRenderings[key] {
            baseImage = cached.image
            ink = cached.ink
            groupInks = cached.groupInks
            renderedAppearance = key
            return
        }
        drawingAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.labelColor
            ink = color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            groupInks = layout.map { group in
                let color = metricColor(group.metric)
                return color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor
            }
            #if MENU_RENDER_PROBE
            colorPreparationCount += 1
            #endif
            guard let context = context() else { baseImage = nil; return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            if layout.isEmpty { drawText("MT", at: NSPoint(x: 3, y: 5.5), width: 12, size: 9.3, color: color) }
            for (index, group) in layout.enumerated() where group.metric != .codex {
                let x = group.origin + group.textOffset
                let color = metricColor(group.metric)
                drawText(lines[index * 2], at: NSPoint(x: x, y: 10.4), width: group.textWidth, size: 9.3, color: color)
                drawText(lines[index * 2 + 1], at: NSPoint(x: x, y: 0.2), width: group.textWidth, size: 8.6, color: color)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.setFillColor(color.withAlphaComponent(0.17).cgColor)
            for group in layout.dropLast() {
                context.fill(CGRect(x: group.origin + group.width + 3.25, y: 5, width: 0.5, height: 12))
            }
            baseImage = context.makeImage()
            if let baseImage {
                // Bound memory even if a display supplies many appearance names.
                if baseRenderings.count >= 4 { baseRenderings.removeAll() }
                baseRenderings[key] = BaseRendering(image: baseImage, ink: ink, groupInks: groupInks)
                renderedAppearance = key
                #if MENU_RENDER_PROBE
                baseRasterizationCount += 1
                #endif
            }
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
        guard let button, let image = composite(), button.image !== image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        button.image = image
        CATransaction.commit()
    }

    private func composite() -> NSImage? {
        if baseImage == nil { rebuildBase() }
        guard let baseImage, let renderedAppearance else { return nil }
        let animated = motionAllowed && !systemSleeping && !displaySleeping && hasActivity
        let codexPose = animated && codexActivity.isVisible ? codexFrame : 0
        let key = FrameKey(appearance: renderedAppearance, animated: animated, codexPose: codexPose)
        if let cached = frameRenderings[key] { return cached }
        guard let context = context() else { return nil }
        context.draw(baseImage, in: CGRect(origin: .zero, size: canvasSize))
        for (index, group) in layout.enumerated() {
            context.saveGState()
            context.translateBy(x: group.origin, y: 0)
            ink = groupInks[index]
            switch group.metric {
            case .cpu: drawCPU(in: context, phase: animated ? cpuPhase : 0)
            case .gpu: drawGPU(in: context, phase: animated ? gpuPhase : 0, animated: animated)
            case .ssd: drawCapacity(in: context, phase: animated ? diskPhase : 0, animated: animated)
            case .codex:
                drawCodex(in: context, frame: codexPose)
            case .network:
                drawFlow(in: context, x: 0, bytes: sample.upload, phase: animated ? uploadPhase : 0.45, upward: true, animated: animated)
                drawFlow(in: context, x: 9, bytes: sample.download, phase: animated ? downloadPhase : 0.45, upward: false, animated: animated)
            }
            context.restoreGState()
        }
        let width = displayWidth
        guard let image = context.makeImage() else { return nil }
        let frame = NSImage(cgImage: image, size: NSSize(width: width, height: Self.imageSize.height))
        // A transient snapshot appearance may recur several times in one tick.
        // Cache only this frame, discarding it on data, preference or phase changes.
        if frameRenderings.count >= 8 { frameRenderings.removeAll(keepingCapacity: true) }
        frameRenderings[key] = frame
        return frame
    }

    /// Original 26pt robot and keyboard, drawn entirely from basic shapes.
    /// Four original typing poses cycle slowly at idle and quickly after a fresh record.
    private func drawCodex(in context: CGContext, frame: Int) {
        context.setStrokeColor(ink)
        context.setFillColor(ink)
        context.setLineWidth(1.1)
        context.setLineCap(.round)
        let head = CGRect(x: 5, y: 9, width: 16, height: 10)
        context.addPath(CGPath(roundedRect: head, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.strokePath()
        context.move(to: CGPoint(x: 13, y: 19)); context.addLine(to: CGPoint(x: 13, y: 21)); context.strokePath()
        context.fillEllipse(in: CGRect(x: 8.5, y: 13, width: 1.8, height: 2.2))
        context.fillEllipse(in: CGRect(x: 15.7, y: 13, width: 1.8, height: 2.2))
        context.move(to: CGPoint(x: 11, y: 10.8)); context.addLine(to: CGPoint(x: 15, y: 10.8)); context.strokePath()
        context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 1.5, width: 20, height: 3.5), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
        context.strokePath()
        for column in 0..<4 { context.fill(CGRect(x: 6 + Double(column) * 4, y: 2.7, width: 1.7, height: 0.8)) }
        let leftY: CGFloat = frame == 1 ? 4.2 : frame == 3 ? 6.7 : 5.5
        let rightY: CGFloat = frame == 3 ? 4.2 : frame == 1 ? 6.7 : 5.5
        context.move(to: CGPoint(x: 6, y: 9)); context.addLine(to: CGPoint(x: 7.5, y: leftY))
        context.move(to: CGPoint(x: 20, y: 9)); context.addLine(to: CGPoint(x: 18.5, y: rightY)); context.strokePath()
        context.fillEllipse(in: CGRect(x: 5.8, y: leftY - 0.7, width: 3.2, height: 1.7))
        context.fillEllipse(in: CGRect(x: 17, y: rightY - 0.7, width: 3.2, height: 1.7))
    }

    private func drawCPU(in context: CGContext, phase: Double) {
        let load = validPercentage(sample.cpuUsage) ?? 0
        let phase = load > 0 ? phase : 0
        context.setFillColor(ink)
        switch preferences.style {
        case .rhythm:
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
        case .orbit:
            let active = Int(ceil(load / 12.5))
            for index in 0..<8 {
                let angle = (Double(index) / 8 + phase) * .pi * 2
                let alpha = sample.cpuUsage == nil ? 0.25 : (index < active ? 0.35 + 0.65 * Double(index + 1) / Double(max(active, 1)) : 0.18)
                context.setFillColor(ink.copy(alpha: alpha) ?? ink)
                context.fillEllipse(in: CGRect(x: 12 + cos(angle) * 7.5 - 1.6, y: 11 + sin(angle) * 7.5 - 1.6, width: 3.2, height: 3.2))
            }
        case .wave:
            context.setStrokeColor(ink); context.setLineWidth(1.7); context.setLineCap(.round)
            let path = CGMutablePath()
            for index in 0...24 {
                let x = Double(index) + 1
                let y = 11 + sin((Double(index) / 24 - phase) * .pi * 2) * (1.2 + load * 0.055)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.addPath(path); context.strokePath()
        case .pinwheel:
            context.saveGState(); context.translateBy(x: 13, y: 11)
            context.rotate(by: phase * .pi * 2)
            let reach = 5.5 + load * 0.025
            for _ in 0..<5 {
                let blade = CGMutablePath()
                blade.move(to: CGPoint(x: 1.3, y: 0))
                blade.addQuadCurve(to: CGPoint(x: 0.4, y: reach), control: CGPoint(x: -1, y: reach * 0.65))
                blade.addQuadCurve(to: CGPoint(x: 3.4, y: reach - 1), control: CGPoint(x: 2.4, y: reach + 0.6))
                blade.addQuadCurve(to: CGPoint(x: 1.3, y: 0), control: CGPoint(x: 4, y: 2.8))
                context.addPath(blade); context.fillPath(); context.rotate(by: .pi * 2 / 5)
            }
            context.fillEllipse(in: CGRect(x: -1.4, y: -1.4, width: 2.8, height: 2.8))
            context.restoreGState()
        case .bounce:
            context.setFillColor(ink.copy(alpha: 0.18) ?? ink)
            context.fill(CGRect(x: 2, y: 2, width: 24, height: 0.7))
            context.setFillColor(ink)
            for index in 0..<3 {
                let height = abs(sin(phase * .pi * 2 + Double(index) * 0.9)) * (1.5 + load * 0.11)
                context.fillEllipse(in: CGRect(x: 3.2 + Double(index) * 8, y: 3.8 + height, width: 3.6, height: 3.6))
            }
        case .radar:
            let center = CGPoint(x: 13, y: 11), angle = phase * .pi * 2
            context.setStrokeColor(ink.copy(alpha: 0.3) ?? ink); context.setLineWidth(0.8)
            for radius in [4.0, 8.5] {
                context.strokeEllipse(in: CGRect(x: 13 - radius, y: 11 - radius, width: radius * 2, height: radius * 2))
            }
            context.setFillColor(ink.copy(alpha: 0.2 + load * 0.002) ?? ink)
            context.move(to: center)
            context.addArc(center: center, radius: 8.5, startAngle: angle - 0.8, endAngle: angle, clockwise: false)
            context.closePath(); context.fillPath()
            context.setStrokeColor(ink); context.move(to: center)
            context.addLine(to: CGPoint(x: 13 + cos(angle) * 8.5, y: 11 + sin(angle) * 8.5)); context.strokePath()
            context.setFillColor(ink); context.fillEllipse(in: CGRect(x: 15.7, y: 13, width: 2, height: 2))
        case .piston:
            context.setLineWidth(1); context.setStrokeColor(ink.copy(alpha: 0.3) ?? ink)
            for index in 0..<3 {
                let x = 2.5 + Double(index) * 8
                context.stroke(CGRect(x: x, y: 3, width: 5.5, height: 16))
                let y = 9 + sin(phase * .pi * 2 + Double(index) * .pi * 2 / 3) * (1.5 + load * 0.04)
                context.setFillColor(ink)
                context.fill(CGRect(x: x + 0.7, y: y, width: 4.1, height: 3))
                context.fill(CGRect(x: x + 2.2, y: 3, width: 1.1, height: y - 3))
            }
        case .conveyor:
            context.setStrokeColor(ink.copy(alpha: 0.3) ?? ink); context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: CGRect(x: 2.5, y: 5, width: 22, height: 12), cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.strokePath()
            let count = 2 + Int(load / 50)
            for index in 0..<count {
                let travel = (phase + Double(index) / Double(count)).truncatingRemainder(dividingBy: 1) * 58
                let point: CGPoint
                if travel < 20 { point = CGPoint(x: 3.5 + travel, y: 6) }
                else if travel < 29 { point = CGPoint(x: 23.5, y: 6 + travel - 20) }
                else if travel < 49 { point = CGPoint(x: 23.5 - (travel - 29), y: 15) }
                else { point = CGPoint(x: 3.5, y: 15 - (travel - 49)) }
                context.setFillColor(ink)
                context.fill(CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
            }
        case .hourglass:
            let progress = phase.truncatingRemainder(dividingBy: 1)
            context.setStrokeColor(ink); context.setLineWidth(1); context.setLineJoin(.round)
            context.move(to: CGPoint(x: 6, y: 19)); context.addLine(to: CGPoint(x: 20, y: 19))
            context.addLine(to: CGPoint(x: 13, y: 11)); context.addLine(to: CGPoint(x: 20, y: 3))
            context.addLine(to: CGPoint(x: 6, y: 3)); context.addLine(to: CGPoint(x: 13, y: 11))
            context.closePath(); context.strokePath()
            let topHeight = 6 * sqrt(1 - progress), bottomHeight = 6 * sqrt(progress)
            context.move(to: CGPoint(x: 13, y: 12))
            context.addLine(to: CGPoint(x: 13 - topHeight * 0.7, y: 12 + topHeight))
            context.addLine(to: CGPoint(x: 13 + topHeight * 0.7, y: 12 + topHeight))
            context.closePath(); context.fillPath()
            context.move(to: CGPoint(x: 7, y: 4)); context.addLine(to: CGPoint(x: 19, y: 4))
            context.addLine(to: CGPoint(x: 13, y: 4 + bottomHeight)); context.closePath(); context.fillPath()
            if load > 0 {
                context.setFillColor(ink.copy(alpha: 0.65) ?? ink)
                context.fill(CGRect(x: 12.6, y: 7 + (1 - progress) * 3, width: 0.8, height: 1.6))
            }
        case .pendulum:
            let angle = sin(phase * .pi * 2) * (0.15 + load * 0.006)
            let bob = CGPoint(x: 13 + sin(angle) * 12, y: 18 - cos(angle) * 12)
            context.setStrokeColor(ink); context.setLineWidth(1.2); context.setLineCap(.round)
            context.move(to: CGPoint(x: 6, y: 19.5)); context.addLine(to: CGPoint(x: 20, y: 19.5)); context.strokePath()
            context.move(to: CGPoint(x: 13, y: 18)); context.addLine(to: bob); context.strokePath()
            context.fillEllipse(in: CGRect(x: bob.x - 2.4, y: bob.y - 2.4, width: 4.8, height: 4.8))
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

    /// Deterministic paired-menu fixture; no source records, app or timer needed.
    static func previewCodex(sample: Snapshot, snapshot: CodexMonitorSnapshot,
                             preferences: MenuBarPreferences, dark: Bool, frame: Int = 0,
                             sleeping: Bool = false) -> (NSImage?, [MenuBarMetric: CGRect], String) {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        let now = ProcessInfo.processInfo.systemUptime
        var baseline = snapshot
        baseline.dailyTokens = max(0, (snapshot.dailyTokens ?? 0) - 1)
        baseline.lastRecordAt = snapshot.lastRecordAt?.addingTimeInterval(-1)
        content.codexActivity.receive(baseline, now: sample.time.addingTimeInterval(-1), uptime: now)
        content.codexActivity.receive(snapshot, now: sample.time, uptime: now)
        content.preferences = preferences
        content.systemSleeping = sleeping
        content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.codexFrame = frame
        content.rebuildBase()
        let frames = Dictionary(uniqueKeysWithValues: content.layout.map {
            ($0.metric, CGRect(x: $0.origin, y: 0, width: $0.width, height: Self.imageSize.height))
        })
        return (content.composite(), frames, content.accessibilityLines.joined(separator: "\n"))
    }

    #if MENU_RENDER_PROBE
    static func previewCodexCadence(sample: Snapshot, snapshot: CodexMonitorSnapshot,
                                    preferences: MenuBarPreferences) -> (Bool, TimeInterval) {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = preferences
        content.codexActivity.receive(snapshot)
        return (content.hasActivity, content.animationInterval(at: ProcessInfo.processInfo.systemUptime))
    }

    static func previewCodexUpdater(sample: Snapshot) -> (CodexMonitorSnapshot) -> (NSImage?, [MenuBarMetric: CGRect]) {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = MenuBarPreferences(motionEnabled: false)
        content.previewAppearance = NSAppearance(named: .aqua)
        return { snapshot in
            content.update(codex: snapshot)
            return (content.composite(), Dictionary(uniqueKeysWithValues: content.layout.map {
                ($0.metric, CGRect(x: $0.origin, y: 0, width: $0.width, height: Self.imageSize.height))
            }))
        }
    }

    static func previewPreparationCounts(sample: Snapshot) -> (Bool, Snapshot?, Bool) -> (Int, Int) {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = MenuBarPreferences()
        return { dark, replacement, force in
            content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if let replacement { content.update(sample: replacement) }
            content.appearanceChanged(force: force)
            _ = content.composite()
            return (content.labelPreparationCount, content.colorPreparationCount)
        }
    }

    /// Exercise AppKit's alternating snapshot appearances on one cached painter.
    static func previewAppearanceRenderer(sample: Snapshot) -> (Bool, Snapshot?, Bool) -> (NSImage?, Int) {
        let content = MenuBarContent(frame: .zero)
        content.sample = sample
        content.preferences = MenuBarPreferences()
        return { dark, replacement, force in
            content.previewAppearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            if let replacement { content.update(sample: replacement) }
            content.appearanceChanged(force: force)
            return (content.composite(), content.baseRasterizationCount)
        }
    }
    #endif

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
            content.frameRenderings.removeAll(keepingCapacity: true)
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
