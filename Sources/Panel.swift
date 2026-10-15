import AppKit
import Foundation
import QuartzCore
import ObjectiveC

private enum PanelColor {
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

private class FlippedView: NSView {
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

private class GlassCard: FlippedView {
    var radius: CGFloat = 16
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: PanelColor.cardTop, ending: PanelColor.cardBottom)?.draw(in: path, angle: 90)
        PanelColor.edge.setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }
}

private final class PanelSurfaceHost: FlippedView {
    private let surfaceShadow = NSView()

    init(glass: NSView) {
        super.init(frame: NSRect(origin: .zero, size: PanelController.size))
        wantsLayer = true
        let inset = PanelController.surfaceInset
        let surfaceFrame = NSRect(origin: NSPoint(x: inset, y: inset), size: PanelController.surfaceSize)
        surfaceShadow.frame = surfaceFrame
        surfaceShadow.wantsLayer = true
        if let shadow = surfaceShadow.layer {
            shadow.masksToBounds = false
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = 0.18
            shadow.shadowRadius = 10
            shadow.shadowOffset = CGSize(width: 0, height: -3)
            shadow.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: PanelController.surfaceSize), cornerWidth: PanelController.cornerRadius, cornerHeight: PanelController.cornerRadius, transform: nil)
        }
        addSubview(surfaceShadow)
        glass.frame = surfaceFrame
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
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

private final class CPUHistoryGraph: FlippedView {
    private var history = CPUUsageHistory()
    var color = PanelColor.blue { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        localizedAccessibilityLabel(self, "CPU 사용률 최근 1분 그래프, 세로 눈금 0에서 100퍼센트")
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

    init(title: String, subtitle: String, icon: String, accent: NSColor) {
        super.init(frame: .zero)
        place(symbol(icon, color: accent), in: self, 14, 11, 13, 13)
        place(text(title, size: 11, weight: .semibold), in: self, 34, 9, 160, 17)
        let note = text(subtitle, size: 9, color: PanelColor.secondary)
        note.alignment = .right
        place(note, in: self, 204, 11, 125, 14)
        for index in 0..<3 {
            let y = CGFloat(34 + index * 25)
            ranks[index].alignment = .center
            place(ranks[index], in: self, 12, y + 1, 16, 16)
            place(names[index], in: self, 37, y, 189, 18)
            values[index].alignment = .right
            place(values[index], in: self, 230, y, 99, 18)
            if index < 2 {
                let separator = NSBox()
                separator.boxType = .separator
                place(separator, in: self, 37, y + 21, 292, 1)
            }
        }
        place(empty, in: self, 16, 59, 311, 18)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func update(_ processes: [ResourceProcess], emptyMessage: String, format: (ResourceProcess) -> String) {
        empty.isHidden = !processes.isEmpty
        empty.stringValue = emptyMessage
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
}

final class PanelController: NSViewController {
    static let surfaceSize = NSSize(width: 380, height: 468)
    static let surfaceInset: CGFloat = 24
    static let size = NSSize(width: surfaceSize.width + 2 * surfaceInset, height: surfaceSize.height + 2 * surfaceInset)
    static let cornerRadius: CGFloat = 22

    private let cpuTemp = text("—", size: 33, weight: .medium, digits: true)
    private let ssdTemp = text("—", size: 33, weight: .medium, digits: true)
    private let cpuCaption = text("코어 최고 온도", size: 9, color: PanelColor.secondary)
    private let ssdCaption = text("내장 저장장치", size: 9, color: PanelColor.secondary)
    private let cpuPercent = text("측정 중", size: 12, weight: .semibold, digits: true)
    private let cpuGraph = CPUHistoryGraph(frame: .zero)
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
    private let memoryPressureNote = text("메모리 압박 정보 없음", size: 10, color: PanelColor.secondary)
    private let memoryCompressed = text("—", size: 24, weight: .medium, digits: true)
    private let memorySwap = text("—", size: 24, weight: .medium, digits: true)
    private let processCount = text("정보 없음", size: 9, color: PanelColor.secondary)
    private let cpuRanking = ProcessRankingCard(title: "CPU 사용량", subtitle: "전체 CPU 기준", icon: "cpu", accent: PanelColor.blue)
    private let memoryRanking = ProcessRankingCard(title: "메모리 사용량", subtitle: "실제 점유 메모리", icon: "memorychip", accent: PanelColor.violet)
    private let diskFree = text("—", size: 31, weight: .medium, digits: true)
    private let diskCapacity = text("전체 용량 정보 없음", size: 11, color: PanelColor.secondary)
    private let diskPercent = text("—", size: 11, weight: .semibold, digits: true)
    private let diskBar = UsageBar()
    private let diskRead = text("측정 중", size: 20, weight: .medium, digits: true)
    private let diskWrite = text("측정 중", size: 20, weight: .medium, digits: true)
    private let diskReadGraph = Sparkline(color: PanelColor.blue)
    private let diskWriteGraph = Sparkline(color: PanelColor.violet)
    private var tabViews: [NSView] = []
    private let menuBarSettingsView = FlippedView()
    private var showingMenuBarSettings = false
    private var languageObserver: NSObjectProtocol?
    private var latestSnapshot = Snapshot.pending
    // Histories continue collecting while the panel or their tab is hidden.
    // Updating the AppKit views is deferred until they will actually be shown.
    private var cpuHistory = CPUUsageHistory()
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
    private var menuBarPreferences = MenuBarPreferences.load()
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
    private let tabDefaultsKey = "dashboardSelectedTabV2"
    private lazy var tabs: LiquidTabControl = {
        let control = LiquidTabControl(labels: ["요약", "메모리", "TOP 3", "SSD"].map(L10n.text), target: self, action: #selector(changeTab))
        localizedAccessibilityLabel(control, "시스템 모니터 탭")
        let saved = UserDefaults.standard.integer(forKey: tabDefaultsKey)
        control.selectedSegment = (0..<4).contains(saved) ? saved : 0
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
        place(brand, in: canvas, 16, 19, 36, 36)
        place(text("Mac Thermal", size: 15, weight: .semibold), in: canvas, 60, 19, 174, 20)
        place(uptimeLabel, in: canvas, 60, 41, 174, 14)
        localizedToolTip(uptimeLabel, "잠자기 시간을 포함한 부팅 후 경과 시간 · 1분 단위")
        place(menuBarSettingsButton, in: canvas, 338, 23, 24, 24)
        place(tabs, in: canvas, 18, 66, 344, 24)
        tabViews = (0..<4).map { _ in
            let content = FlippedView()
            content.wantsLayer = true
            place(content, in: canvas, 18, 100, 344, 289)
            return content
        }
        buildSummary(in: tabViews[0])
        buildMemory(in: tabViews[1])
        buildProcesses(in: tabViews[2])
        buildDisk(in: tabViews[3])
        place(menuBarSettingsView, in: canvas, 18, 66, 344, 363)
        buildMenuBarSettings()
        showSelectedTab()

        let footerLine = NSBox()
        footerLine.boxType = .separator
        place(footerLine, in: canvas, 20, 429, 340, 1)
        place(updated, in: canvas, 21, 437, 240, 15)
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.text("새로고침")) ?? NSImage(), target: self, action: #selector(refreshNow))
        let quitButton = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: L10n.text("종료")) ?? NSImage(), target: self, action: #selector(quitApp))
        for (button, title, x) in [(refreshButton, "지금 새로고침", CGFloat(306)), (quitButton, "Mac Thermal 종료", CGFloat(339))] {
            button.isBordered = false
            button.contentTintColor = PanelColor.secondary
            localizedToolTip(button, title)
            localizedAccessibilityLabel(button, title)
            place(button, in: canvas, x, 434, 21, 21)
        }
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLanguage()
        }
        apply(latestSnapshot, recordHistory: false)
        refreshLanguage()
    }

    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }

    private func refreshLanguage() {
        guard isViewLoaded else { return }
        refreshLocalizedViews(view)
        tabs.updateLabels(["요약", "메모리", "TOP 3", "SSD"].map(L10n.text))
        animationStyleControl.removeAllItems()
        animationStyleControl.addItems(withTitles: [MenuBarAnimationStyle.rhythm.title, MenuBarAnimationStyle.orbit.title])
        languageControl.selectItem(at: AppLanguage.allCases.firstIndex(of: L10n.language) ?? 0)
        updateMenuBarControls()
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
        place(language, in: menuBarSettingsView, 0, 0, 344, 52)
        place(symbol("globe", color: PanelColor.blue), in: language, 15, 19, 14, 14)
        place(text("언어", size: 11, weight: .semibold), in: language, 36, 17, 95, 18)
        place(languageControl, in: language, 139, 12, 192, 28)

        let style = GlassCard()
        place(style, in: menuBarSettingsView, 0, 60, 344, 68)
        place(symbol("waveform", color: PanelColor.blue), in: style, 15, 11, 14, 14)
        place(text("CPU 애니메이션 스타일", size: 11, weight: .semibold), in: style, 36, 9, 290, 18)
        place(animationStyleControl, in: style, 13, 31, 318, 28)

        let motion = GlassCard()
        place(motion, in: menuBarSettingsView, 0, 136, 344, 58)
        place(text("메뉴바 움직임", size: 11, weight: .semibold), in: motion, 16, 8, 265, 18)
        place(menuBarMotionSwitch, in: motion, 292, 6, 36, 22)
        place(text("CPU는 사용률 · 네트워크는 전송량 · SSD 물결은 읽기/쓰기", size: 9, color: PanelColor.secondary), in: motion, 16, 32, 313, 14)

        let intensity = GlassCard()
        place(intensity, in: menuBarSettingsView, 0, 202, 344, 66)
        place(text("움직임 강도", size: 11, weight: .semibold), in: intensity, 16, 6, 240, 18)
        motionIntensityValue.alignment = .right
        place(motionIntensityValue, in: intensity, 278, 7, 50, 17)
        place(motionIntensitySlider, in: intensity, 15, 26, 314, 20)
        place(text("차분하게", size: 9, color: PanelColor.secondary), in: intensity, 17, 47, 140, 14)
        let energetic = text("활기차게", size: 9, color: PanelColor.secondary)
        energetic.alignment = .right
        place(energetic, in: intensity, 186, 47, 141, 14)

        let login = GlassCard()
        place(login, in: menuBarSettingsView, 0, 276, 344, 42)
        place(text("로그인 시 자동 실행", size: 11, weight: .semibold), in: login, 16, 12, 208, 18)
        loginLabel.alignment = .right
        loginLabel.font = .systemFont(ofSize: 9)
        place(loginLabel, in: login, 224, 13, 60, 16)
        place(loginSwitch, in: login, 292, 10, 36, 22)

        place(text("설정은 바로 적용되고 다음 실행에도 유지돼요", size: 9, color: PanelColor.secondary), in: menuBarSettingsView, 3, 324, 338, 13)
        place(text("macOS ‘동작 줄이기’가 켜지면 움직임을 멈춥니다", size: 9, color: PanelColor.secondary), in: menuBarSettingsView, 3, 338, 338, 13)
        updateMenuBarControls()
    }

    private func updateMenuBarControls() {
        updatingMenuBarControls = true
        defer { updatingMenuBarControls = false }
        animationStyleControl.selectItem(at: menuBarPreferences.style.rawValue)
        menuBarMotionSwitch.state = menuBarPreferences.motionEnabled ? .on : .off
        motionIntensitySlider.doubleValue = menuBarPreferences.intensity
        motionIntensitySlider.isEnabled = menuBarPreferences.motionEnabled
        motionIntensityValue.stringValue = String(format: "%.2f×", menuBarPreferences.intensity)
        motionIntensityValue.textColor = menuBarPreferences.motionEnabled ? .labelColor : PanelColor.secondary
    }

    @objc private func changeMenuBarPreferences() {
        guard !updatingMenuBarControls,
              let style = MenuBarAnimationStyle(rawValue: animationStyleControl.indexOfSelectedItem) else { return }
        let preferences = MenuBarPreferences(style: style, motionEnabled: menuBarMotionSwitch.state == .on, intensity: motionIntensitySlider.doubleValue)
        guard preferences != menuBarPreferences else { return }
        menuBarPreferences = preferences
        menuBarPreferences.save()
        updateMenuBarControls()
        menuBarPreferencesChanged?(menuBarPreferences)
    }

    @objc private func toggleMenuBarSettings() {
        showingMenuBarSettings.toggle()
        if showingMenuBarSettings {
            menuBarPreferences = .load()
            updateMenuBarControls()
            updateLoginState()
        }
        showSelectedTab()
    }

    private func buildSummary(in content: NSView) {
        place(thermalDetail, in: content, 3, 0, 338, 15)
        let cpu = GlassCard()
        let ssd = GlassCard()
        place(cpu, in: content, 0, 23, 167, 82)
        place(ssd, in: content, 177, 23, 167, 82)
        for (card, name, icon, accent, value, caption) in [
            (cpu, "CPU", "cpu", PanelColor.blue, cpuTemp, cpuCaption),
            (ssd, "SSD", "internaldrive", PanelColor.violet, ssdTemp, ssdCaption)
        ] {
            place(symbol(icon, color: accent), in: card, 15, 10, 13, 13)
            place(text(name, size: 10, weight: .semibold, color: PanelColor.secondary), in: card, 35, 8, 95, 17)
            place(value, in: card, 13, 25, 141, 39)
            place(caption, in: card, 16, 65, 140, 13)
        }
        let usage = GlassCard()
        place(usage, in: content, 0, 115, 344, 68)
        place(text("CPU 사용률", size: 11, weight: .medium, color: PanelColor.secondary), in: usage, 15, 7, 100, 16)
        let graphRange = text("최근 1분 · 0–100%", size: 9, color: .tertiaryLabelColor)
        graphRange.alignment = .right
        place(graphRange, in: usage, 124, 9, 127, 14)
        cpuPercent.alignment = .right
        place(cpuPercent, in: usage, 259, 6, 69, 18)
        place(cpuGraph, in: usage, 14, 28, 316, 32)

        let network = GlassCard()
        place(network, in: content, 0, 193, 344, 96)
        buildActivityCard(network, title: "네트워크", icon: "arrow.left.arrow.right", firstTitle: "↑  업로드", secondTitle: "↓  다운로드", firstValue: upValue, secondValue: downValue, firstGraph: upGraph, secondGraph: downGraph, secondColor: PanelColor.teal, spacious: false)
        localizedToolTip(network, "Wi-Fi·유선 인터페이스의 바이트/초 합계. 그래프는 실제 측정값의 최근 1분 이력입니다.")
    }

    private func buildMemory(in content: NSView) {
        let capacity = GlassCard()
        place(capacity, in: content, 0, 0, 344, 157)
        place(symbol("memorychip", color: PanelColor.violet), in: capacity, 15, 15, 14, 14)
        place(text("사용 중인 메모리", size: 11, weight: .semibold), in: capacity, 36, 13, 170, 18)
        place(memoryPressure, in: capacity, 235, 12, 94, 23)
        localizedToolTip(memoryPressure, "macOS가 보고하는 메모리 압박 상태입니다. RAM 사용률로 판단하지 않습니다.")
        place(memoryUsed, in: capacity, 14, 40, 245, 42)
        memoryPercent.alignment = .right
        place(memoryPercent, in: capacity, 259, 57, 69, 18)
        place(memoryTotal, in: capacity, 17, 87, 310, 17)
        place(memoryBar, in: capacity, 16, 113, 312, 5)
        place(memoryPressureNote, in: capacity, 17, 130, 310, 15)
        localizedToolTip(memoryUsed, "활성·비활성·고정 메모리와 압축 메모리에서 파일 캐시·회수 가능한 페이지를 제외한 추정 사용량입니다.")
        for (x, title, icon, field, note, color) in [
            (CGFloat(0), "압축 메모리", "arrow.down.right.and.arrow.up.left", memoryCompressed, "RAM 안에서 압축한 크기", PanelColor.violet),
            (CGFloat(177), "스왑 사용량", "internaldrive", memorySwap, "SSD에 옮겨 둔 메모리", PanelColor.blue)
        ] {
            let card = GlassCard()
            place(card, in: content, x, 168, 167, 88)
            place(symbol(icon, color: color), in: card, 14, 12, 13, 13)
            place(text(title, size: 10, weight: .semibold, color: PanelColor.secondary), in: card, 34, 10, 119, 17)
            place(field, in: card, 13, 31, 143, 33)
            place(text(note, size: 9, color: PanelColor.secondary), in: card, 15, 69, 140, 13)
        }
        place(symbol("info.circle", color: PanelColor.secondary), in: content, 3, 272, 12, 12)
        place(text("메모리 압박은 macOS가 판단한 현재 상태입니다", size: 9, color: PanelColor.secondary), in: content, 21, 270, 320, 16)
    }

    private func buildProcesses(in content: NSView) {
        place(text("프로세스 기준", size: 10, weight: .medium, color: PanelColor.secondary), in: content, 3, 0, 135, 15)
        processCount.alignment = .right
        place(processCount, in: content, 139, 1, 202, 14)
        place(cpuRanking, in: content, 0, 23, 344, 119)
        place(memoryRanking, in: content, 0, 152, 344, 119)
        place(text("CPU 비율은 전체 코어를 합친 100% 기준입니다", size: 9, color: PanelColor.secondary), in: content, 3, 276, 338, 13)
    }

    private func buildDisk(in content: NSView) {
        let capacity = GlassCard()
        place(capacity, in: content, 0, 0, 344, 130)
        place(symbol("internaldrive", color: PanelColor.violet), in: capacity, 15, 15, 14, 14)
        place(text("내장 SSD · 사용 가능 공간", size: 11, weight: .semibold), in: capacity, 36, 13, 220, 18)
        diskPercent.alignment = .right
        place(diskPercent, in: capacity, 253, 15, 75, 16)
        place(diskFree, in: capacity, 14, 38, 313, 42)
        place(diskCapacity, in: capacity, 17, 84, 310, 17)
        place(diskBar, in: capacity, 16, 111, 312, 5)
        localizedToolTip(capacity, "시동 볼륨의 전체 용량과 현재 사용 가능한 공간입니다. APFS 공유 공간에 따라 값이 바뀔 수 있습니다.")
        let activity = GlassCard()
        place(activity, in: content, 0, 142, 344, 147)
        buildActivityCard(activity, title: "디스크 활동", icon: "arrow.up.arrow.down", firstTitle: "↓  읽기", secondTitle: "↑  쓰기", firstValue: diskRead, secondValue: diskWrite, firstGraph: diskReadGraph, secondGraph: diskWriteGraph, secondColor: PanelColor.violet, spacious: true)
        localizedToolTip(activity, "내장 물리 SSD의 읽기·쓰기 바이트/초 합계. 그래프는 실제 측정값의 최근 1분 이력입니다.")
    }

    private func buildActivityCard(_ card: NSView, title: String, icon: String, firstTitle: String, secondTitle: String, firstValue: NSTextField, secondValue: NSTextField, firstGraph: Sparkline, secondGraph: Sparkline, secondColor: NSColor, spacious: Bool) {
        place(symbol(icon, color: PanelColor.secondary), in: card, 15, 12, 13, 13)
        place(text(title, size: 11, weight: .semibold, color: PanelColor.secondary), in: card, 34, 10, 137, 17)
        let live = text("최근 1분", size: 9, color: .tertiaryLabelColor)
        live.alignment = .right
        place(live, in: card, 248, 12, 79, 14)
        let labelY: CGFloat = spacious ? 43 : 30
        let valueY: CGFloat = spacious ? 62 : 45
        let graphY: CGFloat = spacious ? 107 : 76
        let graphHeight: CGFloat = spacious ? 25 : 13
        place(text(firstTitle, size: 10, weight: .medium, color: PanelColor.blue), in: card, 16, labelY, 145, 15)
        place(text(secondTitle, size: 10, weight: .medium, color: secondColor), in: card, 186, labelY, 142, 15)
        place(firstValue, in: card, 14, valueY, 148, 28)
        place(secondValue, in: card, 184, valueY, 148, 28)
        place(firstGraph, in: card, 17, graphY, 142, graphHeight)
        place(secondGraph, in: card, 187, graphY, 140, graphHeight)
        let divider = NSBox()
        divider.boxType = .separator
        place(divider, in: card, 171, labelY, 1, graphY + graphHeight - labelY)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.backgroundColor = .clear
        view.window?.isOpaque = false
        updateLoginState()
    }

    private func showSelectedTab() {
        tabs.isHidden = showingMenuBarSettings
        menuBarSettingsView.isHidden = !showingMenuBarSettings
        menuBarSettingsButton.contentTintColor = showingMenuBarSettings ? PanelColor.blue : PanelColor.secondary
        localizedAccessibilityLabel(menuBarSettingsButton, showingMenuBarSettings ? "Mac Thermal 설정 닫기" : "Mac Thermal 설정 열기")
        for (index, content) in tabViews.enumerated() {
            content.layer?.removeAnimation(forKey: "tabContentReveal")
            content.isHidden = showingMenuBarSettings || index != tabs.selectedSegment
        }
        if presentationIsVisible { presentLatestSnapshot() }
    }

    @objc private func changeTab() {
        UserDefaults.standard.set(tabs.selectedSegment, forKey: tabDefaultsKey)
        showSelectedTab()
    }

    private func temperatureText(_ value: Double?) -> NSAttributedString {
        let number = value.map { String(format: "%.0f", $0) } ?? "—"
        let result = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 33, weight: .medium)])
        result.append(NSAttributedString(string: " °C", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: PanelColor.secondary]))
        return result
    }

    private func rateText(_ value: Double?, placeholder: String = "—") -> NSAttributedString {
        guard let value else { return NSAttributedString(string: placeholder, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: placeholder == "—" ? 20 : 12, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]) }
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var scaled = value
        var index = 0
        while scaled >= 1_000 && index < units.count - 1 { scaled /= 1_000; index += 1 }
        let number = String(format: scaled < 100 && index > 0 ? "%.1f" : "%.0f", scaled)
        let result = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium), .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: " " + units[index], attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: PanelColor.secondary]))
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
        case 0: applySummary(sample)
        case 1: applyMemory(sample.resources.memory)
        case 2: applyProcesses(sample.resources.processes)
        case 3: applyDisk(sample.resources.disk)
        default: break
        }
    }

    private func applySummary(_ sample: Snapshot) {
        let temperatureColor = sample.thermal.level > 0 ? sample.thermal.color : NSColor.labelColor
        for (field, value) in [(cpuTemp, sample.cpuTemperature), (ssdTemp, sample.ssdTemperature)] {
            let attributed = NSMutableAttributedString(attributedString: temperatureText(value))
            attributed.addAttribute(.foregroundColor, value: temperatureColor, range: NSRange(location: 0, length: attributed.length - 3))
            field.attributedStringValue = attributed
        }
        cpuCaption.stringValue = L10n.text(sample.cpuTemperature == nil ? "센서 읽기 불가" : "코어 최고 온도")
        ssdCaption.stringValue = L10n.text(sample.ssdTemperature == nil ? "센서 읽기 불가" : "내장 저장장치")
        cpuTemp.toolTip = L10n.format("CPU 코어 센서 %d개 중 최댓값 · PMU 제외", sample.cpuSensors)
        ssdTemp.toolTip = L10n.format("내장 SSD NAND 센서 %d개 중 최댓값", sample.ssdSensors)
        cpuTemp.setAccessibilityLabel(L10n.format("CPU 온도 %@", sample.cpuTemperature.map { L10n.format("%.0f도", $0) } ?? L10n.text("읽기 불가")))
        ssdTemp.setAccessibilityLabel(L10n.format("SSD 온도 %@", sample.ssdTemperature.map { L10n.format("%.0f도", $0) } ?? L10n.text("읽기 불가")))
        cpuPercent.stringValue = sample.cpuUsage.map { String(format: "%.0f%%", $0) } ?? L10n.text("측정 중")
        cpuGraph.update(cpuHistory, percent: sample.cpuUsage)
        cpuGraph.color = sample.thermal.level > 0 ? sample.thermal.color : PanelColor.blue
        thermalDetail.stringValue = sample.thermal.detail
        thermalDetail.textColor = sample.thermal.level > 0 ? sample.thermal.color : PanelColor.secondary
        upValue.attributedStringValue = rateText(sample.upload)
        downValue.attributedStringValue = rateText(sample.download)
        presentHistory(uploadHistory, in: upGraph)
        presentHistory(downloadHistory, in: downGraph)
    }

    private func applyMemory(_ memory: MemorySnapshot) {
        memoryUsed.attributedStringValue = sizeText(memory.usedBytes, size: 31)
        memoryTotal.stringValue = L10n.format("전체 %@", bytesString(memory.totalBytes))
        memoryCompressed.attributedStringValue = sizeText(memory.compressedBytes, size: 24)
        memorySwap.attributedStringValue = sizeText(memory.swapUsedBytes, size: 24)
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
        memoryPressureNote.stringValue = note
        memoryBar.color = PanelColor.violet
    }

    private func applyProcesses(_ processes: ProcessSnapshot) {
        processCount.stringValue = processes.available ? L10n.format("조회 %d개 · 제외 %d개", processes.readableCount, processes.skippedCount) : L10n.text("조회 정보 없음")
        processCount.toolTip = L10n.format("정보를 읽은 프로세스 %d개, 종료·권한 제한 등으로 제외한 프로세스 %d개. 앱별로 합산하지 않은 프로세스 기준 순위입니다.", processes.readableCount, processes.skippedCount)
        let cpuEmpty = processes.available ? (processes.cpuReady ? L10n.text("표시할 프로세스가 없습니다") : L10n.text("다음 측정부터 CPU 순위를 표시합니다")) : L10n.text("프로세스 정보를 읽을 수 없습니다")
        cpuRanking.update(processes.cpuTop, emptyMessage: cpuEmpty) { process in
            process.cpuPercent.map { String(format: "%.1f%%", $0) } ?? L10n.text("측정 중")
        }
        memoryRanking.update(processes.memoryTop, emptyMessage: processes.available ? L10n.text("표시할 프로세스가 없습니다") : L10n.text("프로세스 정보를 읽을 수 없습니다")) { process in
            bytesString(process.memoryBytes)
        }
    }

    private func applyDisk(_ disk: DiskSnapshot) {
        diskFree.attributedStringValue = sizeText(disk.availableBytes, size: 31, binary: false)
        diskCapacity.stringValue = L10n.format("전체 %@", bytesString(disk.totalBytes, binary: false))
        let percentage = disk.totalBytes.flatMap { total in disk.availableBytes.map { total > 0 ? max(0, total - $0) / total * 100 : 0 } }
        diskBar.value = percentage
        diskBar.color = PanelColor.violet
        diskPercent.stringValue = percentage.map { L10n.format("사용 %.0f%%", $0) } ?? "—"
        let placeholder = disk.deviceCount > 0 ? L10n.text("측정 중") : L10n.text("정보 없음")
        diskRead.attributedStringValue = rateText(disk.readBytesPerSecond, placeholder: placeholder)
        diskWrite.attributedStringValue = rateText(disk.writeBytesPerSecond, placeholder: placeholder)
        presentHistory(diskReadHistory, in: diskReadGraph)
        presentHistory(diskWriteHistory, in: diskWriteGraph)
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
        showSelectedTab()
    }
    func probeToggleSettings() { toggleMenuBarSettings() }
    var probeStrings: [String: String] {
        ["cpu": cpuTemp.stringValue, "cpuPercent": cpuPercent.stringValue,
         "memory": memoryUsed.stringValue, "memoryTotal": memoryTotal.stringValue,
         "processes": processCount.stringValue, "disk": diskFree.stringValue,
         "upload": upValue.stringValue, "diskRead": diskRead.stringValue,
         "thermal": thermalDetail.stringValue, "uptime": uptimeLabel.stringValue,
         "updated": updated.stringValue]
    }
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
    var probePresentedCPUHistoryTimes: [TimeInterval] { cpuGraph.probeTimes }
    var probeSurfaceFrames: [NSRect] { tabViews.map(\.frame) + [menuBarSettingsView.frame] }
}
#endif
