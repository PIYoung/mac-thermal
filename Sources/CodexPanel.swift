import AppKit
import Foundation

private func codexText(size: CGFloat = 10, weight: NSFont.Weight = .regular, secondary: Bool = false, digits: Bool = false, lines: Int = 1) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    return field
}

private func codexPlace(_ child: NSView, in parent: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
    child.frame = NSRect(x: x, y: y, width: width, height: height)
    parent.addSubview(child)
}

private final class CodexCanvas: FlippedView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PanelController.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: PanelColor.blue.withAlphaComponent(0.075), ending: .clear)?.draw(in: bounds, angle: 90)
    }
}

private final class CodexPill: FlippedView {
    private let label = codexText(size: 9, weight: .semibold)
    private var color = NSColor.secondaryLabelColor
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.alignment = .center
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 5, dy: 3)
    }
    func update(_ value: String, color: NSColor) {
        label.stringValue = value
        label.textColor = color
        self.color = color
        setAccessibilityLabel(value)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

private final class CodexBar: FlippedView {
    var fraction: Double? { didSet { needsDisplay = true } }
    var color = PanelColor.blue
    override func draw(_ dirtyRect: NSRect) {
        PanelColor.divider.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard let fraction, fraction.isFinite, fraction > 0 else { return }
        color.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, fraction)), height: bounds.height), xRadius: 2, yRadius: 2).fill()
    }
}

/// Original bounded area chart. Cubic handles stay within each pair's value
/// range, so smoothing cannot invent a peak or connect missing dates.
private final class CodexUsageChart: FlippedView {
    private var days: [CodexDailyUsage] = []
    private var tracking: NSTrackingArea?
    private var hovered: Int?
    private var pointer: NSPoint?
    private var hoverValue = ""
    private var hoverSize = NSSize.zero
    private let numberFormatter = NumberFormatter()
    private let hoverDateAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor]
    private let hoverValueAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.labelColor]
    private var language = ""
    func update(_ values: [CodexDailyUsage]) {
        let next = Array(values.prefix(7)), locale = L10n.language.rawValue
        guard next != days || locale != language else { return }
        days = next; language = locale
        numberFormatter.locale = Locale(identifier: L10n.language.localeIdentifier)
        numberFormatter.numberStyle = .decimal
        clearHover()
        let labels = days.map { "\($0.day): " + ($0.tokens.map(Self.compact) ?? L10n.text("정보 없음")) }
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.text("최근 7일 계정 토큰 사용량") + ", " + labels.joined(separator: ", "))
        // Custom callouts are immediate; a second delayed native tooltip would overlap.
        toolTip = nil
        setAccessibilityHelp(L10n.text("서버가 반환한 날짜별 토큰입니다. 빈 날짜는 정보 없음이며 0이 아닙니다."))
        needsDisplay = true
    }
    private static func compact(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return String(count)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { clearHover() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { clearHover() }
    }
    private func clearHover() {
        guard hovered != nil || pointer != nil else { return }
        hovered = nil; pointer = nil; hoverValue = ""; hoverSize = .zero
        needsDisplay = true
    }
    private func updateHover(at point: NSPoint) {
        guard !days.isEmpty, point.x.isFinite, point.y.isFinite, bounds.contains(point) else { clearHover(); return }
        let index = max(0, min(days.count - 1, Int(((point.x - 4) / max(1, bounds.width - 8) * CGFloat(days.count - 1)).rounded())))
        guard hovered != index || pointer != point else { return }
        if hovered != index {
            let day = days[index]
            hoverValue = day.tokens.map {
                L10n.format("%@ 토큰", numberFormatter.string(from: NSNumber(value: $0)) ?? String($0))
            } ?? L10n.text("정보 없음")
            let dateWidth = (day.day as NSString).size(withAttributes: hoverDateAttributes).width
            let valueWidth = (hoverValue as NSString).size(withAttributes: hoverValueAttributes).width
            hoverSize = NSSize(width: min(max(1, bounds.width - 4), max(dateWidth, valueWidth) + 16), height: 32)
        }
        hovered = index; pointer = point; needsDisplay = true
    }
    private var hoverFrame: NSRect? {
        guard let pointer, hovered != nil else { return nil }
        let width = hoverSize.width, height = min(hoverSize.height, bounds.height - 4)
        var x = pointer.x + 10
        if x + width > bounds.maxX - 2 { x = pointer.x - width - 10 }
        var y = pointer.y - height - 8
        if y < 2 { y = pointer.y + 8 }
        return NSRect(x: max(2, min(bounds.width - width - 2, x)),
            y: max(2, min(bounds.height - height - 2, y)), width: width, height: height)
    }
    #if PANEL_UPDATES_PROBE
    func probeHover(at point: NSPoint) { updateHover(at: point) }
    func probeExit() { clearHover() }
    var probeHoverFrame: NSRect? { hoverFrame }
    var probeHoverValue: String { hoverValue }
    var probeHoverDay: String? { hovered.map { days[$0].day } }
    #endif
    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let plot = NSRect(x: 4, y: 5, width: max(1, bounds.width - 8), height: max(1, bounds.height - 22))
        let maximum = max(1, Double(days.compactMap(\.tokens).max() ?? 0))
        let color = PanelColor.blue
        let grid = NSBezierPath()
        for fraction in [0.0, 0.5, 1.0] {
            let y = plot.minY + plot.height * fraction
            grid.move(to: NSPoint(x: plot.minX, y: y)); grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        PanelColor.divider.withAlphaComponent(0.10).setStroke(); grid.lineWidth = 0.5; grid.stroke()
        func point(_ index: Int, _ tokens: Int64) -> NSPoint {
            NSPoint(x: plot.minX + plot.width * CGFloat(index) / CGFloat(max(1, days.count - 1)),
                    y: plot.maxY - plot.height * CGFloat(Double(max(0, tokens)) / maximum))
        }
        var segments: [[NSPoint]] = [], current: [NSPoint] = []
        for (index, day) in days.enumerated() {
            if let tokens = day.tokens { current.append(point(index, tokens)) }
            else if !current.isEmpty { segments.append(current); current = [] }
        }
        if !current.isEmpty { segments.append(current) }
        for segment in segments {
            guard let first = segment.first, let last = segment.last else { continue }
            let line = NSBezierPath(); line.move(to: first)
            for (left, right) in zip(segment, segment.dropFirst()) {
                let offset = (right.x - left.x) / 3
                line.curve(to: right, controlPoint1: NSPoint(x: left.x + offset, y: left.y), controlPoint2: NSPoint(x: right.x - offset, y: right.y))
            }
            if segment.count > 1 {
                let fill = line.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: last.x, y: plot.maxY)); fill.line(to: NSPoint(x: first.x, y: plot.maxY)); fill.close()
                NSGradient(starting: color.withAlphaComponent(0.02), ending: color.withAlphaComponent(0.20))?.draw(in: fill, angle: 90)
                color.setStroke(); line.lineWidth = 1.6; line.lineCapStyle = .round; line.stroke()
            }
            for item in segment { color.withAlphaComponent(0.8).setFill(); NSBezierPath(ovalIn: NSRect(x: item.x - 1.7, y: item.y - 1.7, width: 3.4, height: 3.4)).fill() }
        }
        if let hovered, days.indices.contains(hovered) {
            let x = plot.minX + plot.width * CGFloat(hovered) / CGFloat(max(1, days.count - 1))
            color.withAlphaComponent(0.35).setStroke()
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: x, y: plot.minY)); guide.line(to: NSPoint(x: x, y: plot.maxY))
            guide.lineWidth = 0.5; guide.setLineDash([2, 2], count: 2, phase: 0); guide.stroke()
            if let tokens = days[hovered].tokens {
                let selected = point(hovered, tokens)
                color.withAlphaComponent(0.12).setFill(); NSBezierPath(ovalIn: NSRect(x: selected.x - 5, y: selected.y - 5, width: 10, height: 10)).fill()
                color.setFill(); NSBezierPath(ovalIn: NSRect(x: selected.x - 2.5, y: selected.y - 2.5, width: 5, height: 5)).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for index in [0, days.count - 1] {
            let label = String(days[index].day.suffix(5)).replacingOccurrences(of: "-", with: "/") as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: index == 0 ? 1 : bounds.width - width - 1, y: bounds.height - 12), withAttributes: attributes)
        }
        if let rect = hoverFrame, let hovered {
            let bubble = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill(); bubble.fill()
            PanelColor.divider.setStroke(); bubble.lineWidth = 0.5; bubble.stroke()
            (days[hovered].day as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 3), withAttributes: hoverDateAttributes)
            (hoverValue as NSString).draw(at: NSPoint(x: rect.minX + 8, y: rect.minY + 15), withAttributes: hoverValueAttributes)
        }
    }
}


private final class CodexInsightGrid: GlassCard {
    let heading = codexText(size: 11, weight: .semibold)
    private let keys: [String]
    private let captions: [NSTextField]
    private let values: [NSTextField]
    let message = codexText(size: 10, secondary: true, lines: 2)
    let action = NSButton()
    let composition = CodexComposition()
    var showsComposition = false
    var actionInLastCell = false { didSet { needsLayout = true } }
    var cardHeight: CGFloat { 30 + CGFloat((keys.count + 1) / 2) * 34 + (showsComposition ? 15 : 6) }
    init(_ title: String, keys: [String], composition: Bool = false) {
        self.keys = keys; captions = keys.map { _ in codexText(size: 9, secondary: true) }
        values = keys.map { _ in codexText(size: 12, weight: .medium, digits: true) }
        super.init(frame: .zero)
        heading.stringValue = L10n.text(title); showsComposition = composition
        addSubview(heading)
        for field in captions + values { addSubview(field) }
        addSubview(message); message.isHidden = true; message.alignment = .center
        addSubview(action); action.isHidden = true; action.isBordered = false
        action.contentTintColor = PanelColor.blue; action.font = .systemFont(ofSize: 10, weight: .medium)
        addSubview(self.composition)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 12, y: 7, width: bounds.width - 24, height: 17)
        let cell = (bounds.width - 30) / 2
        for index in keys.indices {
            let x = CGFloat(index % 2) * (cell + 6) + 12, y = CGFloat(index / 2) * 34 + 30
            captions[index].frame = NSRect(x: x, y: y, width: cell, height: 12)
            values[index].frame = NSRect(x: x, y: y + 12, width: cell, height: 18)
        }
        message.frame = NSRect(x: 12, y: 38, width: bounds.width - 24, height: 30)
        action.frame = actionInLastCell ? NSRect(x: 132, y: 111, width: 114, height: 23) : NSRect(x: 12, y: bounds.height - 33, width: bounds.width - 24, height: 23)
        composition.frame = NSRect(x: 12, y: bounds.height - 11, width: bounds.width - 24, height: 4)
        composition.isHidden = !showsComposition || !message.isHidden
    }
    func update(title: String, values texts: [String], help: String) {
        heading.stringValue = title
        actionInLastCell = false
        message.isHidden = true; action.isHidden = true
        for index in keys.indices {
            captions[index].stringValue = L10n.text(keys[index]); captions[index].isHidden = false
            values[index].stringValue = texts.indices.contains(index) ? texts[index] : L10n.text("정보 없음")
            values[index].isHidden = false
            values[index].toolTip = help
        }
        toolTip = help; needsLayout = true
    }
    func show(title: String, message key: String, action actionKey: String? = nil) {
        heading.stringValue = title
        actionInLastCell = false
        for field in captions + values { field.isHidden = true }
        message.stringValue = L10n.text(key); message.isHidden = false
        action.isHidden = actionKey == nil; action.title = actionKey.map(L10n.text) ?? ""
        needsLayout = true
    }
    #if PANEL_UPDATES_PROBE
    var probeValues: [String] { values.filter { !$0.isHidden }.map(\.stringValue) }
    #endif
}
private final class CodexComposition: FlippedView {
    var fraction: Double? { didSet { if oldValue != fraction { needsDisplay = true } } }
    override func draw(_ rect: NSRect) {
        PanelColor.divider.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard let fraction, fraction.isFinite else { return }
        let x = bounds.width * min(1, max(0, fraction))
        PanelColor.blue.setFill(); NSRect(x: 0, y: 0, width: x, height: bounds.height).fill()
        PanelColor.violet.setFill(); NSRect(x: x, y: 0, width: bounds.width - x, height: bounds.height).fill()
    }
}
private final class CodexMinuteChart: FlippedView {
    private var samples: [CodexUsageMinute] = []
    private var language = ""
    func update(_ values: [CodexUsageMinute]) {
        let next = Array(values.suffix(10)), locale = L10n.language.rawValue
        guard samples != next || language != locale else { return }
        samples = next; language = locale; needsDisplay = true
        setAccessibilityElement(true)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: L10n.language.localeIdentifier); formatter.dateFormat = "HH:mm"
        setAccessibilityLabel(L10n.text("최근 10분 · 이 Mac 기록") + ", " + samples.map { formatter.string(from: $0.startedAt) + ": " + ($0.tokens.map { L10n.format("%lld 토큰", $0) } ?? L10n.text("정보 없음")) }.joined(separator: ", "))
    }
    override func draw(_ rect: NSRect) {
        let step = bounds.width / 10, height = max(1, bounds.height - 14)
        let maxValue = Double(max(1, samples.compactMap(\.tokens).max() ?? 0))
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * step + 2, w = max(1, step - 4)
            PanelColor.divider.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: w, height: height), xRadius: 3, yRadius: 3).fill()
            if let tokens = sample.tokens {
                let h = tokens == 0 ? 1 : max(2, height * Double(tokens) / maxValue)
                PanelColor.blue.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: height - h, width: w, height: h), xRadius: 3, yRadius: 3).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.secondaryLabelColor]
        ("−10m" as NSString).draw(at: NSPoint(x: 0, y: bounds.height - 11), withAttributes: attributes)
        let now = L10n.text("지금") as NSString
        now.draw(at: NSPoint(x: bounds.width - now.size(withAttributes: attributes).width, y: bounds.height - 11), withAttributes: attributes)
    }
}

/// Numeric account quota and local-record metadata only. No authentication data.
final class CodexPanelController: NSViewController {
    static let surfaceSize = NSSize(width: 300, height: 420)
    static let size = NSSize(width: 348, height: 468)

    private var latest = CodexMonitorSnapshot.pending
    private var renderNow = Date()
    private var languageObserver: NSObjectProtocol?
    private let connection = CodexPill(frame: .zero)
    private let activityCard = GlassCard()
    private let quotaCard = GlassCard()
    private let quotaTitles = (0..<2).map { _ in codexText(size: 10, weight: .medium) }
    private let quotaValues = (0..<2).map { _ in codexText(size: 11, weight: .semibold, digits: true) }
    private let quotaResets = (0..<2).map { _ in codexText(size: 9, secondary: true, digits: true) }
    private let quotaBars = (0..<2).map { _ in CodexBar() }
    private let quotaStatus = codexText(size: 11, secondary: true, lines: 2)
    private let quotaElapsed = codexText(size: 9, secondary: true, digits: true)
    private lazy var accountButton = NSButton(image: NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(accountClicked))
    private let insightsScroll = NSScrollView()
    private let insightsDocument = FlippedView()
    private let breakdownCard = CodexInsightGrid("토큰 구성 · 이 Mac", keys: ["입력 토큰", "출력 토큰", "캐시 재사용률", "출력 중 추론"], composition: true)
    private let modelDetailCard = CodexInsightGrid("모델 상세", keys: ["입력 토큰", "출력 토큰", "캐시 재사용률", "출력 중 추론"], composition: true)
    private let weekCard = CodexInsightGrid("최근 7일 요약 · 계정", keys: ["제공된 날짜 합계", "제공된 날짜 평균", "최다 사용일", "자료 일수"])
    private let summaryCard = CodexInsightGrid("계정 활동 요약", keys: ["누적 토큰", "하루 최고 토큰", "현재 연속 사용", "최장 연속 사용", "최장 턴 시간"])
    private let flowCard = GlassCard()
    private let flowTitle = codexText(size: 11, weight: .semibold)
    private let flowValue = codexText(size: 10, secondary: true, digits: true)
    private let minuteChart = CodexMinuteChart()
    private let closedChevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
    private let openChevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
    private let modelChevrons = (0..<3).map { _ in NSImageView() }
    private var visibleModels: [CodexModelUsage] = []
    private var expandedModel: String?
    private lazy var modelButtons: [NSButton] = (0..<3).map { index in
        let button = NSButton(title: "", target: self, action: #selector(modelClicked(_:)))
        button.tag = index; button.isTransparent = true; button.isBordered = false
        return button
    }
    private let totalsCard = GlassCard()
    private let modelsCard = GlassCard()
    private let usageCard = GlassCard()
    private let usageTitle = codexText(size: 11, weight: .semibold)
    private lazy var usageScope = NSButton(title: "", target: self, action: #selector(usageClicked))
    private let usageStatus = codexText(size: 10, secondary: true, lines: 2)
    private let usageChart = CodexUsageChart()
    private lazy var usageConnectButton = NSButton(title: "", target: self, action: #selector(usageClicked))
    private let activity = codexText(size: 12, weight: .semibold)
    private let elapsed = codexText(size: 11, weight: .medium, digits: true)
    private let model = codexText(size: 10, secondary: true)
    private let counts = codexText(size: 10, secondary: true, digits: true)
    private let dailyTitle = codexText(size: 10, weight: .medium)
    private let dailyValue = codexText(size: 23, weight: .medium, digits: true)
    private let dailyScope = codexText(size: 9, secondary: true)
    private let modelsTitle = codexText(size: 11, weight: .semibold)
    private let modelsUnit = codexText(size: 9, secondary: true)
    private let modelNames = (0..<3).map { _ in codexText(size: 10, weight: .medium) }
    private let modelValues = (0..<3).map { _ in codexText(size: 10, weight: .medium, digits: true) }
    private let modelBars = (0..<3).map { _ in CodexBar() }
    private let modelsEmpty = codexText(size: 10, secondary: true, lines: 2)
    private let updated = codexText(size: 9, secondary: true, digits: true)
    private lazy var refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(refreshNow))
    var refresh: (() -> Void)?
    var accountAction: (() -> Void)?
    var usageAction: (() -> Void)?
    var summaryAction: (() -> Void)?
    #if PANEL_UPDATES_PROBE
    private var probeVisible = false
    #endif
    private var presentationIsVisible: Bool {
        #if PANEL_UPDATES_PROBE
        return probeVisible
        #else
        return view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor
        #endif
    }

    override func loadView() {
        let canvas = CodexCanvas(frame: NSRect(origin: .zero, size: Self.surfaceSize))
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: canvas.bounds)
            glass.style = .regular
            glass.cornerRadius = PanelController.cornerRadius
            glass.contentView = canvas
            view = PanelSurfaceHost(glass: glass, surfaceSize: Self.surfaceSize)
        } else {
            let glass = NSVisualEffectView(frame: canvas.bounds)
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = PanelController.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.addSubview(canvas)
            view = PanelSurfaceHost(glass: glass, surfaceSize: Self.surfaceSize)
        }
        preferredContentSize = Self.size
        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = PanelColor.blue
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        codexPlace(icon, in: canvas, 15, 16, 19, 19)
        let brand = codexText(size: 16, weight: .semibold)
        brand.stringValue = "Codex"
        codexPlace(brand, in: canvas, 42, 12, 130, 25)
        quotaElapsed.alignment = .right
        codexPlace(quotaElapsed, in: canvas, 98, 20, 78, 14)
        accountButton.isBordered = false
        accountButton.contentTintColor = .secondaryLabelColor
        codexPlace(accountButton, in: canvas, 180, 14, 21, 23)
        codexPlace(connection, in: canvas, 205, 15, 80, 21)
        codexPlace(activityCard, in: canvas, 12, 48, 276, 64)
        codexPlace(activity, in: activityCard, 12, 10, 142, 19)
        elapsed.alignment = .right
        codexPlace(elapsed, in: activityCard, 156, 12, 108, 16)
        codexPlace(model, in: activityCard, 12, 37, 140, 16)
        counts.alignment = .right
        codexPlace(counts, in: activityCard, 152, 37, 112, 16)
        codexPlace(quotaCard, in: canvas, 12, 48, 276, 64)
        for index in 0..<2 {
            let y = CGFloat(7 + index * 27)
            codexPlace(quotaTitles[index], in: quotaCard, 12, y, 66, 15)
            codexPlace(quotaValues[index], in: quotaCard, 80, y - 1, 70, 16)
            quotaResets[index].alignment = .right
            codexPlace(quotaResets[index], in: quotaCard, 152, y, 112, 15)
            codexPlace(quotaBars[index], in: quotaCard, 12, y + 17, 252, 3)
        }
        quotaStatus.alignment = .center
        codexPlace(quotaStatus, in: quotaCard, 12, 16, 252, 34)
        insightsScroll.drawsBackground = false
        insightsScroll.wantsLayer = true
        insightsScroll.layer?.masksToBounds = true
        insightsScroll.contentView.wantsLayer = true
        insightsScroll.contentView.layer?.masksToBounds = true
        insightsScroll.hasVerticalScroller = true
        insightsScroll.autohidesScrollers = true
        insightsScroll.scrollerStyle = .overlay
        codexPlace(insightsScroll, in: canvas, 12, 120, 276, 266)
        insightsDocument.frame = NSRect(x: 0, y: 0, width: 258, height: 800)
        insightsScroll.documentView = insightsDocument
        codexPlace(totalsCard, in: insightsDocument, 0, 0, 258, 60)
        codexPlace(dailyTitle, in: totalsCard, 12, 9, 126, 16)
        codexPlace(dailyValue, in: totalsCard, 10, 27, 236, 27)
        dailyScope.alignment = .right
        codexPlace(dailyScope, in: totalsCard, 132, 11, 114, 13)
        codexPlace(modelsCard, in: insightsDocument, 0, 184, 258, 82)
        codexPlace(modelsTitle, in: modelsCard, 12, 5, 174, 17)
        modelsUnit.alignment = .right
        codexPlace(modelsUnit, in: modelsCard, 170, 7, 76, 14)
        for index in 0..<3 {
            let y = CGFloat(25 + index * 17)
            codexPlace(modelNames[index], in: modelsCard, 12, y, 149, 13)
            modelValues[index].alignment = .right
            codexPlace(modelValues[index], in: modelsCard, 166, y, 64, 13)
            modelBars[index].color = [PanelColor.blue, PanelColor.violet, PanelColor.teal][index]
            codexPlace(modelBars[index], in: modelsCard, 12, y + 13, 234, 2)
            modelChevrons[index].contentTintColor = .tertiaryLabelColor
            modelChevrons[index].imageScaling = .scaleProportionallyDown
            modelChevrons[index].setAccessibilityElement(false)
            codexPlace(modelChevrons[index], in: modelsCard, 238, y + 2, 7, 9)
            codexPlace(modelButtons[index], in: modelsCard, 8, y - 1, 242, 17)
        }
        codexPlace(modelsEmpty, in: modelsCard, 12, 29, 234, 36)
        codexPlace(usageCard, in: insightsDocument, 0, 68, 258, 108)
        codexPlace(usageTitle, in: usageCard, 12, 9, 104, 17)
        usageScope.isBordered = false; usageScope.contentTintColor = .secondaryLabelColor
        usageScope.font = .systemFont(ofSize: 9); usageScope.alignment = .right
        codexPlace(usageScope, in: usageCard, 150, 7, 96, 20)
        codexPlace(usageChart, in: usageCard, 12, 30, 234, 67)
        usageStatus.alignment = .center
        codexPlace(usageStatus, in: usageCard, 12, 31, 234, 28)
        usageConnectButton.isBordered = false; usageConnectButton.contentTintColor = PanelColor.blue
        usageConnectButton.font = .systemFont(ofSize: 10, weight: .medium)
        codexPlace(usageConnectButton, in: usageCard, 57, 65, 144, 23)
        for card in [modelDetailCard, breakdownCard, flowCard, weekCard, summaryCard] as [NSView] { insightsDocument.addSubview(card) }
        codexPlace(flowTitle, in: flowCard, 12, 7, 180, 17)
        flowValue.alignment = .right
        codexPlace(flowValue, in: flowCard, 186, 9, 60, 15)
        codexPlace(minuteChart, in: flowCard, 12, 32, 234, 44)
        summaryCard.action.target = self; summaryCard.action.action = #selector(summaryClicked)
        layoutInsights()
        let line = NSBox()
        line.boxType = .separator
        codexPlace(line, in: canvas, 14, 394, 272, 1)
        codexPlace(updated, in: canvas, 14, 399, 244, 14)
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .secondaryLabelColor
        codexPlace(refreshButton, in: canvas, 266, 396, 22, 22)
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in self?.render() }
        render()
    }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    func apply(_ snapshot: CodexMonitorSnapshot) {
        latest = snapshot
        renderNow = Date()
        guard isViewLoaded, presentationIsVisible else { return }
        render()
    }
    func prepareForPresentation() { _ = view; renderNow = Date(); render() }
    @objc private func refreshNow() { refresh?() }
    @objc private func accountClicked() { accountAction?() }
    @objc private func usageClicked() {
        if latest.quota.connection == .connected { usageAction?() }
        else { accountAction?() }
    }
    private func modelName(_ value: String?) -> String {
        guard let value, value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil else { return L10n.text("정보 없음") }
        return value
    }
    private func tokenText(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return L10n.text("정보 없음") }
        let units = ["", "K", "M", "B", "T", "P", "E"]
        var number = Double(value), index = 0
        while number >= 1_000 && index < units.count - 1 { number /= 1_000; index += 1 }
        return String(format: index > 0 && number < 100 ? "%.1f%@" : "%.0f%@", locale: Locale(identifier: L10n.language.localeIdentifier), number, units[index])
    }
    private func duration(_ value: TimeInterval?) -> String {
        guard let value, value.isFinite, value >= 0, value < Double(Int64.max) else { return L10n.text("정보 없음") }
        let seconds = Int64(value)
        if seconds < 3_600 { return String(format: "%02lld:%02lld", seconds / 60, seconds % 60) }
        return String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    private func dateText(_ date: Date?, short: Bool = false) -> String {
        guard let date, date.timeIntervalSince1970.isFinite else { return L10n.text("정보 없음") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate(short ? "HHmm" : "HHmmss")
        let value = formatter.string(from: date)
        return value.isEmpty ? L10n.text("정보 없음") : value
    }
    private func render() {
        guard isViewLoaded else { return }
        let enabled = latest.recordsEnabled
        let connected = latest.connection == .connected
        let connectionKey: String
        let activityKey: String
        let connectionColor: NSColor
        if !enabled {
            connectionKey = "읽기 꺼짐"; activityKey = "기록 읽기 꺼짐"; connectionColor = .secondaryLabelColor
        } else {
            switch latest.connection {
            case .notRunning: connectionKey = "실행 안 됨"; activityKey = "실행 안 됨"; connectionColor = .secondaryLabelColor
            case .connecting: connectionKey = "확인 중"; activityKey = "로컬 기록 확인 중"; connectionColor = PanelColor.blue
            case .connected: connectionKey = "로컬 기록"; activityKey = "로컬 기록 연결"; connectionColor = .systemGreen
            case .unavailable: connectionKey = "읽기 불가"; activityKey = "기록 읽기 불가"; connectionColor = .systemOrange
            }
        }
        connection.update(L10n.text(connectionKey), color: connectionColor)
        activity.stringValue = L10n.text(activityKey)
        counts.stringValue = enabled ? latest.recordsCount.flatMap { $0 >= 0 && !(latest.incomplete && $0 == 0) ? L10n.format("오늘 %lld개 기록", Int64($0)) : nil } ?? "—" : "—"
        counts.toolTip = L10n.text("이 Mac에서 UTC 오늘에 기록된 유효한 토큰 항목 수입니다. 파일 수가 아닙니다.")
        model.stringValue = enabled ? modelName(latest.currentModel) : L10n.text("정보 없음")
        model.toolTip = L10n.text("최근 기록에서 확인된 모델")
        if latest.connection != .notRunning, let started = latest.appStartedAt,
           started.timeIntervalSince1970.isFinite,
           renderNow.timeIntervalSince(started) >= 0,
           renderNow.timeIntervalSince(started) < Double(Int64.max) {
            elapsed.stringValue = L10n.format("앱 %@", duration(renderNow.timeIntervalSince(started)))
            elapsed.toolTip = L10n.text("Codex 앱 실행 후 경과 시간입니다. 작업 활동 시간과 다릅니다.")
        } else {
            elapsed.stringValue = "—"
            elapsed.toolTip = L10n.text("정보 없음")
        }
        elapsed.setAccessibilityLabel(elapsed.toolTip)
        renderQuota()
        dailyTitle.stringValue = L10n.text("오늘 토큰 (UTC)")
        let daily = enabled ? latest.dailyTokens.flatMap { $0 >= 0 && !(latest.incomplete && $0 == 0) ? $0 : nil } : nil
        dailyValue.stringValue = tokenText(daily)
        dailyValue.font = .monospacedDigitSystemFont(ofSize: daily == nil ? 13 : 23, weight: .medium)
        dailyScope.stringValue = L10n.text(enabled && latest.incomplete ? "이 Mac 기록 · 일부" : "이 Mac 기록")
        dailyValue.toolTip = L10n.text("이 Mac의 로컬 기록에 남은 UTC 오늘 토큰입니다. 계정 전체 사용량이 아닙니다.")
        modelsTitle.stringValue = L10n.text("모델별 · 오늘 TOP 3")
        modelsUnit.stringValue = L10n.text("토큰")
        modelsCard.toolTip = L10n.text("이 Mac의 UTC 오늘 기록에서 모델별 토큰 상위 3개입니다. 막대는 확인된 모든 모델 합계의 비중이며 모델 미상 토큰과 계정 전체 사용량을 포함하지 않습니다.")
        let models = enabled ? latest.models.filter { $0.totalTokens > 0 && modelName($0.model) != L10n.text("정보 없음") }.sorted {
            $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens
        } : []
        visibleModels = Array(models.prefix(3))
        let total = models.reduce(0.0) { $0 + Double($1.totalTokens) }
        modelsEmpty.isHidden = !models.isEmpty
        modelsEmpty.stringValue = L10n.text(!enabled ? "기록 읽기를 켜면 표시됩니다" :
            connected && !latest.incomplete && latest.recordsCount != nil ? "오늘 기록된 모델 사용량이 없습니다" : "모델 기록 정보 없음")
        for index in 0..<3 {
            let row = models.indices.contains(index) ? models[index] : nil
            modelNames[index].isHidden = row == nil
            modelValues[index].isHidden = row == nil
            modelBars[index].isHidden = row == nil
            if let row {
                modelNames[index].stringValue = modelName(row.model)
                modelValues[index].stringValue = tokenText(row.totalTokens)
                modelValues[index].toolTip = L10n.format("%lld 토큰", row.totalTokens)
                modelBars[index].fraction = total > 0 ? Double(row.totalTokens) / total : nil
                modelBars[index].setAccessibilityLabel(L10n.format("모델 %@, %lld 토큰", modelNames[index].stringValue, row.totalTokens))
            }
        }
        let notice = latest.noticeKey.flatMap { L10n.codexTranslations[$0] != nil ? L10n.text($0) : nil }
        let stale = enabled && !connected && latest.updatedAt != nil
        for card in [totalsCard, modelsCard] { card.alphaValue = stale ? 0.62 : 1 }
        updated.stringValue = !enabled ? L10n.text("기록 읽기 꺼짐") : latest.updatedAt.map {
            L10n.format(stale ? "이전 값 · %@" : "갱신 %@", dateText($0))
        } ?? notice ?? L10n.text("업데이트 정보 없음")
        updated.toolTip = enabled && latest.incomplete ? L10n.text("검사 범위나 읽기 제한 때문에 일부 기록만 집계했습니다. 표시값은 전체 사용량이 아닙니다.") : notice ?? L10n.text("이 Mac의 로컬 기록만 집계합니다")
        renderUsage()
        renderInsights()
        refreshButton.isEnabled = enabled || latest.quota.isEnabled
        refreshButton.toolTip = L10n.text("Codex 지금 새로고침")
        refreshButton.setAccessibilityLabel(L10n.text("Codex 지금 새로고침"))
    }

    private func layoutInsights() {
        var cards: [(NSView, CGFloat)] = [(totalsCard, 60), (usageCard, 108), (modelsCard, 82)]
        if expandedModel != nil { cards.append((modelDetailCard, modelDetailCard.cardHeight)) }
        modelDetailCard.isHidden = expandedModel == nil
        cards += [(breakdownCard, breakdownCard.cardHeight), (flowCard, 86), (weekCard, weekCard.cardHeight), (summaryCard, summaryCard.cardHeight)]
        var y: CGFloat = 0
        for (card, height) in cards {
            let rect = NSRect(x: 0, y: y, width: 258, height: height)
            if card.frame != rect { card.frame = rect }
            y += height + 8
        }
        let size = NSSize(width: 258, height: max(266, y - 8))
        if insightsDocument.frame.size != size { insightsDocument.frame.size = size }
    }
    @objc private func modelClicked(_ sender: NSButton) {
        guard visibleModels.indices.contains(sender.tag) else { return }
        let model = visibleModels[sender.tag].model
        expandedModel = expandedModel == model ? nil : model
        renderInsights(); layoutInsights()
    }
    @objc private func summaryClicked() {
        if latest.quota.connection != .connected { accountAction?() }
        else if latest.quota.usage.state == .disabled { usageAction?() }
        else { summaryAction?() }
    }
    private func renderInsights() {
        func ratio(_ fraction: Double?) -> String { fraction.map { L10n.format("%.0f%%", $0 * 100) } ?? L10n.text("정보 없음") }
        let localHelp = L10n.text("이 Mac의 로컬 기록 기준입니다. 캐시는 입력에, 추론은 출력에 포함되며 합계에 다시 더하지 않습니다.")
        func breakdown(_ models: [CodexModelUsage], into card: CodexInsightGrid, title: String) {
            let value = latest.recordsEnabled ? CodexTokenBreakdown.aggregate(models, knownEmpty: latest.recordsCount == 0 && !latest.incomplete) : nil
            card.update(title: title, values: [tokenText(value?.input), tokenText(value?.output), ratio(value?.cacheFraction), ratio(value?.reasoningFraction)], help: localHelp)
            card.composition.fraction = value?.inputFraction
        }
        breakdown(latest.models, into: breakdownCard, title: L10n.text("토큰 구성 · 이 Mac"))
        if let selected = expandedModel, let usage = visibleModels.first(where: { $0.model == selected }) {
            breakdown([usage], into: modelDetailCard, title: selected)
        } else { expandedModel = nil }
        for (index, button) in modelButtons.enumerated() {
            button.isHidden = !visibleModels.indices.contains(index)
            modelChevrons[index].isHidden = button.isHidden
            if visibleModels.indices.contains(index) {
                modelChevrons[index].image = expandedModel == visibleModels[index].model ? openChevron : closedChevron
                button.setAccessibilityLabel(L10n.format("모델 %@ 상세 보기", visibleModels[index].model))
                button.toolTip = L10n.text("누르면 입력·출력·캐시·추론 비중을 펼칩니다")
            }
        }
        flowTitle.stringValue = L10n.text("최근 10분 · 이 Mac 기록")
        let minutes = latest.recordsEnabled ? latest.recentMinutes : []
        minuteChart.update(minutes)
        let observed = minutes.compactMap(\.tokens)
        var minuteTotal: Int64? = observed.isEmpty ? nil : 0
        for value in observed {
            guard value >= 0, let before = minuteTotal, before <= Int64.max - value else { minuteTotal = nil; break }
            minuteTotal = before + value
        }
        flowValue.stringValue = tokenText(minuteTotal)
        flowCard.toolTip = L10n.text("기록 시각별 1분 증가량입니다. 실시간 생성 속도나 실제 작업 시간을 뜻하지 않으며 빈 구간은 정보 없음입니다.")
        let usage = latest.quota.usage
        let fresh = latest.quota.connection == .connected && usage.isFresh(at: renderNow)
        let week = CodexWeekInsight.aggregate(fresh ? usage.days : [])
        weekCard.update(title: L10n.text("최근 7일 요약 · 계정"), values: [tokenText(week.count > 0 ? week.total : nil), tokenText(week.average), week.peakDay.map { String($0.suffix(5)).replacingOccurrences(of: "-", with: "/") } ?? L10n.text("정보 없음"), "\(week.count)/7"], help: L10n.text("서버가 제공한 날짜만 계산합니다. 오늘은 진행 중일 수 있고 빈 날짜는 0으로 계산하지 않습니다."))
        let summaryTitle = L10n.text("계정 활동 요약")
        if latest.quota.connection != .connected {
            summaryCard.show(title: summaryTitle, message: usageStatus.stringValue,
                action: usageConnectButton.isHidden ? nil : usageConnectButton.title)
        } else if !usage.summaryEnabled {
            summaryCard.show(title: summaryTitle, message: "동의 후 계정 요약을 표시합니다", action: "계정 요약 연결")
        } else if !fresh {
            summaryCard.show(title: summaryTitle, message: "사용량 통계 갱신 대기 중", action: "계정 요약 관리")
        } else {
            let summary = usage.summary
            func days(_ n: Int64?) -> String { n.map { L10n.format("%lld일", $0) } ?? L10n.text("정보 없음") }
            // The service may return any subset. Missing values never become zero.
            let turn = summary.longestRunningTurnSec.flatMap { $0 <= 315_576_000 ? duration(Double($0)) : nil } ?? L10n.text("정보 없음")
            summaryCard.update(title: summaryTitle, values: [tokenText(summary.lifetimeTokens), tokenText(summary.peakDailyTokens), days(summary.currentStreakDays), days(summary.longestStreakDays), turn], help: L10n.text("OpenAI가 반환한 계정 요약입니다. 최장 턴은 실제 집중 작업 시간이 아니며 미제공 수치는 정보 없음입니다."))
            summaryCard.action.title = L10n.text("계정 요약 관리")
            summaryCard.action.isHidden = false
            // Keep the action in the unused final grid cell.
            summaryCard.actionInLastCell = true
        }
        layoutInsights()
    }

    private func renderUsage() {
        let usage = latest.quota.usage
        usageTitle.stringValue = L10n.text("최근 7일")
        usageScope.title = L10n.text("계정 토큰")
        usageScope.toolTip = L10n.text("로그인한 계정의 서버 집계 일별 토큰 · 최근 7일 · 약 5분마다 갱신. 이 Mac의 로컬 집계·잔여 한도와 다릅니다. 입력·출력·캐시 구성과 집계 시간대는 제공되지 않습니다. 누르면 연결을 관리합니다.")
        usageScope.setAccessibilityLabel(usageScope.toolTip)
        let accountConnected = latest.quota.connection == .connected
        let ready = accountConnected && usage.isFresh(at: renderNow) && usage.days.contains { $0.tokens != nil }
        usageChart.isHidden = !ready; usageStatus.isHidden = ready
        usageChart.update(ready ? usage.days : [])
        let key: String
        let actionKey: String
        var connecting = false
        switch latest.quota.connection {
        case .disconnected, .needsLogin:
            key = "로그인 후 계정 토큰을 볼 수 있습니다"
            actionKey = "ChatGPT 로그인"
        case .authorizing:
            key = "브라우저에서 로그인을 완료하세요"
            actionKey = "ChatGPT 로그인"; connecting = true
        case .connecting:
            key = "계정 연결 확인 중"
            actionKey = "ChatGPT 로그인"; connecting = true
        case .disconnecting:
            key = "계정 연결 해제 중"
            actionKey = "ChatGPT 로그인"; connecting = true
        case .helperMissing:
            key = "지원되는 Codex 앱이 필요합니다"
            actionKey = "ChatGPT 한도 관리"
        case .unavailable:
            key = "계정 연결을 확인해 주세요"
            actionKey = "ChatGPT 한도 관리"
        case .connected:
            switch usage.state {
            case .disabled: key = "동의 후 계정 토큰 그래프를 표시합니다"
            case .loading: key = "사용량 통계 확인 중"
            case .unavailable: key = "사용량 통계가 제공되지 않았습니다"
            case .ready: key = usage.isFresh(at: renderNow) ? "표시할 날짜별 통계가 없습니다" : "사용량 통계 갱신 대기 중"
            }
            actionKey = usage.state == .disabled ? "사용량 그래프 연결" : "통계 연결 끄기"
        }
        usageStatus.stringValue = L10n.text(key)
        usageConnectButton.isHidden = ready || connecting
        usageConnectButton.title = L10n.text(actionKey)
        usageConnectButton.setAccessibilityLabel(usageConnectButton.title)
        usageCard.toolTip = L10n.text("서버가 반환한 날짜별 토큰입니다. 빈 날짜는 정보 없음이며 0이 아닙니다.")
    }

    private func renderQuota() {
        let quota = latest.quota
        activityCard.isHidden = quota.isEnabled
        quotaCard.isHidden = !quota.isEnabled
        quotaElapsed.isHidden = !quota.isEnabled
        quotaElapsed.stringValue = elapsed.stringValue
        quotaElapsed.toolTip = elapsed.toolTip
        accountButton.contentTintColor = quota.connection == .connected ? PanelColor.blue : .secondaryLabelColor
        accountButton.toolTip = L10n.text(quota.isEnabled ? "ChatGPT 한도 관리" : "ChatGPT 한도 연결")
        accountButton.setAccessibilityLabel(accountButton.toolTip)
        accountButton.isEnabled = quota.connection != .disconnecting
        quotaCard.toolTip = L10n.text("계정의 Codex 한도입니다. 로컬 토큰 집계와 별개이며 리셋 후에는 서버 확인을 기다립니다.")
        if quota.isEnabled { connection.update(L10n.text("계정 한도"), color: quota.connection == .connected ? PanelColor.blue : .secondaryLabelColor) }
        let showRows = quota.isFresh(at: renderNow) && !quota.windows.isEmpty
        quotaStatus.isHidden = showRows
        let statusKey: String
        switch quota.connection {
        case .disconnected: statusKey = "ChatGPT 한도 연결"
        case .disconnecting: statusKey = "계정 연결 해제 중"
        case .connecting: statusKey = "계정 한도 확인 중"
        case .authorizing: statusKey = "브라우저에서 로그인을 완료하세요"
        case .connected: statusKey = quota.windows.isEmpty ? "한도 정보 없음" : "한도 갱신 대기 중"
        case .unavailable: statusKey = "한도를 확인할 수 없습니다 · 계정 버튼으로 재시도"
        case .needsLogin: statusKey = "ChatGPT 로그인이 필요합니다"
        case .helperMissing: statusKey = "지원되는 Codex 앱이 필요합니다"
        }
        quotaStatus.stringValue = L10n.text(statusKey)
        for index in 0..<2 {
            let window = quota.windows.indices.contains(index) ? quota.windows[index] : nil
            for field in [quotaTitles[index], quotaValues[index], quotaResets[index]] { field.isHidden = !showRows || window == nil }
            quotaBars[index].isHidden = !showRows || window == nil
            guard let window else { continue }
            let y = CGFloat(quota.windows.count == 1 ? 20 : 7 + index * 27)
            quotaTitles[index].frame.origin.y = y
            quotaValues[index].frame.origin.y = y - 1
            quotaResets[index].frame.origin.y = y
            quotaBars[index].frame.origin.y = y + 17
            if let minutes = window.durationMinutes {
                let unit = minutes % 1440 == 0 ? "d" : minutes % 60 == 0 ? "h" : "m"
                let number = minutes % 1440 == 0 ? minutes / 1440 : minutes % 60 == 0 ? minutes / 60 : minutes
                quotaTitles[index].stringValue = "\(number)\(unit)"
            } else { quotaTitles[index].stringValue = L10n.text(window.slot == 0 ? "단기 한도" : "장기 한도") }
            let remaining = window.remaining(at: renderNow)
            quotaValues[index].stringValue = remaining.map { L10n.format("잔여 %.0f%%", $0) } ?? "—"
            quotaValues[index].textColor = quota.blocked || (remaining ?? 100) < 10 ? .systemRed : (remaining ?? 100) < 25 ? .systemOrange : .labelColor
            quotaBars[index].color = quota.blocked || (remaining ?? 100) < 10 ? .systemRed : (remaining ?? 100) < 25 ? .systemOrange : PanelColor.blue
            quotaBars[index].fraction = remaining.map { $0 / 100 }
            if quota.blocked {
                quotaResets[index].stringValue = L10n.text("계정 사용 제한")
            } else if let reset = window.resetsAt {
                let seconds = reset.timeIntervalSince(renderNow)
                if seconds <= 0 { quotaResets[index].stringValue = L10n.text("리셋 확인 중") }
                else {
                    let total = Int(ceil(min(seconds, 315_576_000)))
                    let text = total >= 86400 ? String(format: "%dd %02d:%02d", total / 86400, total / 3600 % 24, total / 60 % 60) : String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                    quotaResets[index].stringValue = L10n.format("리셋 %@", text)
                }
            } else { quotaResets[index].stringValue = L10n.text("리셋 정보 없음") }
            quotaBars[index].setAccessibilityLabel([quotaTitles[index].stringValue, quotaValues[index].stringValue, quotaResets[index].stringValue].joined(separator: ", "))
        }
    }

}

#if PANEL_UPDATES_PROBE
extension CodexPanelController {
    var probeQuotaStrings: [String] { quotaTitles.map(\.stringValue) + quotaValues.map(\.stringValue) + quotaResets.map(\.stringValue) }
    var probeQuotaIsVisible: Bool { !quotaCard.isHidden }
    var probeQuotaStatus: String { quotaStatus.stringValue }
    var probeQuotaVisibleRows: Int { quotaTitles.filter { !$0.isHidden }.count }
    func probeSetVisible(_ visible: Bool) { probeVisible = visible }
    func probeRefresh() { refreshButton.performClick(nil) }
    var probeUsageReady: Bool { !usageChart.isHidden }
    var probeUsageStatus: String { usageStatus.stringValue }
    var probeUsageTitle: String { usageTitle.stringValue }
    func probeHoverUsage(at point: NSPoint) { usageChart.probeHover(at: point) }
    func probeExitUsage() { usageChart.probeExit() }
    var probeUsageHoverFrame: NSRect? { usageChart.probeHoverFrame }
    var probeUsageHoverValue: String { usageChart.probeHoverValue }
    var probeUsageHoverDay: String? { usageChart.probeHoverDay }
    var probeUsageSource: String { usageScope.title }
    var probeUsageButtonTitle: String { usageConnectButton.title }
    var probeUsageButtonVisible: Bool { !usageConnectButton.isHidden }
    func probeClickUsageAction() { usageConnectButton.performClick(nil) }
    var probeChartFrame: NSRect { usageChart.frame }
    func probeExpandModel(_ index: Int) { modelButtons[index].performClick(nil); view.layoutSubtreeIfNeeded() }
    var probeBreakdown: [String] { breakdownCard.probeValues }
    var probeModelDetails: [String] { modelDetailCard.isHidden ? [] : modelDetailCard.probeValues }
    var probeWeek: [String] { weekCard.probeValues }
    var probeSummary: [String] { summaryCard.probeValues }
    var probeInsightsHeight: CGFloat { insightsDocument.frame.height }
    func probeScrollInsights(_ y: CGFloat) {
        insightsScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, insightsDocument.frame.height - insightsScroll.contentSize.height))))
        insightsScroll.reflectScrolledClipView(insightsScroll.contentView)
    }
    var probeSeparateCardsVisible: Bool { !usageCard.isHidden && !modelsCard.isHidden && !usageCard.frame.intersects(modelsCard.frame) }
    var probeStrings: [String: String] {
        ["activity": activity.stringValue, "elapsed": elapsed.stringValue, "model": model.stringValue,
         "counts": counts.stringValue, "dailyTitle": dailyTitle.stringValue, "daily": dailyValue.stringValue,
         "scope": dailyScope.stringValue,
         "modelsTitle": modelsTitle.stringValue, "updated": updated.stringValue, "notice": updated.toolTip ?? "",
         "elapsedNotice": elapsed.toolTip ?? ""]
    }
    var probeModelNames: [String] { modelNames.filter { !$0.isHidden }.map(\.stringValue) }
    var probeModelFractions: [Double?] { modelBars.filter { !$0.isHidden }.map(\.fraction) }
    var probeCardsAreDimmed: Bool { totalsCard.alphaValue < 1 }
}
#endif
