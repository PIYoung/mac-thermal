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
    private var language = ""
    func update(_ values: [CodexDailyUsage]) {
        let next = Array(values.prefix(7)), locale = L10n.language.rawValue
        guard next != days || locale != language else { return }
        days = next; language = locale; hovered = nil
        let labels = days.map { "\($0.day): " + ($0.tokens.map(Self.compact) ?? L10n.text("정보 없음")) }
        setAccessibilityElement(true)
        setAccessibilityLabel(L10n.text("최근 7일 계정 토큰 사용량") + ", " + labels.joined(separator: ", "))
        toolTip = L10n.text("서버가 반환한 날짜별 토큰입니다. 빈 날짜는 정보 없음이며 0이 아닙니다.")
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard days.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = max(0, min(days.count - 1, Int(((point.x - 4) / max(1, bounds.width - 8) * CGFloat(days.count - 1)).rounded())))
        guard hovered != index else { return }
        hovered = index
        toolTip = days[index].day + " · " + (days[index].tokens.map { L10n.format("%lld 토큰", $0) } ?? L10n.text("정보 없음"))
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
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
        if let hovered, days.indices.contains(hovered), let tokens = days[hovered].tokens {
            let selected = point(hovered, tokens)
            color.withAlphaComponent(0.12).setFill(); NSBezierPath(ovalIn: NSRect(x: selected.x - 5, y: selected.y - 5, width: 10, height: 10)).fill()
            color.setFill(); NSBezierPath(ovalIn: NSRect(x: selected.x - 2.5, y: selected.y - 2.5, width: 5, height: 5)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for index in [0, days.count - 1] {
            let label = String(days[index].day.suffix(5)).replacingOccurrences(of: "-", with: "/") as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: index == 0 ? 1 : bounds.width - width - 1, y: bounds.height - 12), withAttributes: attributes)
        }
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
        codexPlace(totalsCard, in: canvas, 12, 120, 276, 60)
        codexPlace(dailyTitle, in: totalsCard, 12, 9, 126, 16)
        codexPlace(dailyValue, in: totalsCard, 10, 27, 254, 27)
        dailyScope.alignment = .right
        codexPlace(dailyScope, in: totalsCard, 138, 11, 126, 13)
        codexPlace(modelsCard, in: canvas, 12, 304, 276, 82)
        codexPlace(modelsTitle, in: modelsCard, 12, 5, 174, 17)
        modelsUnit.alignment = .right
        codexPlace(modelsUnit, in: modelsCard, 188, 7, 76, 14)
        for index in 0..<3 {
            let y = CGFloat(25 + index * 17)
            codexPlace(modelNames[index], in: modelsCard, 12, y, 167, 13)
            modelValues[index].alignment = .right
            codexPlace(modelValues[index], in: modelsCard, 184, y, 80, 13)
            modelBars[index].color = [PanelColor.blue, PanelColor.violet, PanelColor.teal][index]
            codexPlace(modelBars[index], in: modelsCard, 12, y + 13, 252, 2)
        }
        codexPlace(modelsEmpty, in: modelsCard, 12, 29, 252, 36)
        codexPlace(usageCard, in: canvas, 12, 188, 276, 108)
        codexPlace(usageTitle, in: usageCard, 12, 9, 104, 17)
        usageScope.isBordered = false; usageScope.contentTintColor = .secondaryLabelColor
        usageScope.font = .systemFont(ofSize: 9); usageScope.alignment = .right
        codexPlace(usageScope, in: usageCard, 168, 7, 96, 20)
        codexPlace(usageChart, in: usageCard, 12, 30, 252, 67)
        usageStatus.alignment = .center
        codexPlace(usageStatus, in: usageCard, 12, 31, 252, 28)
        usageConnectButton.isBordered = false; usageConnectButton.contentTintColor = PanelColor.blue
        usageConnectButton.font = .systemFont(ofSize: 10, weight: .medium)
        codexPlace(usageConnectButton, in: usageCard, 66, 65, 144, 23)
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
    @objc private func usageClicked() { usageAction?() }
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
        refreshButton.isEnabled = enabled || latest.quota.isEnabled
        refreshButton.toolTip = L10n.text("Codex 지금 새로고침")
        refreshButton.setAccessibilityLabel(L10n.text("Codex 지금 새로고침"))
    }

    private func renderUsage() {
        let usage = latest.quota.usage
        usageTitle.stringValue = L10n.text("최근 7일")
        usageScope.title = L10n.text("계정 통계")
        usageScope.toolTip = L10n.text("사용량 그래프 연결 관리")
        usageScope.setAccessibilityLabel(usageScope.toolTip)
        let ready = usage.isFresh(at: renderNow) && usage.days.contains { $0.tokens != nil }
        usageChart.isHidden = !ready; usageStatus.isHidden = ready
        usageChart.update(ready ? usage.days : [])
        let key: String
        switch usage.state {
        case .disabled: key = "날짜별 사용량을 그래프로 확인하세요"
        case .loading: key = "사용량 통계 확인 중"
        case .unavailable: key = "사용량 통계가 제공되지 않았습니다"
        case .ready: key = usage.isFresh(at: renderNow) ? "표시할 날짜별 통계가 없습니다" : "사용량 통계 갱신 대기 중"
        }
        usageStatus.stringValue = L10n.text(key)
        usageConnectButton.isHidden = ready
        usageConnectButton.title = L10n.text(usage.state == .disabled ? "사용량 그래프 연결" : "통계 연결 끄기")
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
    var probeChartFrame: NSRect { usageChart.frame }
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
