import AppKit
import Foundation
import CoreServices

struct ThermalStatus {
    let color: NSColor
    let symbol: String
    let level: Int

    // These are resolved when displayed so existing snapshots switch language immediately.
    var title: String {
        switch level {
        case 0: return L10n.text("정상")
        case 1: return L10n.text("약간 높음")
        case 2: return L10n.text("높음")
        case 3: return L10n.text("냉각 필요")
        default: return L10n.text("확인 불가")
        }
    }

    var detail: String {
        switch level {
        case 0: return L10n.text("macOS 열 상태가 정상 범위입니다")
        case 1: return L10n.text("macOS가 온도 상승을 감지했습니다")
        case 2: return L10n.text("부하를 줄이고 통풍을 확인하세요")
        case 3: return L10n.text("열이 시스템 성능에 영향을 주고 있습니다")
        default: return L10n.text("열 상태를 확인할 수 없습니다")
        }
    }

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            color = .systemGreen; symbol = "checkmark.circle.fill"; level = 0
        case .fair:
            color = .systemOrange; symbol = "thermometer.medium"; level = 1
        case .serious:
            color = .systemRed; symbol = "exclamationmark.triangle.fill"; level = 2
        case .critical:
            color = .systemRed; symbol = "exclamationmark.triangle.fill"; level = 3
        @unknown default:
            color = .secondaryLabelColor; symbol = "questionmark.circle"; level = -1
        }
    }
}

/// Display thresholds, not manufacturer limits or proof of throttling.
/// macOS system thermal pressure is reported separately and never colors siblings.
enum TemperatureWarning: Int {
    case normal, warm, hot
    var color: NSColor { self == .hot ? .systemRed : self == .warm ? .systemOrange : .labelColor }
    func title(for component: String) -> String {
        switch self {
        case .normal: return ""
        case .warm: return L10n.format("%@ 온도 주의", component)
        case .hot: return L10n.format("%@ 온도 높음", component)
        }
    }
    static func cpu(_ value: Double?) -> Self { classify(value, warm: 90, hot: 100) }
    static func gpu(_ value: Double?) -> Self { classify(value, warm: 90, hot: 100) }
    static func memoryProximity(_ value: Double?) -> Self { classify(value, warm: 75, hot: 85) }
    static func valid(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && (1...130).contains($0) ? $0 : nil }
    }
    static func ssd(_ value: Double?) -> Self { classify(value, warm: 60, hot: 70) }
    private static func classify(_ value: Double?, warm: Double, hot: Double) -> Self {
        guard let value, value.isFinite, (1...130).contains(value) else { return .normal }
        return value >= hot ? .hot : value >= warm ? .warm : .normal
    }
}

struct FanSnapshot {
    let rpms: [Double?]?
    init(rpms: [Double?]?) {
        self.rpms = rpms.flatMap { values in
            guard values.count <= 8 else { return nil }
            return values.map { value in value.flatMap { $0.isFinite && (0...30000).contains($0) ? $0 : nil } }
        }
    }
    static let unavailable = FanSnapshot(rpms: nil)
    var isRunning: Bool { rpms?.contains { ($0 ?? 0) > 0 } == true }
    var state: String {
        guard let rpms else { return L10n.text("팬 정보 없음") }
        if rpms.isEmpty { return L10n.text("팬 없음") }
        if isRunning { return L10n.text("회전 중") }
        if rpms.contains(where: { $0 == nil }) { return L10n.text("팬 읽기 불가") }
        return L10n.text("정지")
    }
    var detail: String {
        guard let rpms, !rpms.isEmpty else { return state }
        return rpms.enumerated().map { index, rpm in
            L10n.format("팬 %d: %@", index + 1, rpm.map { String(format: "%.0f RPM", $0) } ?? L10n.text("정보 없음"))
        }.joined(separator: " · ")
    }
    var compact: String {
        guard let rpms, !rpms.isEmpty else { return state }
        let values = rpms.prefix(2).map { $0.map { String(format: "%.0f", $0) } ?? "—" }.joined(separator: " / ")
        let extra = rpms.count > 2 ? String(format: " +%d", rpms.count - 2) : ""
        return state + " · " + values + " RPM" + extra
    }
}

struct Snapshot {
    let cpuTemperature: Double?
    let ssdTemperature: Double?
    let cpuUsage: Double?
    let upload: Double?
    let download: Double?
    let interfaces: Int
    let cpuSensors: Int
    let ssdSensors: Int
    let thermal: ThermalStatus
    let time: Date
    let uptime: TimeInterval?
    let resources: ResourceSnapshot
    var fans: FanSnapshot = .unavailable
    var gpuTemperature: Double? = nil
    var memoryProximityTemperature: Double? = nil
    var gpuSensors: Int = 0
    var memoryProximitySensors: Int = 0
    var gpuWarning: TemperatureWarning { .gpu(gpuTemperature) }
    var memoryProximityWarning: TemperatureWarning { .memoryProximity(memoryProximityTemperature) }
    var cpuWarning: TemperatureWarning { .cpu(cpuTemperature) }
    var ssdWarning: TemperatureWarning { .ssd(ssdTemperature) }

    static var pending: Snapshot {
        Snapshot(cpuTemperature: nil, ssdTemperature: nil, cpuUsage: nil, upload: nil, download: nil, interfaces: 0, cpuSensors: 0, ssdSensors: 0, thermal: ThermalStatus(ProcessInfo.processInfo.thermalState), time: Date(), uptime: nil, resources: .pending)
    }
}

func temperature(_ value: Double?) -> String {
    value.map { String(format: "%.0f°", $0) } ?? "—"
}

func speed(_ value: Double?, compact: Bool = false) -> String {
    guard let value else { return "—" }
    let suffix = compact ? "" : "/s"
    if value >= 1_000_000_000 { return String(format: "%.1fG%@", value / 1_000_000_000, suffix) }
    if value >= 1_000_000 { return String(format: "%.1fM%@", value / 1_000_000, suffix) }
    if value >= 1_000 { return String(format: "%.0fK%@", value / 1_000, suffix) }
    return String(format: "%.0fB%@", value, suffix)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menuContent = MenuBarContent(frame: .zero)
    private let panel = PanelController()
    private let codexPanel = CodexPanelController()
    private let codexMonitor = CodexMonitor()
    private let quotaClient = CodexQuotaClient()
    private let resetNotificationTransport = CodexNativeResetNotifications()
    private lazy var resetNotifications = CodexResetNotifications(transport: resetNotificationTransport)
    private lazy var accountPresenter = CodexAccountPresenter(client: quotaClient)
    private var accountObservers: [NSObjectProtocol] = []
    private var codexSnapshot = CodexMonitorSnapshot.pending
    private lazy var dashboard: DashboardWindow = {
        let window = DashboardWindow(controller: panel, companion: codexPanel,
                                     companionSize: CodexPanelController.surfaceSize)
        window.companionIsAvailable = { [weak self] in CodexMonitor.isCodexRunning() || self?.quotaClient.latest.isEnabled == true }
        window.prepareCompanion = { [weak self] in self?.codexPanel.prepareForPresentation() }
        return window
    }()
    private let sampleQueue = DispatchQueue(label: "local.mac-thermal.metrics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var screenObserver: NSObjectProtocol?
    private var lastSample = Snapshot.pending
    private var panelRequest = PanelPresentationRequest()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read synchronously while the launch Apple event is still current.
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchSource = launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let launchedAtLogin = launchEvent?.eventID == AEEventID(kAEOpenApplication) &&
            (launchSource == OSType(keyAELaunchedAsLogInItem) || launchSource == OSType(keyAELaunchedAsServiceItem))
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.title = ""
            button.image = nil
            menuContent.attach(to: button)
        }
        panel.refresh = { [weak self] in self?.requestSample() }
        codexPanel.refresh = { [weak self] in self?.codexMonitor.refresh(); self?.quotaClient.refresh() }
        codexPanel.accountAction = { [weak self] in self?.accountPresenter.showAccount() }
        codexPanel.usageAction = { [weak self] in self?.accountPresenter.showUsageReview() }
        codexPanel.summaryAction = { [weak self] in self?.accountPresenter.showSummaryReview() }
        panel.codexRecordsEnabledChanged = { [weak self] enabled in self?.codexMonitor.setRecordsEnabled(enabled) }
        panel.codexResetNotificationsChanged = { [weak self] enabled in self?.resetNotifications.setEnabled(enabled) }
        resetNotifications.onChange = { [weak self] in
            guard let self else { return }
            self.panel.updateCodexResetNotifications(enabled: self.resetNotifications.enabled,
                statusKey: self.resetNotifications.statusKey, requesting: self.resetNotifications.requesting)
        }
        resetNotificationTransport.mayPresent = { [weak self] in self?.resetNotifications.enabled == true }
        resetNotifications.start()
        codexMonitor.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            self.codexSnapshot = snapshot
            self.codexSnapshot.quota = self.quotaClient.latest
            self.renderCodex()
        }
        quotaClient.onUpdate = { [weak self] quota in
            guard let self else { return }
            self.resetNotifications.receive(quota)
            self.codexSnapshot.quota = quota
            self.renderCodex()
            self.accountPresenter.receive(quota)
        }
        quotaClient.onDeviceLogin = { [weak self] url, code in self?.accountPresenter.showDeviceLogin(url: url, code: code) }
        quotaClient.onCredentialRemovalFailure = { [weak self] in self?.accountPresenter.showRemovalFailure() }
        let workspace = NSWorkspace.shared.notificationCenter
        accountObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.quotaClient.suspend() })
        accountObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.quotaClient.startSavedConnection() })
        quotaClient.startSavedConnection()
        codexMonitor.start()
        panel.menuBarPreferencesChanged = { [weak self] preferences in
            guard let self else { return }
            self.menuContent.preferences = preferences
            if abs(self.statusItem.length - self.menuContent.contentWidth) > 0.5 {
                self.statusItem.length = self.menuContent.contentWidth
            }
        }
        _ = panel.view
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hidePanel()
        }
        render(lastSample)
        let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
        if !launchedAtLogin { requestPanelShow() }
        if !UserDefaults.standard.bool(forKey: "startupConfigured") && Bundle.main.bundleURL.path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            do {
                try LoginItemManager.enable()
                if LoginItemManager.state().enabled { UserDefaults.standard.set(true, forKey: "startupConfigured") }
            } catch { NSLog("Mac Thermal login item registration: %@", error.localizedDescription) }
            panel.updateLoginState()
        }
    }

    private func requestSample() {
        sampleQueue.async { [weak self] in self?.sample() }
    }

    private func sample() {
        let sensors = mt_thermal_read()
        let metrics = mt_system_metrics_sample()
        let snapshot = Snapshot(
            cpuTemperature: sensors.cpu_sensor_count > 0 ? sensors.cpu_celsius : nil,
            ssdTemperature: sensors.ssd_sensor_count > 0 ? sensors.ssd_celsius : nil,
            cpuUsage: metrics.cpu_valid != 0 ? metrics.cpu_usage_percent : nil,
            upload: metrics.network_valid != 0 ? metrics.upload_bytes_per_second : nil,
            download: metrics.network_valid != 0 ? metrics.download_bytes_per_second : nil,
            interfaces: Int(metrics.interface_count), cpuSensors: Int(sensors.cpu_sensor_count), ssdSensors: Int(sensors.ssd_sensor_count),
            thermal: ThermalStatus(ProcessInfo.processInfo.thermalState), time: Date(), uptime: SystemUptime.seconds(), resources: ResourceSampler.sample(), fans: readFans(),
            gpuTemperature: sensors.gpu_sensor_count > 0 ? sensors.gpu_celsius : nil,
            memoryProximityTemperature: sensors.memory_proximity_sensor_count > 0 ? sensors.memory_proximity_celsius : nil,
            gpuSensors: Int(sensors.gpu_sensor_count), memoryProximitySensors: Int(sensors.memory_proximity_sensor_count))
        DispatchQueue.main.async { [weak self] in self?.render(snapshot) }
    }

    private func renderCodex() {
        let recordsState: CodexRecordsSettingsState = !codexSnapshot.recordsEnabled ? .disabled :
            codexSnapshot.incomplete ? .partial : codexSnapshot.connection == .connecting ? .reading :
            codexSnapshot.connection == .connected ? .ready : .unavailable
        panel.updateCodexRecords(recordsState)
        codexPanel.apply(codexSnapshot)
        menuContent.update(codex: codexSnapshot)
        if abs(statusItem.length - menuContent.contentWidth) > 0.5 { statusItem.length = menuContent.contentWidth }
    }

    private func render(_ sample: Snapshot) {
        quotaClient.tick()
        lastSample = sample
        menuContent.update(sample: sample)
        if abs(statusItem.length - menuContent.contentWidth) > 0.5 {
            statusItem.length = menuContent.contentWidth
        }
        panel.apply(sample)
        if dashboard.isVisible { codexPanel.apply(codexSnapshot) }
    }

    @objc private func togglePanel() {
        if dashboard.isVisible || panelRequest.pending { hidePanel() }
        else { requestPanelShow() }
    }

    private func requestPanelShow() {
        guard !dashboard.isVisible else { panelRequest.cancel(); return }
        let token = panelRequest.begin()
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.main.async { [weak self] in self?.showPendingPanel(token: token) }
    }

    private func showPendingPanel(token: UInt) {
        let button = statusItem.button
        switch panelRequest.evaluate(token: token, hasAnchor: button?.window != nil,
                                     isActive: NSApp.isActive, isVisible: dashboard.isVisible) {
        case .show:
            if let button { dashboard.show(below: button) }
        case .retry:
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.showPendingPanel(token: token)
            }
        case .ignore, .finished, .abandon:
            break
        }
    }

    private func hidePanel() {
        panelRequest.cancel()
        dashboard.orderOut(nil)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let token = panelRequest.token else { return }
        DispatchQueue.main.async { [weak self] in self?.showPendingPanel(token: token) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        requestPanelShow()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        hidePanel()
    }

    // Native popup menus temporarily take key focus. App deactivation, the
    // status item and Escape dismiss the panel; losing key status alone does not.

    func applicationWillTerminate(_ notification: Notification) {
        menuContent.stop()
        codexMonitor.stop()
        resetNotifications.stop()
        quotaClient.stop()
        accountObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        timer?.cancel()
        sampleQueue.sync {
            mt_thermal_close()
            mt_process_metrics_reset()
            mt_gpu_metrics_close()
        }
    }
}

private func readFans() -> FanSnapshot {
    let reading = mt_fan_read()
    guard (0...Int32(MT_MAX_FANS)).contains(reading.count) else { return .unavailable }
    let values: [Double?] = withUnsafeBytes(of: reading.rpm) { bytes in
        let rpms = bytes.bindMemory(to: Double.self)
        return (0..<Int(reading.count)).map { index in
            reading.valid_mask & (1 << index) != 0 ? rpms[index] : nil
        }
    }
    return FanSnapshot(rpms: values)
}

if CommandLine.arguments.contains("--diagnostics") {
    let sensors = mt_thermal_read()
    _ = mt_system_metrics_sample()
    _ = ResourceSampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let metrics = mt_system_metrics_sample()
    let resources = ResourceSampler.sample()
    let startup = LoginItemManager.state()
    let result: [String: Any] = [
        "cpu_celsius": sensors.cpu_sensor_count > 0 ? sensors.cpu_celsius as Any : NSNull(),
        "ssd_celsius": sensors.ssd_sensor_count > 0 ? sensors.ssd_celsius as Any : NSNull(),
        "cpu_sensor_count": sensors.cpu_sensor_count,
        "cpu_usage_percent": metrics.cpu_valid != 0 ? metrics.cpu_usage_percent as Any : NSNull(),
        "gpu_usage_percent": resources.gpu.utilizationPercent as Any? ?? NSNull(),
        "gpu_celsius": sensors.gpu_sensor_count > 0 ? sensors.gpu_celsius as Any : NSNull(),
        "gpu_temperature_sensor_count": sensors.gpu_sensor_count,
        "memory_proximity_celsius": sensors.memory_proximity_sensor_count > 0 ? sensors.memory_proximity_celsius as Any : NSNull(),
        "memory_proximity_sensor_count": sensors.memory_proximity_sensor_count,
        "gpu_model": resources.gpu.model as Any? ?? NSNull(),
        "gpu_core_count": resources.gpu.coreCount as Any? ?? NSNull(),
        "upload_bytes_per_second": metrics.network_valid != 0 ? metrics.upload_bytes_per_second as Any : NSNull(),
        "download_bytes_per_second": metrics.network_valid != 0 ? metrics.download_bytes_per_second as Any : NSNull(),
        "thermal_status": ThermalStatus(ProcessInfo.processInfo.thermalState).title,
        "uptime_seconds": SystemUptime.seconds() as Any? ?? NSNull(),
        "login_enabled": startup.enabled, "login_requires_approval": startup.requiresApproval,
        "memory_total_bytes": resources.memory.totalBytes as Any? ?? NSNull(),
        "memory_used_bytes": resources.memory.usedBytes as Any? ?? NSNull(),
        "memory_compressed_bytes": resources.memory.compressedBytes as Any? ?? NSNull(),
        "swap_used_bytes": resources.memory.swapUsedBytes as Any? ?? NSNull(),
        "memory_pressure_level": resources.memory.pressureLevel as Any? ?? NSNull(),
        "process_cpu_ready": resources.processes.cpuReady,
        "process_readable_count": resources.processes.readableCount,
        "process_skipped_count": resources.processes.skippedCount,
        "cpu_top": resources.processes.cpuTop.map { ["pid": $0.pid, "name": $0.name, "cpu_percent": $0.cpuPercent as Any? ?? NSNull()] as [String: Any] },
        "memory_top": resources.processes.memoryTop.map { ["pid": $0.pid, "name": $0.name, "memory_bytes": $0.memoryBytes] as [String: Any] },
        "disk_total_bytes": resources.disk.totalBytes as Any? ?? NSNull(),
        "disk_available_bytes": resources.disk.availableBytes as Any? ?? NSNull(),
        "disk_read_bytes_per_second": resources.disk.readBytesPerSecond as Any? ?? NSNull(),
        "disk_write_bytes_per_second": resources.disk.writeBytesPerSecond as Any? ?? NSNull(),
        "disk_device_count": resources.disk.deviceCount
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    mt_thermal_close()
    mt_process_metrics_reset()
    mt_gpu_metrics_close()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
