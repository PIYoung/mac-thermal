import AppKit
import Foundation
import QuartzCore
import ObjectiveC

enum PanelColor {
    static let blue = NSColor(calibratedRed: 0.20, green: 0.48, blue: 0.96, alpha: 1)
    static let teal = NSColor(calibratedRed: 0.04, green: 0.64, blue: 0.61, alpha: 1)
    static let violet = NSColor(calibratedRed: 0.54, green: 0.39, blue: 0.88, alpha: 1)
    static let secondary = NSColor.secondaryLabelColor
    static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static let cardTop = adaptive(.white.withAlphaComponent(0.46), .white.withAlphaComponent(0.09))
    static let cardBottom = adaptive(.white.withAlphaComponent(0.18), .white.withAlphaComponent(0.035))
    static let edge = adaptive(.white.withAlphaComponent(0.86), .white.withAlphaComponent(0.18))
    static let divider = adaptive(.black.withAlphaComponent(0.07), .white.withAlphaComponent(0.10))
}

/// Original glass-style artwork on the native scroller: native hit testing,
/// dragging, paging and accessibility remain intact. No repeating animation.
final class GlassScroller: NSScroller {
    private var hovering = false
    private var dragging = false
    private var scrolling = false
    private var settleTimer: Timer?
    private var hoverTracking: NSTrackingArea?
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override var isOpaque: Bool { false }
    private var emphasized: Bool { hovering || dragging || scrolling }
    private var thumbFrame: NSRect {
        let native = rect(for: .knob)
        guard !native.isEmpty else { return .zero }
        let width: CGFloat = emphasized ? 6 : 3
        return NSRect(x: bounds.midX - width / 2, y: native.minY + 1, width: width, height: max(0, native.height - 2))
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value; needsDisplay = true
    }
    override func trackKnob(with event: NSEvent) {
        dragging = true; needsDisplay = true
        defer { dragging = false; indicateScroll() }
        super.trackKnob(with: event)
    }
    func indicateScroll() {
        guard window?.isVisible == true else { return }
        settleTimer?.invalidate()
        scrolling = true; needsDisplay = true
        let timer = Timer(timeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.scrolling = false; self?.settleTimer = nil; self?.needsDisplay = true
        }
        settleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            settleTimer?.invalidate(); settleTimer = nil
            hovering = false; dragging = false; scrolling = false
        }
    }
    deinit { settleTimer?.invalidate() }
    override func draw(_ dirtyRect: NSRect) {
        drawKnobSlot(in: bounds, highlight: emphasized)
        drawKnob()
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Keep the resting track completely transparent.
        guard emphasized else { return }
        let rail = NSRect(x: bounds.midX - 1, y: 3, width: 2, height: max(0, bounds.height - 6))
        NSColor.labelColor.withAlphaComponent(0.055).setFill()
        NSBezierPath(roundedRect: rail, xRadius: 1, yRadius: 1).fill()
    }
    override func drawKnob() {
        let thumb = thumbFrame
        guard !thumb.isEmpty else { return }
        let path = NSBezierPath(roundedRect: thumb, xRadius: thumb.width / 2, yRadius: thumb.width / 2)
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            NSColor.secondaryLabelColor.setFill(); path.fill()
        } else {
            let alpha: CGFloat = emphasized ? 0.62 : 0.30
            NSGradient(starting: PanelColor.blue.withAlphaComponent(alpha), ending: PanelColor.teal.withAlphaComponent(alpha * 0.82))?.draw(in: path, angle: 90)
            NSColor.white.withAlphaComponent(emphasized ? 0.30 : 0.15).setStroke()
            path.lineWidth = 0.5; path.stroke()
        }
    }
    #if PANEL_UPDATES_PROBE
    var probeThumbFrame: NSRect { thumbFrame }
    func probeHover(_ hovered: Bool) { setHover(hovered) }
    #endif
}

/// Keep source keys on views so a language switch updates the existing hierarchy.
private final class LocalizedTextField: NSTextField {
    let localizationKey: String
    init(_ key: String) {
        localizationKey = key
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        refreshLanguage()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func refreshLanguage() { stringValue = L10n.text(localizationKey) }
}

private var tooltipLocalizationKey: UInt8 = 0
private var accessibilityLocalizationKey: UInt8 = 0

private func localizedToolTip(_ view: NSView, _ key: String) {
    objc_setAssociatedObject(view, &tooltipLocalizationKey, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    view.toolTip = L10n.text(key)
}

private func localizedAccessibilityLabel(_ view: NSView, _ key: String) {
    objc_setAssociatedObject(view, &accessibilityLocalizationKey, key, .OBJC_ASSOCIATION_COPY_NONATOMIC)
    view.setAccessibilityLabel(L10n.text(key))
}

private func refreshLocalizedViews(_ view: NSView) {
    (view as? LocalizedTextField)?.refreshLanguage()
    if let key = objc_getAssociatedObject(view, &tooltipLocalizationKey) as? String {
        view.toolTip = L10n.text(key)
    }
    if let key = objc_getAssociatedObject(view, &accessibilityLocalizationKey) as? String {
        view.setAccessibilityLabel(L10n.text(key))
    }
    view.subviews.forEach(refreshLocalizedViews)
}

private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, digits: Bool = false) -> NSTextField {
    let field = LocalizedTextField(value)
    field.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    return field
}

private func place(_ item: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
    item.frame = NSRect(x: x, y: y, width: width, height: height)
    parent.addSubview(item)
}

private func symbol(_ name: String, color: NSColor) -> NSImageView {
    let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    image.contentTintColor = color
    image.imageScaling = .scaleProportionallyDown
    image.setAccessibilityElement(false)
    image.setAccessibilityHidden(true)
    return image
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class GlassCanvas: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PanelController.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let glow = NSGradient(colors: [PanelColor.blue.withAlphaComponent(0.14), PanelColor.blue.withAlphaComponent(0)])!
        glow.draw(fromCenter: NSPoint(x: 22, y: 20), radius: 0, toCenter: NSPoint(x: 22, y: 20), radius: 245, options: .drawsAfterEndingLocation)
        let second = NSGradient(colors: [PanelColor.violet.withAlphaComponent(0.09), PanelColor.violet.withAlphaComponent(0)])!
        second.draw(fromCenter: NSPoint(x: bounds.width, y: 160), radius: 0, toCenter: NSPoint(x: bounds.width, y: 160), radius: 205, options: .drawsAfterEndingLocation)
    }
}

class GlassCard: FlippedView {
    var radius: CGFloat = 16
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: PanelColor.cardTop, ending: PanelColor.cardBottom)?.draw(in: path, angle: 90)
        PanelColor.edge.setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }
}

final class PanelSurfaceHost: FlippedView {
    private let surfaceShadow = NSView()
    let surfaceFrame: NSRect

    init(glass: NSView, surfaceSize: NSSize = PanelController.surfaceSize) {
        let inset = PanelController.surfaceInset
        surfaceFrame = NSRect(origin: NSPoint(x: inset, y: inset), size: surfaceSize)
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: surfaceSize.width + inset * 2, height: surfaceSize.height + inset * 2)))
        wantsLayer = true
        surfaceShadow.frame = surfaceFrame
        surfaceShadow.wantsLayer = true
        if let shadow = surfaceShadow.layer {
            shadow.masksToBounds = false
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.18
            shadow.shadowRadius = 10
            shadow.shadowOffset = CGSize(width: 0, height: -3)
            shadow.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: surfaceSize), cornerWidth: PanelController.cornerRadius, cornerHeight: PanelController.cornerRadius, transform: nil)
        }
        addSubview(surfaceShadow)
        glass.frame = surfaceFrame
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0, surfaceFrame.contains(local) else { return nil }
        return super.hitTest(point)
    }
}

private final class UsageBar: FlippedView {
    var value: Double? { didSet { needsDisplay = true } }
    var color = PanelColor.blue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5)
        PanelColor.divider.setFill()
        track.fill()
        guard let value, value > 0 else { return }
        let filled = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(value, 100) / 100), height: bounds.height)
        let path = NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5)
        NSGradient(starting: color.withAlphaComponent(0.65), ending: color)?.draw(in: path, angle: 0)
    }
}

private struct ActivityHistory {
    private(set) var endTime = Date()
    private(set) var points: [(Date, Double)] = []

    mutating func append(_ value: Double?, at time: Date) {
        endTime = time
        let cutoff = time.addingTimeInterval(-60)
        points.removeAll { $0.0 < cutoff }
        if let value, value.isFinite, value >= 0 { points.append((time, value)) }
    }
}

private final class Sparkline: FlippedView {
    let color: NSColor
    var endTime = Date()
    var points: [(Date, Double)] = [] { didSet { needsDisplay = true } }
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        PanelColor.divider.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: 0, y: bounds.height - 1))
        baseline.line(to: NSPoint(x: bounds.width, y: bounds.height - 1))
        baseline.lineWidth = 0.5
        baseline.stroke()
        guard points.count >= 2 else { return }
        let highest = max(points.map(\.1).max() ?? 0, 1)
        let firstTime = endTime.addingTimeInterval(-60)
        let path = NSBezierPath()
        var last = NSPoint.zero
        for (index, sample) in points.enumerated() {
            let x = CGFloat(max(0, min(60, sample.0.timeIntervalSince(firstTime))) / 60) * bounds.width
            let y = bounds.height - 2 - CGFloat(sample.1 / highest) * (bounds.height - 4)
            let point = NSPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
            last = point
        }
        color.withAlphaComponent(0.76).setStroke()
        path.lineWidth = 1.35
        path.lineJoinStyle = .round
        path.stroke()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 1.8, y: last.y - 1.8, width: 3.6, height: 3.6)).fill()
    }
}

private final class UsageHistoryGraph: FlippedView {
    private var history = CPUUsageHistory()
    var color = PanelColor.blue { didSet { needsDisplay = true } }

    init(frame: NSRect, accessibilityKey: String) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        localizedAccessibilityLabel(self, accessibilityKey)
        localizedToolTip(self, "실제 측정값의 최근 1분 · 세로 눈금 0~100% 고정 · 빈 구간은 미측정 또는 잠자기")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func update(_ history: CPUUsageHistory, percent: Double?) {
        self.history = history
        updateAccessibility(percent)
        needsDisplay = true
    }

    func updateAccessibility(_ percent: Double?) {
        setAccessibilityValue(percent.map { L10n.format("현재 %.0f퍼센트", $0) } ?? L10n.text("측정 중"))
    }

    #if PANEL_UPDATES_PROBE
    var probeTimes: [TimeInterval] { history.points.map(\.time) }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        let plot = bounds.insetBy(dx: 2, dy: 2)
        guard plot.width > 0, plot.height > 0 else { return }
        PanelColor.divider.setStroke()
        for fraction in [CGFloat(0), 0.5, 1] {
            let grid = NSBezierPath()
            let y = plot.minY + plot.height * fraction
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.lineWidth = 0.5
            grid.stroke()
        }
        func position(_ point: CPUUsageHistory.Point) -> NSPoint {
            let x = plot.minX + CGFloat(max(0, min(60, point.time - history.endTime + 60)) / 60) * plot.width
            let y = plot.maxY - CGFloat((point.percent ?? 0) / 100) * plot.height
            return NSPoint(x: x, y: y)
        }
        for run in history.runs {
            guard let first = run.first, let last = run.last else { continue }
            let line = NSBezierPath()
            line.move(to: position(first))
            for point in run.dropFirst() { line.line(to: position(point)) }
            if run.count > 1 {
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: position(last).x, y: plot.maxY))
                area.line(to: NSPoint(x: position(first).x, y: plot.maxY))
                area.close()
                NSGradient(starting: color.withAlphaComponent(0.24), ending: color.withAlphaComponent(0.035))?.draw(in: area, angle: -90)
                color.withAlphaComponent(0.9).setStroke()
                line.lineWidth = 1.5
                line.lineJoinStyle = .round
                line.lineCapStyle = .round
                line.stroke()
            }
        }
        if let last = history.points.last, last.percent != nil {
            let point = position(last)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 1.8, y: point.y - 1.8, width: 3.6, height: 3.6)).fill()
        }
    }
}

private final class ResourceBadge: FlippedView {
    private let label = text("정보 없음", size: 10, weight: .semibold)
    private var color: NSColor = .secondaryLabelColor
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        label.frame = NSRect(x: 8, y: (bounds.height - 15) / 2, width: bounds.width - 16, height: 15)
    }
    func update(_ title: String, color: NSColor) {
        label.stringValue = title
        label.textColor = color
        self.color = color
        setAccessibilityLabel(title)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        color.withAlphaComponent(0.10).setFill()
        path.fill()
        color.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 0.7
        path.stroke()
    }
}

private final class ProcessRankingCard: GlassCard {
    private let names = (0..<3).map { _ in text("", size: 11, weight: .medium) }
    private let values = (0..<3).map { _ in text("", size: 11, weight: .semibold, digits: true) }
    private let ranks = (1...3).map { text(String($0), size: 10, weight: .semibold, color: PanelColor.secondary, digits: true) }
    private let empty = text("측정 중", size: 11, color: PanelColor.secondary)
    private let count = text("정보 없음", size: 8, color: PanelColor.secondary)

    init(title: String, subtitle: String, icon: String, accent: NSColor) {
        super.init(frame: .zero)
        place(symbol(icon, color: accent), in: self, 12, 9, 13, 13)
        place(text(title, size: 11, weight: .semibold), in: self, 32, 7, 162, 17)
        let note = text(subtitle, size: 9, color: PanelColor.secondary)
        note.alignment = .right
        place(note, in: self, 200, 9, 94, 14)
        for index in 0..<3 {
            let y = CGFloat(31 + index * 23)
            ranks[index].alignment = .center
            place(ranks[index], in: self, 10, y + 1, 16, 16)
            place(names[index], in: self, 33, y, 157, 18)
            values[index].alignment = .right
            place(values[index], in: self, 196, y, 98, 18)
            if index < 2 {
                let separator = NSBox()
                separator.boxType = .separator
                place(separator, in: self, 33, y + 21, 261, 1)
            }
        }
        place(empty, in: self, 14, 54, 280, 18)
        place(count, in: self, 14, 104, 280, 12)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func update(_ processes: [ResourceProcess], emptyMessage: String, countText: String, detail: String, format: (ResourceProcess) -> String) {
        empty.isHidden = !processes.isEmpty
        empty.stringValue = emptyMessage
        count.stringValue = countText
        toolTip = detail
        for index in 0..<3 {
            let process = index < processes.count ? processes[index] : nil
            ranks[index].isHidden = process == nil
            names[index].isHidden = process == nil
            values[index].isHidden = process == nil
            if let process {
                names[index].stringValue = process.name
                names[index].toolTip = "\(process.name) · PID \(process.pid)"
                values[index].stringValue = format(process)
                names[index].setAccessibilityLabel(L10n.format("%d위 %@, PID %d", index + 1, process.name, process.pid))
            }
        }
    }
    #if PANEL_UPDATES_PROBE
    var probeCount: String { count.stringValue }
    var probeRows: [String] {
        zip(names, values).filter { !$0.0.isHidden }.map { $0.0.stringValue + " · " + $0.1.stringValue }
    }
    #endif
}

// UI state only: the monitor owns consent persistence and record-reader lifetime.
enum CodexRecordsSettingsState: Equatable {
    case disabled, reading, partial, ready, unavailable
    var enabled: Bool { self != .disabled }
    var titleKey: String {
        switch self {
        case .disabled: return "꺼짐 · 기본값"
        case .reading: return "로컬 기록 확인 중"
        case .partial: return "일부 기록만 집계"
        case .ready: return "읽기 전용 · 외부 전송 없음"
        case .unavailable: return "로컬 기록을 읽을 수 없습니다"
        }
    }
}

final class PanelController: NSViewController {
    static let surfaceSize = NSSize(width: 340, height: 420)
    static let surfaceInset: CGFloat = 24
    static let size = NSSize(width: surfaceSize.width + 2 * surfaceInset, height: surfaceSize.height + 2 * surfaceInset)
    static let cornerRadius: CGFloat = 22

    private let cpuTemp = text("—", size: 18, weight: .medium, digits: true)
    private let ssdTemp = text("—", size: 18, weight: .medium, digits: true)
    private let cpuPercent = text("측정 중", size: 30, weight: .medium, digits: true)
    private let cpuGraph = UsageHistoryGraph(frame: .zero, accessibilityKey: "CPU 사용률 최근 1분 그래프, 세로 눈금 0에서 100퍼센트")
    private let gpuPercent = text("정보 없음", size: 30, weight: .medium, digits: true)
    private let gpuGraph = UsageHistoryGraph(frame: .zero, accessibilityKey: "GPU 사용률 최근 1분 그래프, 세로 눈금 0에서 100퍼센트")
    private let gpuModel = text("정보 없음", size: 19, weight: .medium)
    private let gpuCores = text("정보 없음", size: 19, weight: .medium, digits: true)
    private let gpuDetail = text("이 Mac에서 GPU 사용률을 읽을 수 없습니다", size: 9, color: PanelColor.secondary)
    private let uptimeLabel = text("부팅 후 시간 확인 중", size: 10, color: PanelColor.secondary, digits: true)
    private let upValue = text("—", size: 20, weight: .medium, digits: true)
    private let downValue = text("—", size: 20, weight: .medium, digits: true)
    private let upGraph = Sparkline(color: PanelColor.blue)
    private let downGraph = Sparkline(color: PanelColor.teal)
    private let thermalDetail = text("macOS 열 상태 확인 중", size: 10, color: PanelColor.secondary)
    private let updated = text("측정 준비 중", size: 10, color: .tertiaryLabelColor)
    private let loginLabel = text("", size: 10, color: PanelColor.secondary)

    private let memoryUsed = text("—", size: 31, weight: .medium, digits: true)
    private let memoryTotal = text("전체 용량 정보 없음", size: 11, color: PanelColor.secondary)
    private let memoryPercent = text("—", size: 11, weight: .semibold, digits: true)
    private let memoryBar = UsageBar()
    private let memoryPressure = ResourceBadge(frame: .zero)
    private let memoryCompressed = text("—", size: 17, weight: .medium, digits: true)
    private let memorySwap = text("—", size: 17, weight: .medium, digits: true)
    private let cpuRanking = ProcessRankingCard(title: "CPU 프로세스 TOP 3", subtitle: "전체 CPU 기준", icon: "cpu", accent: PanelColor.blue)
    private let memoryRanking = ProcessRankingCard(title: "메모리 프로세스 TOP 3", subtitle: "실제 점유 메모리", icon: "memorychip", accent: PanelColor.violet)
    private let diskFree = text("—", size: 31, weight: .medium, digits: true)
    private let diskCapacity = text("전체 용량 정보 없음", size: 11, color: PanelColor.secondary)
    private let diskBar = UsageBar()
    private let diskMonitorView = FlippedView()
    private var diskCleanupView: DiskCleanupView?
    private lazy var diskCleanupButton: NSButton = {
        let button = NSButton(title: L10n.text("디스크 정리"), target: self, action: #selector(openDiskCleanup))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 10, weight: .medium)
        localizedAccessibilityLabel(button, "디스크 정리")
        localizedToolTip(button, "홈 폴더를 자동 검사하고 선택한 파일만 확인 후 휴지통으로 이동합니다")
        return button
    }()
    private let diskRead = text("측정 중", size: 20, weight: .medium, digits: true)
    private let diskWrite = text("측정 중", size: 20, weight: .medium, digits: true)
    private let diskReadGraph = Sparkline(color: PanelColor.blue)
    private let diskWriteGraph = Sparkline(color: PanelColor.violet)
    private var tabViews: [NSView] = []
    private let menuBarSettingsView = FlippedView()
    private let settingsScroll = NSScrollView()
    private let settingsScroller = GlassScroller()
    private var settingsScrollObserver: NSObjectProtocol?
    private var codexRecordsState = CodexRecordsSettingsState.disabled
    private let codexRecordsStatus = text("꺼짐 · 기본값", size: 9, color: PanelColor.secondary)
    private lazy var codexRecordsSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(changeCodexRecords)
        control.controlSize = .small
        localizedAccessibilityLabel(control, "로컬 기록 읽기")
        localizedToolTip(control, "켜면 이 Mac의 Codex 대화 기록 파일에서 모델명·토큰 숫자·시각을 추출해 집계합니다. 끄면 읽기를 중단하며 본문은 보관·표시·전송하지 않습니다.")
        return control
    }()
    var codexRecordsEnabledChanged: ((Bool) -> Void)?

    func updateCodexRecords(_ state: CodexRecordsSettingsState) {
        guard codexRecordsState != state else { return }
        codexRecordsState = state
        if isViewLoaded { renderCodexRecordsSetting() }
    }

    private func renderCodexRecordsSetting() {
        codexRecordsSwitch.state = codexRecordsState.enabled ? .on : .off
        codexRecordsStatus.stringValue = L10n.text(codexRecordsState.titleKey)
        codexRecordsStatus.textColor = [.partial, .unavailable].contains(codexRecordsState) ? .systemOrange : PanelColor.secondary
        codexRecordsStatus.toolTip = codexRecordsState == .partial ? L10n.text("검사 범위나 읽기 제한 때문에 일부 기록만 집계했습니다. 표시값은 전체 사용량이 아닙니다.") : codexRecordsStatus.stringValue
    }

    @objc private func changeCodexRecords() {
        let enabled = codexRecordsSwitch.state == .on
        guard codexRecordsState.enabled != enabled else { return }
        updateCodexRecords(enabled ? .reading : .disabled)
        codexRecordsEnabledChanged?(enabled)
    }

    private var resetNotificationsEnabled = false
    private var resetNotificationsStatusKey = "꺼짐 · 기본값"
    private var resetNotificationsRequesting = false
    private let resetNotificationsStatus = text("꺼짐 · 기본값", size: 9, color: PanelColor.secondary)
    private lazy var resetNotificationsSwitch: NSSwitch = {
        let control = NSSwitch(); control.controlSize = .small
        control.target = self; control.action = #selector(changeResetNotifications)
        localizedAccessibilityLabel(control, "한도 리셋 알림")
        return control
    }()
    var codexResetNotificationsChanged: ((Bool) -> Void)?
    func updateCodexResetNotifications(enabled: Bool, statusKey: String, requesting: Bool) {
        resetNotificationsEnabled = enabled; resetNotificationsStatusKey = statusKey
        resetNotificationsRequesting = requesting
        if isViewLoaded { renderResetNotificationsSetting() }
    }
    private func renderResetNotificationsSetting() {
        resetNotificationsSwitch.state = resetNotificationsEnabled ? .on : .off
        resetNotificationsSwitch.isEnabled = !resetNotificationsRequesting
        resetNotificationsStatus.stringValue = L10n.text(resetNotificationsStatusKey)
        resetNotificationsStatus.toolTip = resetNotificationsStatus.stringValue
    }
    @objc private func changeResetNotifications() {
        let enabled = resetNotificationsSwitch.state == .on
        guard enabled != resetNotificationsEnabled else { return }
        codexResetNotificationsChanged?(enabled)
    }

    private var showingMenuBarSettings = false
    private var languageObserver: NSObjectProtocol?
    private var latestSnapshot = Snapshot.pending
    // Histories continue collecting while the panel or their tab is hidden.
    // Updating the AppKit views is deferred until they will actually be shown.
    private var cpuHistory = CPUUsageHistory()
    private var gpuHistory = CPUUsageHistory()
    private var uploadHistory = ActivityHistory()
    private var downloadHistory = ActivityHistory()
    private var diskReadHistory = ActivityHistory()
    private var diskWriteHistory = ActivityHistory()
    #if PANEL_UPDATES_PROBE
    private var probeVisible = false
    #endif

    private var presentationIsVisible: Bool {
        #if PANEL_UPDATES_PROBE
        return probeVisible
        #else
        return view.window?.isVisible == true
        #endif
    }
    private var menuBarPreferences: MenuBarPreferences
    private var updatingMenuBarControls = false
    private let motionIntensityValue = text("1.20×", size: 11, weight: .semibold, digits: true)
    private lazy var menuBarSettingsButton: NSButton = {
        let button = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(toggleMenuBarSettings))
        button.isBordered = false
        button.contentTintColor = PanelColor.secondary
        localizedToolTip(button, "설정")
        localizedAccessibilityLabel(button, "Mac Thermal 설정 열기")
        return button
    }()
    private lazy var animationStyleControl: NSPopUpButton = {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: [MenuBarAnimationStyle.rhythm.title, MenuBarAnimationStyle.orbit.title])
        control.target = self
        control.action = #selector(changeMenuBarPreferences)
        control.controlSize = .regular
        localizedAccessibilityLabel(control, "CPU 애니메이션 스타일")
        localizedToolTip(control, "리듬 막대 또는 순환 점으로 CPU가 바쁜 정도를 표시합니다")
        return control
    }()
    private lazy var metricControls: [MenuBarMetric: NSButton] = {
        Dictionary(uniqueKeysWithValues: MenuBarMetric.allCases.map { metric in
            let control = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(changeMenuBarPreferences))
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11)
            localizedAccessibilityLabel(control, metric == .network ? "네트워크" : metric.title)
            localizedToolTip(control, "메뉴바에 표시할 항목을 선택합니다")
            return (metric, control)
        })
    }()
    private lazy var menuBarMotionSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(changeMenuBarPreferences)
        control.controlSize = .small
        localizedAccessibilityLabel(control, "메뉴바 움직임")
        localizedToolTip(control, "끄면 메뉴바 아이콘을 정지된 상태로 표시합니다")
        return control
    }()
    private lazy var motionIntensitySlider: NSSlider = {
        let control = NSSlider(value: 1.2, minValue: 0.75, maxValue: 1.5, target: self, action: #selector(changeMenuBarPreferences))
        control.isContinuous = true
        control.controlSize = .small
        localizedAccessibilityLabel(control, "메뉴바 움직임 강도")
        localizedToolTip(control, "움직임의 강도만 바뀌며 측정된 숫자는 그대로 유지됩니다")
        return control
    }()
    private lazy var languageControl: NSPopUpButton = {
        let control = NSPopUpButton(frame: .zero, pullsDown: false)
        control.addItems(withTitles: AppLanguage.allCases.map(\.nativeName))
        control.target = self
        control.action = #selector(changeLanguage)
        control.controlSize = .regular
        localizedAccessibilityLabel(control, "언어")
        localizedToolTip(control, "선택한 언어를 바로 적용하고 다음 실행에도 유지합니다")
        return control
    }()
    private let tabDefaults: UserDefaults
    private let tabDefaultsKey = "dashboardSelectedResourceTabV4"
    private static let tabIdentifiers = ["cpu", "gpu", "memory", "ssd", "network"]
    private static let tabLabels = ["CPU", "GPU", "메모리", "SSD", "통신"]
    init(defaults: UserDefaults = .standard) {
        tabDefaults = defaults
        menuBarPreferences = .load(defaults: defaults)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) {
        tabDefaults = .standard
        menuBarPreferences = .load()
        super.init(coder: coder)
    }
    private func restoredTab() -> Int {
        if tabDefaults.object(forKey: tabDefaultsKey) != nil {
            return Self.tabIdentifiers.firstIndex(of: tabDefaults.string(forKey: tabDefaultsKey) ?? "") ?? 0
        }
        let migrated: Int
        if tabDefaults.object(forKey: "dashboardSelectedResourceTabV3") != nil {
            migrated = [0: 0, 1: 2, 2: 3, 3: 4][tabDefaults.integer(forKey: "dashboardSelectedResourceTabV3")] ?? 0
        } else {
            let legacy = tabDefaults.integer(forKey: "dashboardSelectedTabV2")
            migrated = [0: 0, 1: 2, 2: 0, 3: 3][legacy] ?? 0
        }
        tabDefaults.set(Self.tabIdentifiers[migrated], forKey: tabDefaultsKey)
        return migrated
    }
    private lazy var tabs: LiquidTabControl = {
        let control = LiquidTabControl(labels: Self.tabLabels.map(L10n.text), target: self, action: #selector(changeTab))
        localizedAccessibilityLabel(control, "시스템 모니터 탭")
        control.selectedSegment = restoredTab()
        return control
    }()
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private lazy var loginSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(toggleLogin)
        control.controlSize = .small
        localizedAccessibilityLabel(control, "로그인 시 자동 실행")
        return control
    }()
    var refresh: (() -> Void)?
    var menuBarPreferencesChanged: ((MenuBarPreferences) -> Void)?

    override func loadView() {
        let canvas = GlassCanvas(frame: NSRect(origin: .zero, size: Self.surfaceSize))
        canvas.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: canvas.bounds)
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = canvas
            view = PanelSurfaceHost(glass: glass)
        } else {
            let glass = NSVisualEffectView(frame: canvas.bounds)
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = Self.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.addSubview(canvas)
            view = PanelSurfaceHost(glass: glass)
        }
        preferredContentSize = Self.size

        let brand = NSImageView()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            brand.image = NSImage(contentsOf: iconURL)
        }
        brand.imageScaling = .scaleProportionallyDown
        brand.setAccessibilityElement(false)
        place(brand, in: canvas, 16, 13, 30, 30)
        place(text("Mac Thermal", size: 15, weight: .semibold), in: canvas, 54, 11, 226, 20)
        place(uptimeLabel, in: canvas, 54, 32, 226, 14)
        localizedToolTip(uptimeLabel, "잠자기 시간을 포함한 부팅 후 경과 시간 · 1분 단위")
        place(menuBarSettingsButton, in: canvas, 300, 16, 24, 24)
        place(tabs, in: canvas, 16, 55, 308, 24)
        tabViews = Self.tabIdentifiers.map { _ in
            let content = FlippedView()
            content.wantsLayer = true
            place(content, in: canvas, 16, 88, 308, 277)
            return content
        }
        buildCPU(in: tabViews[0])
        buildGPU(in: tabViews[1])
        buildMemory(in: tabViews[2])
        place(diskMonitorView, in: tabViews[3], 0, 0, 308, 277)
        buildDisk(in: diskMonitorView)
        buildNetwork(in: tabViews[4])
        settingsScroll.drawsBackground = false
        settingsScroll.hasVerticalScroller = true
        settingsScroll.autohidesScrollers = true
        settingsScroll.verticalScroller = settingsScroller
        settingsScroll.scrollerStyle = .legacy
        place(settingsScroll, in: canvas, 16, 55, 308, 310)
        // Share the Codex thumb style while retaining a stable native hit lane.
        menuBarSettingsView.frame = NSRect(x: 0, y: 0, width: 290, height: 472)
        settingsScroll.documentView = menuBarSettingsView
        settingsScroll.contentView.postsBoundsChangedNotifications = true
        settingsScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: settingsScroll.contentView, queue: .main) { [weak self] _ in self?.settingsScroller.indicateScroll() }
        buildMenuBarSettings()
        showSelectedTab()

        let footerLine = NSBox()
        footerLine.boxType = .separator
        place(footerLine, in: canvas, 16, 379, 308, 1)
        place(updated, in: canvas, 17, 388, 238, 15)
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.text("새로고침")) ?? NSImage(), target: self, action: #selector(refreshNow))
        let quitButton = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: L10n.text("종료")) ?? NSImage(), target: self, action: #selector(quitApp))
        for (button, title, x) in [(refreshButton, "지금 새로고침", CGFloat(267)), (quitButton, "Mac Thermal 종료", CGFloat(300))] {
            button.isBordered = false
            button.contentTintColor = PanelColor.secondary
            localizedToolTip(button, title)
            localizedAccessibilityLabel(button, title)
            place(button, in: canvas, x, 385, 21, 21)
        }
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLanguage()
        }
        apply(latestSnapshot, recordHistory: false)
        refreshLanguage()
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let settingsScrollObserver { NotificationCenter.default.removeObserver(settingsScrollObserver) }
    }

    private func refreshLanguage() {
        guard isViewLoaded else { return }
        refreshLocalizedViews(view)
        tabs.updateLabels(Self.tabLabels.map(L10n.text))
        animationStyleControl.removeAllItems()
        animationStyleControl.addItems(withTitles: [MenuBarAnimationStyle.rhythm.title, MenuBarAnimationStyle.orbit.title])
        for metric in MenuBarMetric.allCases { metricControls[metric]?.title = metric.title }
        diskCleanupButton.title = L10n.text("디스크 정리")
        diskCleanupView?.refreshLanguage()
        languageControl.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.language) ?? 0)
        updateMenuBarControls()
        renderCodexRecordsSetting()
        renderResetNotificationsSetting()
        showSelectedTab()
        updateLoginState()
    }

    @objc private func changeLanguage() {
        let index = languageControl.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        L10n.setLanguage(AppLanguage.allCases[index])
    }

    private func buildMenuBarSettings() {
        let language = GlassCard()
        place(language, in: menuBarSettingsView, 0, 0, 290, 40)
        place(symbol("globe", color: PanelColor.blue), in: language, 13, 13, 14, 14)
        place(text("언어", size: 11, weight: .semibold), in: language, 34, 11, 66, 18)
        place(languageControl, in: language, 107, 6, 170, 28)

        let records = GlassCard()
        place(records, in: menuBarSettingsView, 0, 46, 290, 78)
        place(symbol("terminal", color: PanelColor.blue), in: records, 13, 10, 14, 14)
        place(text("로컬 기록 읽기", size: 11, weight: .semibold), in: records, 34, 8, 200, 18)
        place(codexRecordsSwitch, in: records, 242, 7, 36, 22)
        let privacy = text("대화 기록 파일에서 추출 · 본문 저장·표시·전송 없음", size: 9, color: PanelColor.secondary)
        privacy.maximumNumberOfLines = 2
        privacy.lineBreakMode = .byWordWrapping
        place(privacy, in: records, 14, 31, 262, 27)
        localizedToolTip(records, "이 Mac의 Codex 대화 기록 파일에서 모델명·토큰 숫자·시각만 추출해 집계합니다. 본문은 보관·표시·전송하지 않습니다.")
        place(codexRecordsStatus, in: records, 14, 60, 262, 14)
        renderCodexRecordsSetting()

        let alerts = GlassCard()
        place(alerts, in: menuBarSettingsView, 0, 130, 290, 78)
        place(symbol("bell.badge", color: PanelColor.blue), in: alerts, 13, 10, 14, 14)
        place(text("한도 리셋 알림", size: 11, weight: .semibold), in: alerts, 34, 8, 200, 18)
        place(resetNotificationsSwitch, in: alerts, 242, 7, 36, 22)
        let notice = text("계정 한도 연결 후 사용 · 잠금화면에 표시될 수 있음", size: 9, color: PanelColor.secondary)
        notice.maximumNumberOfLines = 2; notice.lineBreakMode = .byWordWrapping
        place(notice, in: alerts, 14, 31, 262, 27)
        place(resetNotificationsStatus, in: alerts, 14, 60, 262, 14)
        localizedToolTip(alerts, "앱 실행 중 한도 갱신을 확인하면 알립니다. 끄면 이 앱의 리셋 알림을 중지하고 지웁니다. 추가 조회·외부 전송은 없습니다.")
        renderResetNotificationsSetting()

        let metrics = GlassCard()
        place(metrics, in: menuBarSettingsView, 0, 214, 290, 50)
        place(symbol("menubar.rectangle", color: PanelColor.blue), in: metrics, 13, 7, 14, 14)
        place(text("메뉴바 표시", size: 11, weight: .semibold), in: metrics, 34, 5, 242, 18)
        for (index, metric) in MenuBarMetric.allCases.enumerated() {
            guard let control = metricControls[metric] else { continue }
            let origins: [CGFloat] = [11, 55, 99, 143, 224]
            let widths: [CGFloat] = [44, 44, 44, 81, 57]
            place(control, in: metrics, origins[index], 26, widths[index], 20)
            if metric == .codex { localizedToolTip(control, "Codex 앱 실행 중에만 표시합니다. 새 토큰 기록이 들어오면 움직입니다.") }
        }

        let style = GlassCard()
        place(style, in: menuBarSettingsView, 0, 270, 290, 46)
        place(symbol("waveform", color: PanelColor.blue), in: style, 13, 5, 14, 14)
        place(text("CPU 애니메이션 스타일", size: 11, weight: .semibold), in: style, 34, 3, 242, 18)
        place(animationStyleControl, in: style, 11, 20, 268, 26)

        let motion = GlassCard()
        place(motion, in: menuBarSettingsView, 0, 322, 290, 40)
        place(text("메뉴바 움직임", size: 11, weight: .semibold), in: motion, 14, 11, 220, 18)
        place(menuBarMotionSwitch, in: motion, 242, 9, 36, 22)
        localizedToolTip(motion, "CPU·GPU는 사용률 · 네트워크는 전송량 · SSD는 읽기/쓰기")
        localizedToolTip(menuBarMotionSwitch, "macOS ‘동작 줄이기’가 켜지면 움직임을 멈춥니다")

        let intensity = GlassCard()
        place(intensity, in: menuBarSettingsView, 0, 368, 290, 58)
        place(text("움직임 강도", size: 11, weight: .semibold), in: intensity, 14, 3, 200, 18)
        motionIntensityValue.alignment = .right
        place(motionIntensityValue, in: intensity, 226, 4, 50, 17)
        place(motionIntensitySlider, in: intensity, 13, 22, 264, 18)
        place(text("차분하게", size: 9, color: PanelColor.secondary), in: intensity, 15, 41, 130, 13)
        let energetic = text("활기차게", size: 9, color: PanelColor.secondary)
        energetic.alignment = .right
        place(energetic, in: intensity, 146, 41, 130, 13)

        let login = GlassCard()
        place(login, in: menuBarSettingsView, 0, 432, 290, 40)
        place(text("로그인 시 자동 실행", size: 11, weight: .semibold), in: login, 14, 11, 150, 18)
        loginLabel.alignment = .right
        loginLabel.font = .systemFont(ofSize: 9)
        place(loginLabel, in: login, 170, 12, 58, 16)
        place(loginSwitch, in: login, 242, 9, 36, 22)
        localizedToolTip(menuBarSettingsView, "설정은 바로 적용되고 다음 실행에도 유지돼요")
        updateMenuBarControls()
    }

    private func updateMenuBarControls() {
        updatingMenuBarControls = true
        defer { updatingMenuBarControls = false }
        animationStyleControl.selectItem(at: menuBarPreferences.style.rawValue)
        animationStyleControl.isEnabled = menuBarPreferences.visibleMetrics.contains(.cpu)
        for metric in MenuBarMetric.allCases {
            metricControls[metric]?.state = menuBarPreferences.visibleMetrics.contains(metric) ? .on : .off
        }
        menuBarMotionSwitch.state = menuBarPreferences.motionEnabled ? .on : .off
        menuBarMotionSwitch.isEnabled = !menuBarPreferences.visibleMetrics.isEmpty
        motionIntensitySlider.doubleValue = menuBarPreferences.intensity
        motionIntensitySlider.isEnabled = menuBarPreferences.motionEnabled && !menuBarPreferences.visibleMetrics.isEmpty
        motionIntensityValue.stringValue = String(format: "%.2f×", menuBarPreferences.intensity)
        motionIntensityValue.textColor = motionIntensitySlider.isEnabled ? .labelColor : PanelColor.secondary
    }

    @objc private func changeMenuBarPreferences() {
        guard !updatingMenuBarControls,
              let style = MenuBarAnimationStyle(rawValue: animationStyleControl.indexOfSelectedItem) else { return }
        let visibleMetrics = Set(MenuBarMetric.allCases.filter { metricControls[$0]?.state == .on })
        let preferences = MenuBarPreferences(style: style, motionEnabled: menuBarMotionSwitch.state == .on, intensity: motionIntensitySlider.doubleValue, visibleMetrics: visibleMetrics)
        guard preferences != menuBarPreferences else { return }
        menuBarPreferences = preferences
        menuBarPreferences.save(defaults: tabDefaults)
        updateMenuBarControls()
        menuBarPreferencesChanged?(menuBarPreferences)
    }

    @objc private func toggleMenuBarSettings() {
        showingMenuBarSettings.toggle()
        if showingMenuBarSettings {
            menuBarPreferences = .load(defaults: tabDefaults)
            updateMenuBarControls()
            updateLoginState()
        }
        showSelectedTab()
    }

    private func buildCPU(in content: NSView) {
        let usage = GlassCard()
        place(usage, in: content, 0, 0, 308, 106)
        place(symbol("cpu", color: PanelColor.blue), in: usage, 13, 12, 13, 13)
        place(text("CPU 사용률", size: 11, weight: .semibold), in: usage, 33, 9, 140, 17)
        place(text("최근 1분 · 0–100%", size: 9, color: PanelColor.secondary), in: usage, 14, 29, 160, 14)
        cpuPercent.alignment = .right
        place(cpuPercent, in: usage, 177, 5, 115, 38)
        place(cpuGraph, in: usage, 14, 53, 280, 43)

        let thermal = GlassCard()
        place(thermal, in: content, 0, 113, 308, 36)
        place(text("온도", size: 10, weight: .medium, color: PanelColor.secondary), in: thermal, 13, 10, 43, 16)
        place(cpuTemp, in: thermal, 57, 4, 72, 26)
        thermalDetail.alignment = .right
        place(thermalDetail, in: thermal, 133, 10, 161, 16)
        place(cpuRanking, in: content, 0, 157, 308, 120)
    }

    private func buildGPU(in content: NSView) {
        let usage = GlassCard()
        place(usage, in: content, 0, 0, 308, 158)
        place(symbol("square.grid.3x3.fill", color: PanelColor.violet), in: usage, 13, 12, 13, 13)
        place(text("GPU 사용률", size: 11, weight: .semibold), in: usage, 33, 9, 140, 17)
        place(text("최근 1분 · 0–100%", size: 9, color: PanelColor.secondary), in: usage, 14, 29, 160, 14)
        gpuPercent.alignment = .right
        place(gpuPercent, in: usage, 177, 5, 115, 38)
        gpuGraph.color = PanelColor.violet
        place(gpuGraph, in: usage, 14, 52, 280, 70)
        place(gpuDetail, in: usage, 14, 136, 280, 14)

        let hardware = GlassCard()
        place(hardware, in: content, 0, 165, 308, 112)
        place(text("GPU 모델", size: 10, weight: .medium, color: PanelColor.secondary), in: hardware, 14, 9, 280, 16)
        place(gpuModel, in: hardware, 13, 29, 281, 26)
        let divider = NSBox()
        divider.boxType = .separator
        place(divider, in: hardware, 14, 65, 280, 1)
        place(text("GPU 코어", size: 10, weight: .medium, color: PanelColor.secondary), in: hardware, 14, 85, 130, 16)
        gpuCores.alignment = .right
        place(gpuCores, in: hardware, 151, 78, 143, 28)
    }

    private func buildMemory(in content: NSView) {
        let capacity = GlassCard()
        place(capacity, in: content, 0, 0, 308, 106)
        place(symbol("memorychip", color: PanelColor.violet), in: capacity, 13, 13, 14, 14)
        place(text("사용 중인 메모리", size: 11, weight: .semibold), in: capacity, 34, 11, 161, 18)
        place(memoryPressure, in: capacity, 201, 9, 94, 23)
        place(memoryUsed, in: capacity, 12, 31, 218, 40)
        memoryPercent.alignment = .right
        place(memoryPercent, in: capacity, 236, 43, 58, 18)
        place(memoryTotal, in: capacity, 15, 77, 278, 16)
        place(memoryBar, in: capacity, 14, 94, 280, 5)
        localizedToolTip(memoryUsed, "활성·비활성·고정 메모리와 압축 메모리에서 파일 캐시·회수 가능한 페이지를 제외한 추정 사용량입니다.")

        let secondary = GlassCard()
        place(secondary, in: content, 0, 113, 308, 36)
        for (x, title, field, note) in [
            (CGFloat(13), "압축 메모리", memoryCompressed, "RAM 안에서 압축한 크기"),
            (CGFloat(167), "스왑 사용량", memorySwap, "SSD에 옮겨 둔 메모리")
        ] {
            place(text(title, size: 9, weight: .medium, color: PanelColor.secondary), in: secondary, x, 2, 126, 13)
            place(field, in: secondary, x - 1, 15, 127, 21)
            localizedToolTip(field, note)
        }
        let divider = NSBox()
        divider.boxType = .separator
        place(divider, in: secondary, 153, 7, 1, 22)
        place(memoryRanking, in: content, 0, 157, 308, 120)
    }

    private func buildDisk(in content: NSView) {
        let capacity = GlassCard()
        place(capacity, in: content, 0, 0, 308, 106)
        place(symbol("internaldrive", color: PanelColor.violet), in: capacity, 13, 13, 14, 14)
        place(text("내장 SSD", size: 11, weight: .semibold), in: capacity, 34, 11, 148, 18)
        place(diskCleanupButton, in: capacity, 190, 7, 105, 25)
        place(diskFree, in: capacity, 12, 31, 283, 36)
        place(diskBar, in: capacity, 14, 76, 280, 5)
        place(diskCapacity, in: capacity, 15, 88, 278, 14)
        localizedToolTip(capacity, "시동 볼륨의 전체 용량과 현재 사용 가능한 공간입니다. APFS 공유 공간에 따라 값이 바뀔 수 있습니다.")

        let activity = GlassCard()
        place(activity, in: content, 0, 113, 308, 128)
        place(symbol("arrow.up.arrow.down", color: PanelColor.secondary), in: activity, 13, 10, 13, 13)
        place(text("디스크 활동", size: 11, weight: .semibold), in: activity, 32, 8, 160, 17)
        let recent = text("최근 1분", size: 9, color: PanelColor.secondary)
        recent.alignment = .right
        place(recent, in: activity, 202, 10, 92, 14)
        for (x, title, field, graph, color) in [
            (CGFloat(14), "↓  읽기", diskRead, diskReadGraph, PanelColor.blue),
            (CGFloat(168), "↑  쓰기", diskWrite, diskWriteGraph, PanelColor.violet)
        ] {
            place(text(title, size: 10, weight: .medium, color: color), in: activity, x, 32, 126, 15)
            place(field, in: activity, x - 2, 47, 128, 28)
            place(graph, in: activity, x, 83, 126, 30)
        }
        let divider = NSBox()
        divider.boxType = .separator
        place(divider, in: activity, 153, 33, 1, 80)
        localizedToolTip(activity, "내장 물리 SSD의 읽기·쓰기 바이트/초 합계. 그래프는 실제 측정값의 최근 1분 이력입니다.")

        let thermal = GlassCard()
        place(thermal, in: content, 0, 248, 308, 29)
        place(symbol("thermometer.medium", color: PanelColor.violet), in: thermal, 13, 8, 13, 13)
        place(text("SSD 온도", size: 10, weight: .medium, color: PanelColor.secondary), in: thermal, 33, 8, 156, 15)
        ssdTemp.alignment = .right
        place(ssdTemp, in: thermal, 200, 1, 94, 26)
    }

    private func buildNetwork(in content: NSView) {
        for (y, title, value, graph, color) in [
            (CGFloat(0), "↓  다운로드", downValue, downGraph, PanelColor.teal),
            (CGFloat(143), "↑  업로드", upValue, upGraph, PanelColor.blue)
        ] {
            let card = GlassCard()
            place(card, in: content, 0, y, 308, 134)
            place(text(title, size: 11, weight: .semibold, color: color), in: card, 14, 10, 180, 18)
            let recent = text("최근 1분", size: 9, color: PanelColor.secondary)
            recent.alignment = .right
            place(recent, in: card, 202, 11, 92, 14)
            place(value, in: card, 12, 31, 282, 34)
            place(graph, in: card, 14, 75, 280, 46)
            localizedToolTip(card, "Wi-Fi·유선 인터페이스의 바이트/초 합계. 그래프는 실제 측정값의 최근 1분 이력입니다.")
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.backgroundColor = .clear
        view.window?.isOpaque = false
        updateLoginState()
    }

    private func showSelectedTab() {
        tabs.isHidden = showingMenuBarSettings
        settingsScroll.isHidden = !showingMenuBarSettings
        menuBarSettingsButton.contentTintColor = showingMenuBarSettings ? PanelColor.blue : PanelColor.secondary
        localizedAccessibilityLabel(menuBarSettingsButton, showingMenuBarSettings ? "Mac Thermal 설정 닫기" : "Mac Thermal 설정 열기")
        for (index, content) in tabViews.enumerated() {
            content.layer?.removeAnimation(forKey: "tabContentReveal")
            content.isHidden = showingMenuBarSettings || index != tabs.selectedSegment
        }
        if presentationIsVisible { presentLatestSnapshot() }
    }

    @objc private func changeTab() {
        guard Self.tabIdentifiers.indices.contains(tabs.selectedSegment) else { return }
        tabDefaults.set(Self.tabIdentifiers[tabs.selectedSegment], forKey: tabDefaultsKey)
        showSelectedTab()
    }

    private func temperatureText(_ value: Double?) -> NSAttributedString {
        let number = value.map { String(format: "%.0f", $0) } ?? "—"
        let result = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium)])
        result.append(NSAttributedString(string: " °C", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .regular), .foregroundColor: PanelColor.secondary]))
        return result
    }

    private func rateText(_ value: Double?, placeholder: String = "—", size: CGFloat = 20) -> NSAttributedString {
        guard let value else { return NSAttributedString(string: placeholder, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: placeholder == "—" ? size : 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]) }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1_000 && index < units.count - 1 { scaled /= 1_000; index += 1 }
        let number = String(format: scaled < 100 && index > 0 ? "%.1f" : "%.0f", scaled)
        let result = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: " " + units[index], attributes: [.font: NSFont.systemFont(ofSize: size > 20 ? 11 : 10, weight: .medium), .foregroundColor: PanelColor.secondary]))
        return result
    }

    private func byteParts(_ value: Double, binary: Bool) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        let divisor = binary ? 1_024.0 : 1_000.0
        var scaled = max(0, value)
        var index = 0
        while scaled >= divisor && index < units.count - 1 { scaled /= divisor; index += 1 }
        return (String(format: index > 0 && scaled < 100 ? "%.1f" : "%.0f", scaled), units[index])
    }

    private func bytesString(_ value: Double?, binary: Bool = true) -> String {
        guard let value, value.isFinite, value >= 0 else { return L10n.text("정보 없음") }
        let (number, unit) = byteParts(value, binary: binary)
        return number + " " + unit
    }

    private func sizeText(_ value: Double?, size: CGFloat, binary: Bool = true) -> NSAttributedString {
        guard let value, value.isFinite, value >= 0 else {
            return NSAttributedString(string: L10n.text("정보 없음"), attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        }
        let (number, unit) = byteParts(value, binary: binary)
        let result = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: " " + unit, attributes: [.font: NSFont.systemFont(ofSize: size > 25 ? 14 : 11, weight: .medium), .foregroundColor: PanelColor.secondary]))
        return result
    }

    private func presentHistory(_ history: ActivityHistory, in graph: Sparkline) {
        graph.endTime = history.endTime
        graph.points = history.points
    }

    func apply(_ sample: Snapshot, recordHistory: Bool = true) {
        latestSnapshot = sample
        if recordHistory {
            cpuHistory.append(sample.cpuUsage, at: sample.uptime)
            gpuHistory.append(sample.resources.gpu.utilizationPercent, at: sample.uptime)
            uploadHistory.append(sample.upload, at: sample.time)
            downloadHistory.append(sample.download, at: sample.time)
            diskReadHistory.append(sample.resources.disk.readBytesPerSecond, at: sample.time)
            diskWriteHistory.append(sample.resources.disk.writeBytesPerSecond, at: sample.time)
        }
        guard isViewLoaded, presentationIsVisible else { return }
        presentLatestSnapshot()
    }

    /// Render the latest collected values before opening, without adding samples.
    /// Offscreen documentation rendering also uses this explicit presentation step.
    func prepareForPresentation() {
        _ = view
        presentLatestSnapshot()
    }

    private func presentLatestSnapshot() {
        guard isViewLoaded else { return }
        let sample = latestSnapshot
        uptimeLabel.stringValue = SystemUptime.label(sample.uptime)
        updated.stringValue = L10n.format("2초마다 갱신  ·  %@", timeFormatter.string(from: sample.time))
        guard !showingMenuBarSettings else { return }
        switch tabs.selectedSegment {
        case 0: applyCPU(sample)
        case 1: applyGPU(sample.resources.gpu)
        case 2:
            applyMemory(sample.resources.memory)
            applyMemoryProcesses(sample.resources.processes)
        case 3: applyDisk(sample)
        case 4: applyNetwork(sample)
        default: break
        }
    }

    private func applyCPU(_ sample: Snapshot) {
        let temperatureColor = sample.thermal.level > 0 ? sample.thermal.color : NSColor.labelColor
        let attributed = NSMutableAttributedString(attributedString: temperatureText(sample.cpuTemperature))
        attributed.addAttribute(.foregroundColor, value: temperatureColor, range: NSRange(location: 0, length: attributed.length - 3))
        cpuTemp.attributedStringValue = attributed
        cpuTemp.toolTip = L10n.format("CPU 코어 센서 %d개 중 최댓값 · PMU 제외", sample.cpuSensors)
        cpuTemp.setAccessibilityLabel(L10n.format("CPU 온도 %@", sample.cpuTemperature.map { L10n.format("%.0f도", $0) } ?? L10n.text("읽기 불가")))
        cpuPercent.stringValue = sample.cpuUsage.map { String(format: "%.0f%%", $0) } ?? L10n.text("측정 중")
        cpuPercent.font = .monospacedDigitSystemFont(ofSize: sample.cpuUsage == nil ? 12 : 30, weight: .medium)
        cpuGraph.update(cpuHistory, percent: sample.cpuUsage)
        cpuGraph.color = sample.thermal.level > 0 ? sample.thermal.color : PanelColor.blue
        thermalDetail.stringValue = L10n.format("macOS 열 상태 · %@", sample.thermal.title)
        thermalDetail.toolTip = sample.thermal.detail
        thermalDetail.setAccessibilityLabel(sample.thermal.detail)
        thermalDetail.textColor = sample.thermal.level > 0 ? sample.thermal.color : PanelColor.secondary
        applyCPUProcesses(sample.resources.processes)
    }

    private func applyGPU(_ gpu: GPUSnapshot) {
        let percent = gpu.utilizationPercent.flatMap { value in
            value.isFinite && (0...100).contains(value) ? value : nil
        }
        gpuPercent.stringValue = percent.map { String(format: "%.0f%%", $0) } ?? L10n.text("정보 없음")
        gpuPercent.font = .monospacedDigitSystemFont(ofSize: percent == nil ? 12 : 30, weight: .medium)
        gpuGraph.update(gpuHistory, percent: percent)
        if percent == nil { gpuGraph.setAccessibilityValue(L10n.text("정보 없음")) }
        gpuDetail.stringValue = L10n.text(percent == nil ? "이 Mac에서 GPU 사용률을 읽을 수 없습니다" : "GPU 전체 사용률 · 드라이버 보고값")
        gpuDetail.toolTip = gpuDetail.stringValue
        gpuModel.stringValue = gpu.model.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("정보 없음")
        gpuModel.toolTip = gpuModel.stringValue
        gpuCores.stringValue = gpu.coreCount.flatMap { $0 > 0 ? L10n.format("%d코어", $0) : nil } ?? L10n.text("정보 없음")
    }

    private func applyMemory(_ memory: MemorySnapshot) {
        memoryUsed.attributedStringValue = sizeText(memory.usedBytes, size: 31)
        memoryTotal.stringValue = L10n.format("전체 %@", bytesString(memory.totalBytes))
        memoryCompressed.attributedStringValue = sizeText(memory.compressedBytes, size: 17)
        memorySwap.attributedStringValue = sizeText(memory.swapUsedBytes, size: 17)
        let percentage = memory.totalBytes.flatMap { total in memory.usedBytes.map { total > 0 ? $0 / total * 100 : 0 } }
        memoryBar.value = percentage
        memoryPercent.stringValue = percentage.map { String(format: "%.0f%%", $0) } ?? "—"
        let title: String
        let note: String
        let color: NSColor
        switch memory.pressureLevel {
        case 0:
            title = L10n.text("압박 정상"); note = L10n.text("메모리 압박이 정상 범위입니다"); color = .systemGreen
        case 1:
            title = L10n.text("압박 주의"); note = L10n.text("macOS가 메모리 압박을 감지했습니다"); color = .systemOrange
        case 2:
            title = L10n.text("압박 높음"); note = L10n.text("macOS가 높은 메모리 압박을 보고했습니다"); color = .systemRed
        default:
            title = L10n.text("정보 없음"); note = L10n.text("메모리 압박 상태를 읽을 수 없습니다"); color = .secondaryLabelColor
        }
        memoryPressure.update(title, color: color)
        memoryPressure.toolTip = note + "\n" + L10n.text("macOS가 보고하는 메모리 압박 상태입니다. RAM 사용률로 판단하지 않습니다.")
        memoryBar.color = PanelColor.violet
    }

    private func processCountText(_ processes: ProcessSnapshot) -> String {
        processes.available ? L10n.format("조회 %d개 · 제외 %d개", processes.readableCount, processes.skippedCount) : L10n.text("조회 정보 없음")
    }

    private func processDetail(_ processes: ProcessSnapshot) -> String {
        L10n.format("정보를 읽은 프로세스 %d개, 종료·권한 제한 등으로 제외한 프로세스 %d개. 앱별로 합산하지 않은 프로세스 기준 순위입니다.", processes.readableCount, processes.skippedCount)
    }

    private func applyCPUProcesses(_ processes: ProcessSnapshot) {
        let cpuEmpty = processes.available ? (processes.cpuReady ? L10n.text("표시할 프로세스가 없습니다") : L10n.text("다음 측정부터 CPU 순위를 표시합니다")) : L10n.text("프로세스 정보를 읽을 수 없습니다")
        cpuRanking.update(processes.cpuTop, emptyMessage: cpuEmpty, countText: processCountText(processes), detail: processDetail(processes) + "\n" + L10n.text("CPU 비율은 전체 코어를 합친 100% 기준입니다")) { process in
            process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? L10n.text("측정 중")
        }
    }

    private func applyMemoryProcesses(_ processes: ProcessSnapshot) {
        memoryRanking.update(processes.memoryTop, emptyMessage: processes.available ? L10n.text("표시할 프로세스가 없습니다") : L10n.text("프로세스 정보를 읽을 수 없습니다"), countText: processCountText(processes), detail: processDetail(processes)) { process in
            bytesString(process.memoryBytes)
        }
    }

    private func applyDisk(_ sample: Snapshot) {
        let disk = sample.resources.disk
        let total = disk.totalBytes.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let available = disk.availableBytes.flatMap { value in
            value.isFinite && value >= 0 && (total.map { value <= $0 } ?? true) ? value : nil
        }
        let used = total.flatMap { total in available.map { total - $0 } }
        let percentage = total.flatMap { total in used.map { $0 / total * 100 } }
        let usageLine = NSMutableAttributedString(attributedString: sizeText(used, size: 27, binary: false))
        usageLine.append(NSAttributedString(string: " / " + bytesString(total, binary: false), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium), .foregroundColor: PanelColor.secondary]))
        if let percentage {
            usageLine.append(NSAttributedString(string: String(format: " (%.0f%%)", percentage), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: PanelColor.secondary]))
        }
        diskFree.attributedStringValue = usageLine
        diskFree.setAccessibilityLabel(L10n.format("SSD 사용 %@, 전체 %@", bytesString(used, binary: false), bytesString(total, binary: false)))
        diskCapacity.stringValue = L10n.format("사용 가능 %@", bytesString(available, binary: false))
        diskBar.value = percentage
        diskBar.color = PanelColor.violet
        let placeholder = disk.deviceCount > 0 ? L10n.text("측정 중") : L10n.text("정보 없음")
        diskRead.attributedStringValue = rateText(disk.readBytesPerSecond, placeholder: placeholder)
        diskWrite.attributedStringValue = rateText(disk.writeBytesPerSecond, placeholder: placeholder)
        presentHistory(diskReadHistory, in: diskReadGraph)
        presentHistory(diskWriteHistory, in: diskWriteGraph)
        let temperature = NSMutableAttributedString(attributedString: temperatureText(sample.ssdTemperature))
        temperature.addAttribute(.foregroundColor, value: sample.thermal.level > 0 ? sample.thermal.color : NSColor.labelColor, range: NSRange(location: 0, length: temperature.length - 3))
        ssdTemp.attributedStringValue = temperature
        ssdTemp.toolTip = L10n.format("내장 SSD NAND 센서 %d개 중 최댓값", sample.ssdSensors)
        ssdTemp.setAccessibilityLabel(L10n.format("SSD 온도 %@", sample.ssdTemperature.map { L10n.format("%.0f도", $0) } ?? L10n.text("읽기 불가")))
    }

    @objc private func openDiskCleanup() {
        let cleanup: DiskCleanupView
        if let existing = diskCleanupView { cleanup = existing }
        else {
            cleanup = DiskCleanupView(frame: diskMonitorView.bounds, defaults: tabDefaults)
            cleanup.didClose = { [weak self] in self?.closeDiskCleanup() }
            cleanup.didFinish = { [weak self] in self?.refresh?() }
            tabViews[3].addSubview(cleanup)
            diskCleanupView = cleanup
        }
        diskMonitorView.isHidden = true
        cleanup.isHidden = false
        cleanup.onEntry()
    }

    private func closeDiskCleanup() {
        diskCleanupView?.isHidden = true
        diskMonitorView.isHidden = false
        if presentationIsVisible { presentLatestSnapshot() }
    }

    private func applyNetwork(_ sample: Snapshot) {
        upValue.attributedStringValue = rateText(sample.upload, size: 26)
        downValue.attributedStringValue = rateText(sample.download, size: 26)
        presentHistory(uploadHistory, in: upGraph)
        presentHistory(downloadHistory, in: downGraph)
    }

    func updateLoginState() {
        guard isViewLoaded else { return }
        let status = LoginItemManager.state()
        loginSwitch.state = status.enabled || status.requiresApproval ? .on : .off
        loginLabel.stringValue = status.enabled ? L10n.text("켜짐") : (status.requiresApproval ? L10n.text("승인 필요") : L10n.text("꺼짐"))
        loginLabel.textColor = status.requiresApproval ? .systemOrange : PanelColor.secondary
        loginLabel.toolTip = status.title
    }

    @objc private func toggleLogin() {
        do {
            if loginSwitch.state == .on { try LoginItemManager.enable() }
            else { try LoginItemManager.disable() }
            if LoginItemManager.state().requiresApproval { LoginItemManager.openSettings() }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("자동 실행 설정을 완료하지 못했습니다")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: L10n.text("확인"))
            alert.runModal()
        }
        updateLoginState()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func refreshNow() { refresh?() }
}

#if PANEL_UPDATES_PROBE
// Synthetic offscreen checks only; none of these hooks are in release builds.
extension PanelController {
    func probeSetVisible(_ visible: Bool) { probeVisible = visible }
    func probeSelectTab(_ index: Int) {
        tabs.selectedSegment = index
        changeTab()
    }
    func probeToggleSettings() { toggleMenuBarSettings() }
    var probeResetNotificationsEnabled: Bool { resetNotificationsSwitch.state == .on }
    var probeResetNotificationsCanChange: Bool { resetNotificationsSwitch.isEnabled }
    var probeResetNotificationsStatus: String { resetNotificationsStatus.stringValue }
    func probeSetResetNotifications(_ enabled: Bool) {
        resetNotificationsSwitch.state = enabled ? .on : .off
        resetNotificationsSwitch.sendAction(resetNotificationsSwitch.action, to: resetNotificationsSwitch.target)
    }
    var probeCodexRecordsEnabled: Bool { codexRecordsSwitch.state == .on }
    var probeCodexRecordsStatus: String { codexRecordsStatus.stringValue }
    var probeCodexPrivacyFits: Bool {
        let privacy = L10n.text("대화 기록 파일에서 추출 · 본문 저장·표시·전송 없음") as NSString
        return privacy.boundingRect(with: NSSize(width: 262, height: 100), options: .usesLineFragmentOrigin,
            attributes: [.font: NSFont.systemFont(ofSize: 9)]).height <= 27
    }
    func probeSetCodexRecordsEnabled(_ enabled: Bool) {
        codexRecordsSwitch.state = enabled ? .on : .off
        codexRecordsSwitch.sendAction(codexRecordsSwitch.action, to: codexRecordsSwitch.target)
    }
    func probeClickMetric(_ metric: MenuBarMetric) { metricControls[metric]?.performClick(nil) }
    var probeMenuBarPreferences: MenuBarPreferences { menuBarPreferences }
    var probeVisibleMetrics: Set<MenuBarMetric> {
        Set(MenuBarMetric.allCases.filter { metricControls[$0]?.state == .on })
    }
    var probeMetricTitles: [String] { MenuBarMetric.allCases.compactMap { metricControls[$0]?.title } }
    var probeMetricLabelsFit: Bool {
        metricControls.values.allSatisfy { ($0.cell?.cellSize.width ?? 0) <= $0.frame.width }
    }
    var probeCPUStyleEnabled: Bool { animationStyleControl.isEnabled }
    var probeMotionControlEnabled: Bool { menuBarMotionSwitch.isEnabled }
    var probeIntensityControlEnabled: Bool { motionIntensitySlider.isEnabled }
    func probeOpenDiskCleanup() { diskCleanupButton.performClick(nil) }
    func probeCloseDiskCleanup() { closeDiskCleanup() }
    var probeDiskCleanupView: DiskCleanupView? { diskCleanupView }
    var probeDiskCleanupButtonTitle: String { diskCleanupButton.title }
    var probeStrings: [String: String] {
        ["cpu": cpuTemp.stringValue, "cpuPercent": cpuPercent.stringValue,
         "gpuPercent": gpuPercent.stringValue, "gpuModel": gpuModel.stringValue,
         "gpuCores": gpuCores.stringValue, "gpuDetail": gpuDetail.stringValue,
         "memory": memoryUsed.stringValue, "memoryTotal": memoryTotal.stringValue,
         "processes": tabs.selectedSegment == 2 ? memoryRanking.probeCount : cpuRanking.probeCount,
         "cpuProcesses": cpuRanking.probeCount, "memoryProcesses": memoryRanking.probeCount,
         "disk": diskFree.stringValue, "ssdTemperature": ssdTemp.stringValue,
         "upload": upValue.stringValue, "diskRead": diskRead.stringValue,
         "thermal": thermalDetail.stringValue, "uptime": uptimeLabel.stringValue,
         "updated": updated.stringValue]
    }
    var probeSelectedTab: Int { tabs.selectedSegment }
    var probeTabLabels: [String] { Self.tabLabels.map(L10n.text) }
    var probeRankingTexts: [String: [String]] { ["cpu": cpuRanking.probeRows, "memory": memoryRanking.probeRows] }
    var probeHistoryTimes: [[TimeInterval]] {
        [cpuHistory.points.map(\.time), uploadHistory.points.map { $0.0.timeIntervalSince1970 },
         downloadHistory.points.map { $0.0.timeIntervalSince1970 },
         diskReadHistory.points.map { $0.0.timeIntervalSince1970 },
         diskWriteHistory.points.map { $0.0.timeIntervalSince1970 }]
    }
    var probePresentedHistoryTimes: [[TimeInterval]] {
        [upGraph.points.map { $0.0.timeIntervalSince1970 },
         downGraph.points.map { $0.0.timeIntervalSince1970 },
         diskReadGraph.points.map { $0.0.timeIntervalSince1970 },
         diskWriteGraph.points.map { $0.0.timeIntervalSince1970 }]
    }
    var probeCPUHistoryRuns: [[CPUUsageHistory.Point]] { cpuHistory.runs }
    var probeGPUHistoryRuns: [[CPUUsageHistory.Point]] { gpuHistory.runs }
    var probeGPUHistoryTimes: [TimeInterval] { gpuHistory.points.map(\.time) }
    var probePresentedCPUHistoryTimes: [TimeInterval] { cpuGraph.probeTimes }
    var probePresentedGPUHistoryTimes: [TimeInterval] { gpuGraph.probeTimes }
    var probeSurfaceFrames: [NSRect] { tabViews.map(\.frame) + [settingsScroll.frame] }
}
#endif
