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

/// Numeric Codex metadata only. No local history, credentials or task text is read here.
final class CodexPanelController: NSViewController {
    static let surfaceSize = NSSize(width: 300, height: 420)
    static let size = NSSize(width: 348, height: 468)

    private var latest = CodexMonitorSnapshot.pending
    private var renderNow = Date()
    private var languageObserver: NSObjectProtocol?
    private let connection = CodexPill(frame: .zero)
    private let activityCard = GlassCard()
    private let totalsCard = GlassCard()
    private let modelsCard = GlassCard()
    private let quotaCard = GlassCard()
    private let activity = codexText(size: 12, weight: .semibold)
    private let elapsed = codexText(size: 11, weight: .medium, digits: true)
    private let model = codexText(size: 10, secondary: true)
    private let counts = codexText(size: 10, secondary: true, digits: true)
    private let dailyTitle = codexText(size: 10, weight: .medium)
    private let dailyValue = codexText(size: 23, weight: .medium, digits: true)
    private let dailyScope = codexText(size: 9, secondary: true)
    private let timeTitle = codexText(size: 10, weight: .medium)
    private let timeValue = codexText(size: 20, weight: .medium, digits: true)
    private let timeScope = codexText(size: 9, secondary: true)
    private let modelsTitle = codexText(size: 11, weight: .semibold)
    private let modelsUnit = codexText(size: 9, secondary: true)
    private let modelNames = (0..<3).map { _ in codexText(size: 10, weight: .medium) }
    private let modelValues = (0..<3).map { _ in codexText(size: 10, weight: .medium, digits: true) }
    private let modelBars = (0..<3).map { _ in CodexBar() }
    private let modelsEmpty = codexText(size: 10, secondary: true, lines: 2)
    private let quotaTitle = codexText(size: 11, weight: .semibold)
    private let quotaLegend = codexText(size: 9, secondary: true)
    private let quotaNames = (0..<2).map { _ in codexText(size: 9, weight: .medium) }
    private let quotaValues = (0..<2).map { _ in codexText(size: 10, weight: .medium, digits: true) }
    private let quotaResets = (0..<2).map { _ in codexText(size: 9, secondary: true, digits: true) }
    private let quotaBars = (0..<2).map { _ in CodexBar() }
    private let quotaEmpty = codexText(size: 10, secondary: true)
    private let updated = codexText(size: 9, secondary: true, digits: true)
    private lazy var refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(refreshNow))
    var refresh: (() -> Void)?
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
        codexPlace(brand, in: canvas, 42, 12, 156, 25)
        codexPlace(connection, in: canvas, 205, 15, 80, 21)
        codexPlace(activityCard, in: canvas, 12, 48, 276, 64)
        codexPlace(activity, in: activityCard, 12, 10, 142, 19)
        elapsed.alignment = .right
        codexPlace(elapsed, in: activityCard, 156, 12, 108, 16)
        codexPlace(model, in: activityCard, 12, 37, 140, 16)
        counts.alignment = .right
        codexPlace(counts, in: activityCard, 152, 37, 112, 16)
        codexPlace(totalsCard, in: canvas, 12, 120, 276, 72)
        codexPlace(dailyTitle, in: totalsCard, 12, 9, 118, 16)
        codexPlace(dailyValue, in: totalsCard, 10, 27, 120, 29)
        codexPlace(dailyScope, in: totalsCard, 12, 55, 118, 13)
        codexPlace(timeTitle, in: totalsCard, 150, 9, 114, 16)
        codexPlace(timeValue, in: totalsCard, 148, 29, 116, 27)
        codexPlace(timeScope, in: totalsCard, 150, 55, 114, 13)
        let divider = NSBox()
        divider.boxType = .separator
        codexPlace(divider, in: totalsCard, 138, 14, 1, 44)
        codexPlace(modelsCard, in: canvas, 12, 200, 276, 100)
        codexPlace(modelsTitle, in: modelsCard, 12, 9, 174, 17)
        modelsUnit.alignment = .right
        codexPlace(modelsUnit, in: modelsCard, 188, 11, 76, 14)
        for index in 0..<3 {
            let y = CGFloat(32 + index * 22)
            codexPlace(modelNames[index], in: modelsCard, 12, y, 167, 14)
            modelValues[index].alignment = .right
            codexPlace(modelValues[index], in: modelsCard, 184, y, 80, 14)
            modelBars[index].color = [PanelColor.blue, PanelColor.violet, PanelColor.teal][index]
            codexPlace(modelBars[index], in: modelsCard, 12, y + 16, 252, 3)
        }
        codexPlace(modelsEmpty, in: modelsCard, 12, 40, 252, 36)
        codexPlace(quotaCard, in: canvas, 12, 308, 276, 78)
        codexPlace(quotaTitle, in: quotaCard, 12, 8, 132, 17)
        quotaLegend.alignment = .right
        codexPlace(quotaLegend, in: quotaCard, 151, 10, 113, 14)
        for index in 0..<2 {
            let y = CGFloat(29 + index * 22)
            codexPlace(quotaNames[index], in: quotaCard, 12, y, 47, 14)
            quotaValues[index].alignment = .right
            codexPlace(quotaValues[index], in: quotaCard, 60, y, 85, 14)
            quotaResets[index].alignment = .right
            codexPlace(quotaResets[index], in: quotaCard, 151, y, 113, 14)
            codexPlace(quotaBars[index], in: quotaCard, 12, y + 16, 133, 3)
        }
        codexPlace(quotaEmpty, in: quotaCard, 12, 39, 252, 17)
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
    func prepareForPresentation() { _ = view; render() }
    @objc private func refreshNow() { refresh?() }

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
    private func quotaName(_ quota: CodexQuota, index: Int) -> String {
        guard let minutes = quota.windowMinutes, minutes > 0 else { return L10n.format("한도 %d", index + 1) }
        if minutes % 1_440 == 0 { return L10n.format("%d일", minutes / 1_440) }
        if minutes % 60 == 0 { return L10n.format("%d시간", minutes / 60) }
        return L10n.format("%d분", minutes)
    }
    private func dateText(_ date: Date?, reset: Bool = false) -> String {
        guard let date, date.timeIntervalSince1970.isFinite else { return L10n.text("정보 없음") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate(reset ? "MMMdHHmm" : "HHmmss")
        return formatter.string(from: date)
    }
    private func render() {
        guard isViewLoaded else { return }
        let connected = latest.connection == .connected
        let connectionKey: String
        let connectionColor: NSColor
        switch latest.connection {
        case .notRunning: connectionKey = "실행 안 됨"; connectionColor = .secondaryLabelColor
        case .connecting: connectionKey = "연결 중"; connectionColor = PanelColor.blue
        case .connected: connectionKey = "연결됨"; connectionColor = .systemGreen
        case .unavailable: connectionKey = "연결 끊김"; connectionColor = .systemOrange
        }
        connection.update(L10n.text(connectionKey), color: connectionColor)
        let active = latest.activeCount.flatMap { $0 >= 0 ? $0 : nil }
        let waiting = latest.waitingCount.flatMap { $0 >= 0 ? $0 : nil }
        if !connected { activity.stringValue = L10n.text(connectionKey) }
        else if (active ?? 0) > 0 { activity.stringValue = L10n.text("작업 진행 중") }
        else if (waiting ?? 0) > 0 { activity.stringValue = L10n.text("입력 대기 중") }
        else if active == 0 && waiting == 0 { activity.stringValue = L10n.text("활동 없음") }
        else { activity.stringValue = L10n.text("정보 없음") }
        counts.stringValue = L10n.format("진행 %@ · 대기 %@", active.map(String.init) ?? "—", waiting.map(String.init) ?? "—")
        model.stringValue = modelName(latest.currentModel)
        model.toolTip = L10n.text("현재 관측된 모델")
        let currentElapsed = latest.currentStartedAt.flatMap { started in
            guard started.timeIntervalSince1970.isFinite else { return nil as TimeInterval? }
            return (connected ? renderNow : latest.updatedAt)?.timeIntervalSince(started)
        }
        if (active ?? 0) > 0 || (waiting ?? 0) > 0 {
            elapsed.stringValue = duration(currentElapsed)
            elapsed.toolTip = L10n.format("현재 작업 경과 %@", elapsed.stringValue)
        } else if latest.connection != .notRunning, let started = latest.appStartedAt,
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
        dailyTitle.stringValue = L10n.text("오늘 토큰 (UTC)")
        let daily = latest.dailyTokens.flatMap { $0 >= 0 ? $0 : nil }
        dailyValue.stringValue = tokenText(daily)
        dailyValue.font = .monospacedDigitSystemFont(ofSize: daily == nil ? 13 : 23, weight: .medium)
        dailyScope.stringValue = L10n.text("계정 집계")
        dailyValue.toolTip = L10n.text("UTC 기준으로 서버가 제공한 계정의 오늘 토큰입니다. 연결 이후 관측량과 다릅니다.")
        timeTitle.stringValue = L10n.text("활동 시간")
        let hasObservation = connected || latest.observedActiveSeconds > 0 || latest.observedTokens > 0 || !latest.models.isEmpty
        timeValue.stringValue = hasObservation ? duration(latest.observedActiveSeconds) : L10n.text("정보 없음")
        timeValue.font = .monospacedDigitSystemFont(ofSize: hasObservation ? 20 : 13, weight: .medium)
        timeScope.stringValue = L10n.text("이번 연결 관측")
        timeValue.toolTip = L10n.text("이번 연결에서 실제 관측한 작업 활동 시간입니다. 앱 실행 시간이나 계정의 일일 총 시간이 아닙니다.")
        modelsTitle.stringValue = L10n.text("모델별 · 관측")
        modelsUnit.stringValue = L10n.text("토큰")
        modelsCard.toolTip = L10n.text("이번 연결에서 관측한 모델별 토큰입니다. 막대는 관측된 모델 합계에 대한 비중이며 계정 일일 총량과 다릅니다.")
        let models = latest.models.filter { $0.totalTokens > 0 }.sorted { $0.totalTokens == $1.totalTokens ? $0.model < $1.model : $0.totalTokens > $1.totalTokens }
        let total = models.reduce(0.0) { $0 + Double($1.totalTokens) }
        modelsEmpty.isHidden = !models.isEmpty
        modelsEmpty.stringValue = L10n.text("아직 관측된 모델 사용량이 없습니다")
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
        quotaTitle.stringValue = L10n.text("사용 한도")
        quotaLegend.stringValue = L10n.text("사용 / 잔여")
        quotaEmpty.stringValue = L10n.text("한도 정보 없음")
        quotaEmpty.isHidden = !latest.quotas.isEmpty
        for index in 0..<2 {
            let quota = latest.quotas.indices.contains(index) ? latest.quotas[index] : nil
            for field in [quotaNames[index], quotaValues[index], quotaResets[index]] { field.isHidden = quota == nil }
            quotaBars[index].isHidden = quota == nil
            if let quota {
                let used = quota.usedPercent.isFinite && (0...100).contains(quota.usedPercent) ? quota.usedPercent : nil
                quotaNames[index].stringValue = quotaName(quota, index: index)
                quotaValues[index].stringValue = used.map { String(format: "%.0f%% / %.0f%%", $0, 100 - $0) } ?? L10n.text("정보 없음")
                quotaResets[index].stringValue = quota.resetsAt == nil ? L10n.text("정보 없음") : "↻ " + dateText(quota.resetsAt, reset: true)
                quotaResets[index].toolTip = L10n.format("재설정 %@", dateText(quota.resetsAt, reset: true))
                quotaResets[index].setAccessibilityLabel(quotaResets[index].toolTip)
                quotaBars[index].fraction = used.map { $0 / 100 }
                quotaValues[index].setAccessibilityLabel(L10n.format("한도 %@, 사용과 잔여 %@", quotaNames[index].stringValue, quotaValues[index].stringValue))
            }
        }
        let stale = !connected && latest.updatedAt != nil
        for card in [totalsCard, modelsCard, quotaCard] { card.alphaValue = stale ? 0.62 : 1 }
        let notice = latest.noticeKey.flatMap { L10n.codexTranslations[$0] != nil ? L10n.text($0) : nil }
        updated.stringValue = latest.updatedAt.map { L10n.format(stale ? "이전 값 · %@" : "갱신 %@", dateText($0)) } ?? notice ?? L10n.text("업데이트 정보 없음")
        updated.toolTip = notice ?? L10n.text("연결 이후 관측한 활동만 집계합니다")
        refreshButton.toolTip = L10n.text("Codex 지금 새로고침")
        refreshButton.setAccessibilityLabel(L10n.text("Codex 지금 새로고침"))
    }
}

#if PANEL_UPDATES_PROBE
extension CodexPanelController {
    func probeSetVisible(_ visible: Bool) { probeVisible = visible }
    func probeRefresh() { refreshButton.performClick(nil) }
    var probeStrings: [String: String] {
        ["activity": activity.stringValue, "elapsed": elapsed.stringValue, "model": model.stringValue,
         "dailyTitle": dailyTitle.stringValue, "daily": dailyValue.stringValue, "scope": dailyScope.stringValue, "time": timeValue.stringValue,
         "timeScope": timeScope.stringValue, "modelsTitle": modelsTitle.stringValue,
         "updated": updated.stringValue, "notice": updated.toolTip ?? "", "elapsedNotice": elapsed.toolTip ?? ""]
    }
    var probeModelNames: [String] { modelNames.filter { !$0.isHidden }.map(\.stringValue) }
    var probeModelFractions: [Double?] { modelBars.filter { !$0.isHidden }.map(\.fraction) }
    var probeQuotaValues: [String] { quotaValues.filter { !$0.isHidden }.map(\.stringValue) }
    var probeQuotaResets: [String] { quotaResets.filter { !$0.isHidden }.map(\.stringValue) }
    var probeQuotaFractions: [Double?] { quotaBars.filter { !$0.isHidden }.map(\.fraction) }
    var probeCardsAreDimmed: Bool { totalsCard.alphaValue < 1 }
}
#endif
