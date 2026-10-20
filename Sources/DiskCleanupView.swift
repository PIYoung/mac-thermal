import AppKit
import QuartzCore

/// Operations are injectable so UI probes never inspect or move real user files.
struct DiskCleanupViewOperations {
    var scan: (URL, DiskCleanupRememberedFolder?, DiskCleanupCancellation, (DiskCleanupProgress) -> Void) throws -> DiskCleanupPlan
    var execute: (DiskCleanupPlan, Set<UUID>, DiskCleanupCancellation, (DiskCleanupProgress) -> Void) -> DiskCleanupResult
    // A non-live test transport must explicitly inject home scanning as well.
    var scanHome: (DiskCleanupCancellation, (DiskCleanupProgress) -> Void) throws -> DiskCleanupPlan = { _, _ in
        throw DiskCleanupError(reason: .invalidRoot)
    }
    var availableBytes: (URL) -> Int64? = { root in
        ((try? FileManager.default.attributesOfFileSystem(forPath: root.path))?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    static let live = Self(
        scan: { try DiskCleanup.scan(rootURL: $0, cancellation: $2, expectedFolder: $1, progress: $3) },
        execute: { DiskCleanup.execute(plan: $0, selectedIDs: $1, cancellation: $2, progress: $3) },
        scanHome: { try DiskCleanup.scanHome(cancellation: $0, progress: $1) })
}

private final class CleanupPrimaryButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        let color: NSColor = isEnabled
            ? (isHighlighted ? NSColor.systemBlue.blended(withFraction: 0.16, of: .black) ?? .systemBlue : .systemBlue)
            : .quaternaryLabelColor
        color.setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

private func cleanupLabel(size: CGFloat = 10, weight: NSFont.Weight = .regular, secondary: Bool = false, lines: Int = 1) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    field.maximumNumberOfLines = lines
    field.lineBreakMode = lines == 1 ? .byTruncatingMiddle : .byWordWrapping
    return field
}

private func cleanupBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(max(0, bytes)), unit = 0
    while value >= 1_000 && unit < units.count - 1 { value /= 1_000; unit += 1 }
    return String(format: unit > 0 && value < 100 ? "%.1f %@" : "%.0f %@", value, units[unit])
}

private func cleanupReason(_ reason: DiskCleanupCandidateReason) -> String {
    L10n.text(reason == .oldInstaller ? "오래된 설치 파일" : "오래된 대용량 파일")
}

private func cleanupIssue(_ reason: DiskCleanupIssueReason) -> String {
    let key: String
    switch reason {
    case .invalidRoot: key = "선택한 폴더를 사용할 수 없습니다"
    case .protectedLocation: key = "시스템 또는 보호된 위치는 제외합니다"
    case .unsupportedVolume: key = "지원하는 로컬 디스크의 폴더를 선택하세요"
    case .cloudLocation: key = "클라우드 동기화 위치는 제외합니다"
    case .permissionDenied: key = "접근 권한이 없습니다"
    case .symbolicLink: key = "심볼릭 링크는 제외합니다"
    case .aliasFile: key = "별칭 파일은 제외합니다"
    case .packageDirectory: key = "앱과 패키지 내부는 제외합니다"
    case .notRegularFile: key = "일반 파일이 아닙니다"
    case .tooRecent: key = "최근에 변경한 파일은 제외합니다"
    case .notCandidate: key = "정리 후보 조건에 맞지 않습니다"
    case .changed: key = "검사 후 파일이 변경되어 건너뛰었습니다"
    case .missing: key = "파일을 찾을 수 없습니다"
    case .outsideScope: key = "선택한 폴더 범위를 벗어났습니다"
    case .cancelled: key = "남은 작업을 중지했습니다"
    case .scanLimit: key = "검사 한도에 도달했습니다"
    case .trashFailed: key = "휴지통으로 이동하지 못했습니다"
    }
    return L10n.text(key)
}

private final class CleanupFileRow: FlippedView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = cleanupLabel(size: 11, weight: .medium)
    private let path = cleanupLabel(size: 9, secondary: true)
    private let metadata = cleanupLabel(size: 9, secondary: true)
    private let reason = cleanupLabel(size: 9)
    private let reveal = NSButton(image: NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: nil) ?? NSImage(), target: nil, action: nil)
    var selectionChanged: ((Bool) -> Void)?
    private var revealURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        checkbox.controlSize = .small
        checkbox.target = self
        checkbox.action = #selector(toggleSelection)
        reveal.isBordered = false
        reveal.contentTintColor = .secondaryLabelColor
        reveal.target = self
        reveal.action = #selector(revealFile)
        [checkbox, name, path, metadata, reason, reveal].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func layout() {
        super.layout()
        checkbox.frame = NSRect(x: 8, y: 9, width: 20, height: 20)
        name.frame = NSRect(x: 33, y: 8, width: max(0, bounds.width - 68), height: 17)
        reveal.frame = NSRect(x: bounds.width - 30, y: 7, width: 23, height: 22)
        path.frame = NSRect(x: 33, y: 25, width: max(0, bounds.width - 42), height: 12)
        metadata.frame = NSRect(x: 33, y: 39, width: max(0, bounds.width - 42), height: 12)
        reason.frame = NSRect(x: 33, y: 53, width: max(0, bounds.width - 42), height: 12)
    }
    func configure(candidate: DiskCleanupCandidate, selected: Bool, recommended: Bool, selectable: Bool, result: DiskCleanupItemResult?, date: String) {
        checkbox.isHidden = !selectable
        checkbox.state = selected ? .on : .off
        checkbox.setAccessibilityLabel(L10n.format("정리 대상으로 선택: %@", candidate.url.path))
        name.stringValue = candidate.url.lastPathComponent
        path.stringValue = candidate.relativePath
        path.toolTip = candidate.url.path
        path.setAccessibilityLabel(candidate.url.path)
        metadata.stringValue = cleanupBytes(candidate.sizeBytes) + " · " + date
        if let result {
            let status: String
            switch result.status {
            case .moved: status = L10n.text("이동됨"); reason.textColor = .systemGreen
            case .skipped: status = L10n.text("건너뜀"); reason.textColor = .secondaryLabelColor
            case .failed: status = L10n.text("실패"); reason.textColor = .systemOrange
            }
            reason.stringValue = result.reason.map { status + " · " + cleanupIssue($0) } ?? status
            revealURL = result.status == .moved ? result.trashURL : result.originalURL
        } else {
            reason.stringValue = recommended ? L10n.text("추천") + " · " + cleanupReason(candidate.reason) : cleanupReason(candidate.reason)
            reason.textColor = .secondaryLabelColor
            revealURL = candidate.url
        }
        reason.toolTip = reason.stringValue
        reveal.isEnabled = revealURL != nil
        reveal.toolTip = L10n.text("Finder에서 보기")
        reveal.setAccessibilityLabel(L10n.format("Finder에서 보기: %@", name.stringValue))
    }
    override func draw(_ dirtyRect: NSRect) {
        PanelColor.divider.setFill()
        NSRect(x: 12, y: bounds.height - 0.5, width: max(0, bounds.width - 24), height: 0.5).fill()
    }
    @objc private func toggleSelection() { selectionChanged?(checkbox.state == .on) }
    @objc private func revealFile() {
        if let revealURL { NSWorkspace.shared.activateFileViewerSelecting([revealURL]) }
    }
}

/// A bounded SSD subpage. Selection, plan and an active job survive tab/panel closure.
final class DiskCleanupView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Stage: String { case idle, ready, restoring, scanning, review, confirmation, executing, result }
    private struct Confirmation {
        let plan: DiskCleanupPlan
        let candidates: [DiskCleanupCandidate]
        let ids: Set<UUID>
        let bytes: Int64
    }
    private let operations: DiskCleanupViewOperations
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "local.mac-thermal.cleanup", qos: .utility)
    private static let scopePreferenceKey = "diskCleanupScopeV2"
    private var automaticHome = true
    private var stage = Stage.idle
    private var folderURL: URL?
    private var rememberedFolder: DiskCleanupRememberedFolder?
    private var hasRememberedFolder = false
    private var entryAttempted = false
    private var plan: DiskCleanupPlan?
    private var selectedIDs = Set<UUID>()
    private var recommendedIDs = Set<UUID>()
    private var confirmation: Confirmation?
    private var result: DiskCleanupResult?
    private var cancellation: DiskCleanupCancellation?
    private var stopRequested = false
    private var pickerInFlight = false
    private var jobGeneration: UInt = 0
    private var resultAvailableBytes: Int64?
    private var progress = DiskCleanupProgress(visitedCount: 0, candidateCount: 0, completedCount: 0, totalCount: 0)
    private var errorMessage: String?
    private var candidateRows: [DiskCleanupCandidate] = []
    private var resultRows: [DiskCleanupItemResult] = []
    private let folder = cleanupLabel(size: 9, secondary: true)
    private let summary = cleanupLabel(size: 10, weight: .medium)
    private let notice = cleanupLabel(size: 9, secondary: true, lines: 2)
    private let body = GlassCard()
    private let message = cleanupLabel(size: 11, lines: 4)
    private let detail = cleanupLabel(size: 9, secondary: true, lines: 4)
    private let progressBar = NSProgressIndicator()
    private let banner = cleanupLabel(size: 9, secondary: true, lines: 2)
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var languageObserver: NSObjectProtocol?
    private lazy var back = NSButton(title: "", target: self, action: #selector(closePage))
    private lazy var primary: NSButton = {
        let button = NSButton(frame: .zero)
        button.cell = CleanupPrimaryButtonCell(textCell: "")
        button.target = self
        button.action = #selector(primaryAction)
        return button
    }()
    private lazy var secondary = NSButton(title: "", target: self, action: #selector(secondaryAction))
    private lazy var changeFolder: NSPopUpButton = {
        let control = NSPopUpButton(frame: .zero, pullsDown: true)
        control.controlSize = .small
        control.imagePosition = .imageOnly
        control.imageScaling = .scaleProportionallyDown
        (control.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let menu = NSMenu()
        menu.autoenablesItems = false
        let label = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)
        label.isHidden = true
        let choose = menu.addItem(withTitle: "", action: #selector(chooseAnotherFolder), keyEquivalent: "")
        choose.target = self
        let forget = menu.addItem(withTitle: "", action: #selector(forgetFolder), keyEquivalent: "")
        forget.target = self
        control.menu = menu
        return control
    }()
    var didClose: (() -> Void)?
    var didFinish: (() -> Void)?

    init(frame: NSRect, operations: DiskCleanupViewOperations = .live, defaults: UserDefaults = .standard) {
        self.operations = operations
        self.defaults = defaults
        super.init(frame: frame)
        wantsLayer = true
        body.wantsLayer = true
        back.isBordered = false
        back.contentTintColor = .systemBlue
        back.font = .systemFont(ofSize: 11, weight: .medium)
        changeFolder.isBordered = false
        changeFolder.contentTintColor = .secondaryLabelColor
        for button in [primary, secondary] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10, weight: .medium)
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cleanup-file"))
        column.width = 288
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = 72
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = table
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        [back, folder, changeFolder, summary, body, notice, secondary, primary].forEach(addSubview)
        [message, detail, progressBar, scroll, banner].forEach(body.addSubview)
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageDidChange, object: nil, queue: .main) { [weak self] _ in self?.refreshLanguage() }
        render(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) } }
    override func layout() {
        super.layout()
        back.frame = NSRect(x: 0, y: 0, width: 57, height: 24)
        folder.frame = NSRect(x: 64, y: 5, width: 208, height: 14)
        changeFolder.frame = NSRect(x: 280, y: 1, width: 25, height: 23)
        summary.frame = NSRect(x: 4, y: 26, width: 300, height: 17)
        body.frame = NSRect(x: 0, y: 45, width: 308, height: 168)
        let bannerHeight: CGFloat = stage == .result ? 39 : 26
        let listTop: CGFloat = banner.isHidden ? 4 : bannerHeight + 8
        message.frame = NSRect(x: 16, y: banner.isHidden ? 12 : bannerHeight + 12, width: 276, height: banner.isHidden ? 56 : 40)
        let detailTop = max(86, message.frame.maxY + 6)
        detail.frame = NSRect(x: 16, y: detailTop, width: 276, height: 156 - detailTop)
        progressBar.frame = NSRect(x: 16, y: 73, width: 276, height: 6)
        banner.frame = NSRect(x: 16, y: 5, width: 276, height: bannerHeight)
        scroll.frame = NSRect(x: 8, y: listTop, width: 292, height: 164 - listTop)
        table.tableColumns.first?.width = scroll.contentSize.width
        table.frame.size.width = scroll.contentSize.width
        notice.frame = NSRect(x: 4, y: 220, width: 300, height: 28)
        secondary.frame = NSRect(x: 0, y: 253, width: 92, height: 24)
        primary.frame = NSRect(x: 100, y: 253, width: 208, height: 24)
    }

    func refreshLanguage() { render(animated: false) }
    /// Called only for an explicit cleanup-button entry, never at app launch.
    /// An existing review or job is kept intact when the panel is reopened.
    func onEntry() {
        guard !entryAttempted, stage == .idle, folderURL == nil, plan == nil, !pickerInFlight else { return }
        entryAttempted = true
        if defaults.string(forKey: Self.scopePreferenceKey) != "folder" {
            prepareHomeScan()
            return
        }
        automaticHome = false
        jobGeneration &+= 1
        let generation = jobGeneration
        let cancellation = DiskCleanupCancellation()
        self.cancellation = cancellation
        stopRequested = false
        stage = .restoring
        render(animated: false)
        queue.async { [weak self] in
            guard let self else { return }
            let remembered = DiskCleanup.restoreRememberedFolder(defaults: self.defaults)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobGeneration == generation else { return }
                self.cancellation = nil
                guard !cancellation.isCancelled, let remembered else {
                    self.prepareHomeScan(); return
                }
                self.rememberedFolder = remembered
                self.hasRememberedFolder = true
                self.folderURL = remembered.rootURL
                self.stage = .ready
                self.startScan()
            }
        }
    }
    private var isBusy: Bool { stage == .restoring || stage == .scanning || stage == .executing }
    private var canForgetFolder: Bool { !automaticHome && !isBusy && !pickerInFlight }
    private func totalBytes(_ candidates: [DiskCleanupCandidate]) -> Int64 {
        candidates.reduce(0) { partial, candidate in
            let sum = partial.addingReportingOverflow(candidate.sizeBytes)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }
    private func render(animated: Bool = true) {
        back.title = "‹ SSD"
        back.setAccessibilityLabel(L10n.text("SSD 모니터로 돌아가기"))
        folder.stringValue = automaticHome ? L10n.text("내 홈 폴더 · 자동 검사") : (folderURL?.path ?? L10n.text("선택한 폴더만 검사합니다"))
        folder.toolTip = folderURL?.path
        changeFolder.isHidden = false
        changeFolder.isEnabled = !isBusy && !pickerInFlight
        changeFolder.toolTip = L10n.text("폴더 관리")
        changeFolder.setAccessibilityLabel(L10n.text("폴더 관리"))
        changeFolder.item(at: 0)?.title = L10n.text("폴더 관리")
        changeFolder.item(at: 1)?.title = L10n.text("특정 폴더만 검사")
        changeFolder.item(at: 2)?.title = L10n.text("홈 폴더 자동 검사로 전환")
        changeFolder.item(at: 1)?.isEnabled = !isBusy && !pickerInFlight
        changeFolder.item(at: 2)?.isEnabled = canForgetFolder
        notice.stringValue = L10n.text("휴지통으로 옮겨도 바로 공간이 늘어나지는 않습니다. 휴지통은 자동으로 비우지 않습니다.")
        primary.isEnabled = true
        secondary.isEnabled = true
        secondary.isHidden = false
        banner.isHidden = true
        scroll.isHidden = ![.review, .confirmation, .result].contains(stage)
        message.isHidden = !scroll.isHidden
        detail.isHidden = !scroll.isHidden
        progressBar.isHidden = stage != .executing
        errorMessage.map { message.stringValue = $0 }
        candidateRows = []
        resultRows = []
        switch stage {
        case .idle, .ready:
            summary.stringValue = L10n.text("파일을 지우기 전에 항목과 동작을 확인합니다")
            if automaticHome {
                message.stringValue = errorMessage ?? L10n.text("홈 아래 로컬 파일의 이름·크기·날짜만 검사합니다. 파일 내용은 읽거나 전송하지 않습니다.")
                detail.stringValue = L10n.text("30일 지난 설치 파일·100MB 이상 파일을 찾습니다. 시스템·Library·숨김·앱·개발·알려진 클라우드 경로는 제외하며, 접근이 막힌 곳은 건너뜁니다.")
                notice.stringValue = L10n.text("모든 동기화 폴더를 감지할 수는 없습니다. 후보는 직접 선택하고, 휴지통 이동 전 다시 확인합니다.")
            } else {
                message.stringValue = errorMessage ?? L10n.text("클라우드와 동기화되지 않는 로컬 폴더를 선택하세요") + "\n" + L10n.text("선택한 폴더를 기억하고 다음 정리 때 자동 검사합니다")
                detail.stringValue = L10n.text("생성·수정 모두 30일 이상 지난 설치 파일 또는 100MB 이상 파일을 찾습니다. 오래된 설치 파일만 미리 선택하고, 이동은 최종 확인 후 진행합니다.")
            }
            primary.title = L10n.text(automaticHome ? "자동 검사" : (folderURL == nil ? "폴더 선택" : "검사 시작"))
            secondary.title = L10n.text("특정 폴더만 검사")
            secondary.isHidden = true
        case .restoring:
            summary.stringValue = L10n.text("기억한 폴더 확인 중")
            message.stringValue = L10n.text("기억한 폴더 확인 중")
            detail.stringValue = L10n.text("선택한 폴더만 검사합니다")
            primary.title = L10n.text("기억한 폴더 확인 중")
            primary.isEnabled = false
            secondary.title = L10n.text(stopRequested ? "중지 요청됨" : "검사 중지")
            secondary.isEnabled = !stopRequested
        case .scanning:
            summary.stringValue = L10n.text("폴더 검사 중")
            message.stringValue = L10n.text("파일을 변경하지 않고 정리 후보를 찾고 있습니다")
            detail.stringValue = L10n.format("확인 %d개 · 후보 %d개", progress.visitedCount, progress.candidateCount)
            primary.title = L10n.text("검사 중")
            primary.isEnabled = false
            secondary.title = L10n.text(stopRequested ? "중지 요청됨" : "검사 중지")
            secondary.isEnabled = !stopRequested
        case .review:
            candidateRows = plan?.candidates ?? []
            banner.isHidden = false
            banner.stringValue = L10n.text("30일 이상 · 설치 파일 / 100MB 이상")
            if automaticHome {
                banner.stringValue += "\n" + L10n.text("자동 선택 없음 · 정리할 파일을 직접 선택하세요")
            } else if let plan, !plan.cancelled && !plan.truncated && !stopRequested {
                banner.stringValue += "\n" + L10n.text("추천: 설치 파일만 · 대용량 파일 직접 선택")
            }
            let chosen = candidateRows.filter { selectedIDs.contains($0.id) }
            summary.stringValue = L10n.format("선택 %d개 · 정리 대상 %@", chosen.count, cleanupBytes(totalBytes(chosen)))
            primary.title = L10n.text("선택 내용 확인")
            primary.isEnabled = !chosen.isEmpty
            secondary.title = L10n.text("다시 검사")
            if candidateRows.isEmpty {
                scroll.isHidden = true; message.isHidden = false; detail.isHidden = false
                message.stringValue = L10n.text("조건에 맞는 정리 후보가 없습니다")
                detail.stringValue = scanDetail
            }
            body.toolTip = scanDetail
            if let plan, !candidateRows.isEmpty, plan.cancelled || plan.truncated || stopRequested {
                banner.stringValue = L10n.text("30일 이상 · 설치 파일 / 100MB 이상") + "\n" + L10n.text(plan.cancelled || stopRequested ? "검사를 중지해 일부 항목만 표시합니다" : "검사 한도에 도달해 일부 항목만 표시합니다")
            }
        case .confirmation:
            candidateRows = confirmation?.candidates ?? []
            summary.stringValue = L10n.format("확인: %d개 · %@", candidateRows.count, cleanupBytes(confirmation?.bytes ?? 0))
            primary.title = L10n.format("%d개 휴지통으로 이동", candidateRows.count)
            primary.isEnabled = !candidateRows.isEmpty
            secondary.title = L10n.text("선택 수정")
            notice.stringValue = L10n.text("위 파일만 휴지통으로 이동합니다. 영구 삭제와 휴지통 비우기는 하지 않습니다.")
        case .executing:
            summary.stringValue = L10n.text("선택한 파일을 휴지통으로 이동 중")
            message.stringValue = L10n.format("처리 %d / %d개", progress.completedCount, progress.totalCount)
            detail.stringValue = L10n.text(stopRequested ? "현재 파일 처리가 끝나면 남은 작업을 중지합니다. 이미 옮긴 파일은 휴지통에 남습니다." : "파일이 변경되었거나 범위를 벗어나면 건너뜁니다. 이미 옮긴 파일은 휴지통에서 확인할 수 있습니다.")
            progressBar.doubleValue = progress.totalCount > 0 ? Double(progress.completedCount) / Double(progress.totalCount) * 100 : 0
            primary.title = L10n.text("이동 중")
            primary.isEnabled = false
            secondary.title = L10n.text(stopRequested ? "중지 요청됨" : "남은 작업 중지")
            secondary.isEnabled = !stopRequested
        case .result:
            resultRows = result?.items ?? []
            let byID = Dictionary(uniqueKeysWithValues: (plan?.candidates ?? []).map { ($0.id, $0) })
            candidateRows = resultRows.compactMap { byID[$0.candidateID] }
            let moved = resultRows.filter { $0.status == .moved }.count
            let skipped = resultRows.filter { $0.status == .skipped }.count
            let failed = resultRows.filter { $0.status == .failed }.count
            summary.stringValue = L10n.format("이동 %d · 건너뜀 %d · 실패 %d", moved, skipped, failed)
            let movedIDs = Set(resultRows.filter { $0.status == .moved }.map(\.candidateID))
            let movedBytes = totalBytes((plan?.candidates ?? []).filter { movedIDs.contains($0.id) })
            banner.isHidden = false
            let statusKey: String
            if result?.cancelled == true { statusKey = "정리 중지 결과" }
            else if failed > 0 || skipped > 0 { statusKey = "정리 결과 · 일부 미처리" }
            else { statusKey = "정리 결과" }
            banner.stringValue = L10n.text(statusKey) + "\n" + L10n.format("휴지통 이동 %@ · 현재 사용 가능 %@", cleanupBytes(movedBytes), resultAvailableBytes.map(cleanupBytes) ?? L10n.text("정보 없음"))
            primary.title = L10n.text("휴지통 열기")
            secondary.title = L10n.text("다시 검사")
            if candidateRows.isEmpty {
                scroll.isHidden = true; message.isHidden = false; detail.isHidden = false
                message.stringValue = L10n.text("이동한 파일이 없습니다")
                detail.stringValue = result?.cancelled == true ? L10n.text("남은 작업을 중지했습니다") : ""
            }
        }
        if pickerInFlight { primary.isEnabled = false; secondary.isEnabled = false }
        updatePrimaryAppearance()
        table.reloadData()
        banner.maximumNumberOfLines = stage == .result ? 3 : 2
        table.frame.size.height = max(160, CGFloat(candidateRows.count) * 72)
        needsLayout = true
        if animated, window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.82; fade.toValue = 1; fade.duration = 0.12
            body.layer?.add(fade, forKey: "cleanupStage")
        }
    }
    private func updatePrimaryAppearance() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let title = NSAttributedString(string: primary.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: primary.isEnabled ? NSColor.white : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph
        ])
        primary.attributedTitle = title
        primary.attributedAlternateTitle = title
    }
    private var scanDetail: String {
        guard let plan else { return "" }
        var value = L10n.format("확인 %d개 · 제외 %d개", plan.scannedCount, plan.skippedCount)
        if plan.cancelled || stopRequested { value += "\n" + L10n.text("검사를 중지해 일부 항목만 표시합니다") }
        if plan.truncated { value += "\n" + L10n.text("검사 한도에 도달해 일부 항목만 표시합니다") }
        if let first = plan.issues.first { value += "\n" + cleanupIssue(first.reason) }
        return value
    }
    @objc private func closePage() { didClose?() }
    @objc private func primaryAction() {
        guard !pickerInFlight else { return }
        switch stage {
        case .idle: if automaticHome { prepareHomeScan(); startScan() } else { chooseFolder() }
        case .ready: startScan()
        case .review:
            guard let plan else { return }
            let candidates = plan.candidates.filter { selectedIDs.contains($0.id) }
            guard !candidates.isEmpty else { return }
            confirmation = Confirmation(plan: plan, candidates: candidates, ids: Set(candidates.map(\.id)), bytes: totalBytes(candidates))
            stage = .confirmation; render()
        case .confirmation: executeConfirmation()
        case .result:
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true))
        case .restoring, .scanning, .executing: break
        }
    }
    @objc private func secondaryAction() {
        guard !pickerInFlight else { return }
        switch stage {
        case .idle, .ready: chooseFolder()
        case .review, .result: startScan()
        case .confirmation: confirmation = nil; stage = .review; render()
        case .restoring, .scanning, .executing:
            cancellation?.cancel(); stopRequested = true; render(animated: false)
        }
    }
    @objc private func chooseAnotherFolder() { chooseFolder() }
    @objc private func forgetFolder() {
        guard canForgetFolder else { return }
        DiskCleanup.forgetRememberedFolder(defaults: defaults)
        jobGeneration &+= 1
        prepareHomeScan()
    }
    private func prepareHomeScan() {
        automaticHome = true
        defaults.set("home", forKey: Self.scopePreferenceKey)
        rememberedFolder = nil; hasRememberedFolder = false
        folderURL = FileManager.default.homeDirectoryForCurrentUser
        plan = nil; confirmation = nil; result = nil; resultAvailableBytes = nil
        selectedIDs = []; recommendedIDs = []; errorMessage = nil; stopRequested = false
        entryAttempted = true; stage = .ready; render(animated: false)
    }
    private func acceptFolder(_ url: URL) {
        guard !isBusy, !pickerInFlight else { return }
        DiskCleanup.forgetRememberedFolder(defaults: defaults)
        jobGeneration &+= 1
        rememberedFolder = nil
        hasRememberedFolder = false
        entryAttempted = true
        automaticHome = false
        defaults.set("folder", forKey: Self.scopePreferenceKey)
        folderURL = url
        plan = nil; confirmation = nil; result = nil; selectedIDs = []; recommendedIDs = []
        errorMessage = nil; stage = .ready
        startScan()
    }
    private func chooseFolder() {
        guard !isBusy, !pickerInFlight else { return }
        pickerInFlight = true
        let generation = jobGeneration
        render(animated: false)
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = false
        picker.resolvesAliases = false
        picker.title = L10n.text("정리할 로컬 폴더 선택")
        picker.message = L10n.text("클라우드와 동기화되지 않는 로컬 폴더를 선택하세요")
        picker.prompt = L10n.text("이 폴더 선택")
        picker.begin { [weak self] response in
            guard let self else { return }
            self.pickerInFlight = false
            guard self.jobGeneration == generation, !self.isBusy else { self.render(animated: false); return }
            guard response == .OK, let url = picker.url else { self.render(animated: false); return }
            self.acceptFolder(url)
        }
    }
    private func startScan() {
        guard !isBusy, !pickerInFlight, let root = folderURL else { return }
        jobGeneration &+= 1
        let generation = jobGeneration
        let expectedFolder = rememberedFolder
        let scanningHome = automaticHome
        let cancellation = DiskCleanupCancellation()
        self.cancellation = cancellation
        stopRequested = false; errorMessage = nil; plan = nil; confirmation = nil; result = nil; resultAvailableBytes = nil; selectedIDs = []; recommendedIDs = []
        progress = DiskCleanupProgress(visitedCount: 0, candidateCount: 0, completedCount: 0, totalCount: 0)
        stage = .scanning; render()
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let report: (DiskCleanupProgress) -> Void = { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.jobGeneration == generation else { return }; self.updateProgress(progress)
                    }
                }
                let plan = try scanningHome ? self.operations.scanHome(cancellation, report)
                    : self.operations.scan(root, expectedFolder, cancellation, report)
                let remembered = scanningHome || plan.cancelled || cancellation.isCancelled ? nil : DiskCleanup.rememberFolder(from: plan, defaults: self.defaults)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.jobGeneration == generation else { return }
                    self.plan = plan
                    self.recommendedIDs = scanningHome || plan.cancelled || plan.truncated || cancellation.isCancelled ? [] : Set(plan.candidates.filter { $0.reason == .oldInstaller }.map(\.id))
                    self.selectedIDs = self.recommendedIDs
                    if let remembered { self.rememberedFolder = remembered; self.hasRememberedFolder = true }
                    self.cancellation = nil; self.stage = .review; self.render()
                }
            } catch {
                let reason = (error as? DiskCleanupError)?.reason
                if expectedFolder != nil { DiskCleanup.forgetRememberedFolder(defaults: self.defaults) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.jobGeneration == generation else { return }
                    if expectedFolder != nil {
                        self.rememberedFolder = nil; self.hasRememberedFolder = false; self.folderURL = nil
                        self.errorMessage = L10n.text("기억한 폴더가 변경되었거나 사용할 수 없습니다. 폴더를 다시 선택하세요")
                        self.stage = .idle
                    } else {
                        self.errorMessage = reason.map(cleanupIssue) ?? L10n.text("폴더를 검사하지 못했습니다")
                        self.stage = .ready
                    }
                    self.cancellation = nil; self.render()
                }
            }
        }
    }
    private func executeConfirmation() {
        guard stage == .confirmation, let confirmed = confirmation, !confirmed.ids.isEmpty else { return }
        jobGeneration &+= 1
        let generation = jobGeneration
        let cancellation = DiskCleanupCancellation()
        self.cancellation = cancellation
        stopRequested = false
        progress = DiskCleanupProgress(visitedCount: 0, candidateCount: confirmed.candidates.count, completedCount: 0, totalCount: confirmed.candidates.count)
        stage = .executing; render()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.operations.execute(confirmed.plan, confirmed.ids, cancellation) { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.jobGeneration == generation else { return }; self.updateProgress(progress)
                }
            }
            let available = self.operations.availableBytes(confirmed.plan.rootURL)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.jobGeneration == generation else { return }
                self.result = result; self.resultAvailableBytes = available; self.cancellation = nil; self.stage = .result; self.render(); self.didFinish?()
            }
        }
    }
    private func updateProgress(_ progress: DiskCleanupProgress) {
        guard isBusy else { return }
        self.progress = progress
        if stage == .scanning { detail.stringValue = L10n.format("확인 %d개 · 후보 %d개", progress.visitedCount, progress.candidateCount) }
        else {
            message.stringValue = L10n.format("처리 %d / %d개", progress.completedCount, progress.totalCount)
            progressBar.doubleValue = progress.totalCount > 0 ? Double(progress.completedCount) / Double(progress.totalCount) * 100 : 0
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { candidateRows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard candidateRows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cleanup-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? CleanupFileRow ?? CleanupFileRow(frame: .zero)
        view.identifier = identifier
        let candidate = candidateRows[row]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: L10n.language.localeIdentifier)
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        let item = stage == .result ? resultRows.first { $0.candidateID == candidate.id } : nil
        view.configure(candidate: candidate, selected: selectedIDs.contains(candidate.id), recommended: recommendedIDs.contains(candidate.id), selectable: stage == .review, result: item, date: formatter.string(from: candidate.modifiedAt))
        view.selectionChanged = { [weak self] selected in
            guard let self, self.stage == .review else { return }
            if selected { self.selectedIDs.insert(candidate.id) } else { self.selectedIDs.remove(candidate.id) }
            let chosen = self.plan?.candidates.filter { self.selectedIDs.contains($0.id) } ?? []
            self.summary.stringValue = L10n.format("선택 %d개 · 정리 대상 %@", chosen.count, cleanupBytes(self.totalBytes(chosen)))
            self.primary.isEnabled = !chosen.isEmpty
            self.updatePrimaryAppearance()
        }
        return view
    }
}

#if PANEL_UPDATES_PROBE
extension DiskCleanupView {
    var probeStage: String { stage.rawValue }
    var probeSelectedIDs: Set<UUID> { selectedIDs }
    var probeRecommendedIDs: Set<UUID> { recommendedIDs }
    var probeConfirmedIDs: Set<UUID> { confirmation?.ids ?? [] }
    var probeSummary: String { summary.stringValue }
    var probePrimaryTitle: String { primary.title }
    var probePrimaryEnabled: Bool { primary.isEnabled }
    var probeNotice: String { notice.stringValue }
    var probeCandidateCount: Int { candidateRows.count }
    var probeHeaderHeight: CGFloat { body.frame.minY }
    var probeListHeight: CGFloat { scroll.frame.height }
    var probeBanner: String { banner.stringValue }
    var probeForgetEnabled: Bool { canForgetFolder }
    var probeAutomaticHome: Bool { automaticHome }
    func probeAcceptFolder(_ url: URL) { acceptFolder(url) }
    func probeForgetFolder() { forgetFolder() }
    func probeSetPlan(_ plan: DiskCleanupPlan) {
        guard !isBusy else { return }
        automaticHome = plan.isAutomaticHome
        folderURL = plan.rootURL; self.plan = plan; selectedIDs = []; recommendedIDs = []; confirmation = nil; result = nil
        stage = .review; render(animated: false)
    }
    func probeToggleCandidate(at row: Int) {
        guard stage == .review, candidateRows.indices.contains(row) else { return }
        let cell = tableView(table, viewFor: table.tableColumns.first, row: row) as? CleanupFileRow
        cell?.checkbox.performClick(nil)
    }
    func probePressPrimary() { primary.performClick(nil) }
    func probePressSecondary() { secondary.performClick(nil) }
}
#endif
