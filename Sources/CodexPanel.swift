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

/// Numeric local-record metadata only. This view never opens history files or reads task text.
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
    private let recordsCard = GlassCard()
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
    private let recordsTitle = codexText(size: 11, weight: .semibold)
    private let recordsPrivacy = codexText(size: 9, secondary: true, lines: 2)
    private let recordsStatus = codexText(size: 9, secondary: true)
    private lazy var recordsSwitch: NSSwitch = {
        let control = NSSwitch()
        control.target = self
        control.action = #selector(recordsChanged)
        return control
    }()
    private let updated = codexText(size: 9, secondary: true, digits: true)
    private lazy var refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(refreshNow))
    var refresh: (() -> Void)?
    var recordsEnabledChanged: ((Bool) -> Void)?
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
        codexPlace(recordsCard, in: canvas, 12, 308, 276, 78)
        codexPlace(recordsTitle, in: recordsCard, 12, 8, 198, 17)
        codexPlace(recordsSwitch, in: recordsCard, 224, 7, 40, 23)
        codexPlace(recordsPrivacy, in: recordsCard, 12, 31, 252, 27)
        codexPlace(recordsStatus, in: recordsCard, 12, 60, 252, 14)
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
    @objc private func recordsChanged() {
        let enabled = recordsSwitch.state == .on
        guard latest.recordsEnabled != enabled else { return }
        latest.recordsEnabled = enabled
        latest.dailyTokens = nil
        latest.models = []
        latest.currentModel = nil
        latest.recordsCount = nil
        latest.lastRecordAt = nil
        latest.updatedAt = nil
        latest.incomplete = false
        latest.noticeKey = nil
        if enabled { latest.connection = .connecting }
        render()
        recordsEnabledChanged?(enabled)
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
        dailyTitle.stringValue = L10n.text("오늘 토큰 (UTC)")
        let daily = enabled ? latest.dailyTokens.flatMap { $0 >= 0 && !(latest.incomplete && $0 == 0) ? $0 : nil } : nil
        dailyValue.stringValue = tokenText(daily)
        dailyValue.font = .monospacedDigitSystemFont(ofSize: daily == nil ? 13 : 23, weight: .medium)
        dailyScope.stringValue = L10n.text(enabled && latest.incomplete ? "이 Mac 기록 · 일부" : "이 Mac 기록")
        dailyValue.toolTip = L10n.text("이 Mac의 로컬 기록에 남은 UTC 오늘 토큰입니다. 계정 전체 사용량이 아닙니다.")
        timeTitle.stringValue = L10n.text("최근 기록")
        let recordedAt = enabled ? latest.lastRecordAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil } : nil
        timeValue.stringValue = dateText(recordedAt, short: true)
        timeValue.font = .monospacedDigitSystemFont(ofSize: recordedAt == nil ? 13 : 20, weight: .medium)
        timeScope.stringValue = L10n.text("현지 시각")
        timeValue.toolTip = L10n.text("마지막 유효한 로컬 토큰 기록의 시각입니다. 이 Mac의 시간대로 표시합니다.")
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
        recordsTitle.stringValue = L10n.text("로컬 기록 읽기")
        recordsSwitch.state = enabled ? .on : .off
        recordsSwitch.toolTip = L10n.text("켜면 이 Mac의 Codex 대화 기록 파일에서 모델명·토큰 숫자·시각을 추출해 집계합니다. 끄면 읽기를 중단하며 본문은 보관·표시·전송하지 않습니다.")
        recordsSwitch.setAccessibilityLabel(L10n.text("로컬 기록 읽기"))
        recordsPrivacy.stringValue = L10n.text("대화 기록 파일에서 추출 · 본문 저장·표시·전송 없음")
        recordsPrivacy.toolTip = L10n.text("이 Mac의 Codex 대화 기록 파일에서 모델명·토큰 숫자·시각만 추출해 집계합니다. 본문은 보관·표시·전송하지 않습니다.")
        let notice = latest.noticeKey.flatMap { L10n.codexTranslations[$0] != nil ? L10n.text($0) : nil }
        if !enabled { recordsStatus.stringValue = L10n.text("꺼짐 · 기본값") }
        else if latest.incomplete { recordsStatus.stringValue = L10n.text("일부 기록만 집계") }
        else if latest.connection == .connecting { recordsStatus.stringValue = L10n.text("로컬 기록 확인 중") }
        else if connected { recordsStatus.stringValue = L10n.text("읽기 전용 · 외부 전송 없음") }
        else { recordsStatus.stringValue = notice ?? L10n.text("로컬 기록을 읽을 수 없습니다") }
        recordsStatus.textColor = enabled && (latest.incomplete || latest.connection == .unavailable) ? .systemOrange : .secondaryLabelColor
        recordsStatus.toolTip = enabled && latest.incomplete ? L10n.text("검사 범위나 읽기 제한 때문에 일부 기록만 집계했습니다. 표시값은 전체 사용량이 아닙니다.") : recordsStatus.stringValue
        recordsStatus.setAccessibilityLabel(recordsStatus.toolTip)
        let stale = enabled && !connected && latest.updatedAt != nil
        for card in [totalsCard, modelsCard] { card.alphaValue = stale ? 0.62 : 1 }
        updated.stringValue = !enabled ? L10n.text("기록 읽기 꺼짐") : latest.updatedAt.map {
            L10n.format(stale ? "이전 값 · %@" : "갱신 %@", dateText($0))
        } ?? notice ?? L10n.text("업데이트 정보 없음")
        updated.toolTip = enabled && latest.incomplete ? recordsStatus.toolTip : notice ?? L10n.text("이 Mac의 로컬 기록만 집계합니다")
        refreshButton.isEnabled = enabled
        refreshButton.toolTip = L10n.text("Codex 지금 새로고침")
        refreshButton.setAccessibilityLabel(L10n.text("Codex 지금 새로고침"))
    }

}

#if PANEL_UPDATES_PROBE
extension CodexPanelController {
    func probeSetVisible(_ visible: Bool) { probeVisible = visible }
    func probeRefresh() { refreshButton.performClick(nil) }
    func probeSetRecordsEnabled(_ enabled: Bool) {
        recordsSwitch.state = enabled ? .on : .off
        recordsSwitch.sendAction(recordsSwitch.action, to: recordsSwitch.target)
    }
    var probeRecordsEnabled: Bool { recordsSwitch.state == .on }
    var probeStrings: [String: String] {
        ["activity": activity.stringValue, "elapsed": elapsed.stringValue, "model": model.stringValue,
         "counts": counts.stringValue, "dailyTitle": dailyTitle.stringValue, "daily": dailyValue.stringValue,
         "scope": dailyScope.stringValue, "time": timeValue.stringValue, "timeScope": timeScope.stringValue,
         "modelsTitle": modelsTitle.stringValue, "updated": updated.stringValue, "notice": updated.toolTip ?? "",
         "elapsedNotice": elapsed.toolTip ?? "", "recordsTitle": recordsTitle.stringValue,
         "recordsPrivacy": recordsPrivacy.stringValue, "recordsStatus": recordsStatus.stringValue]
    }
    var probeModelNames: [String] { modelNames.filter { !$0.isHidden }.map(\.stringValue) }
    var probeModelFractions: [Double?] { modelBars.filter { !$0.isHidden }.map(\.fraction) }
    var probeCardsAreDimmed: Bool { totalsCard.alphaValue < 1 }
}
#endif
