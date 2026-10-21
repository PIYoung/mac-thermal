import Foundation

enum MenuBarAnimationStyle: Int, CaseIterable {
    case rhythm = 0
    case orbit = 1
    case wave = 2
    case pinwheel = 3
    case bounce = 4
    case radar = 5
    case piston = 6
    case conveyor = 7
    case hourglass = 8
    case pendulum = 9

    var title: String {
        L10n.text(["리듬 막대", "순환 점", "웨이브", "바람개비", "통통 공", "레이더", "피스톤", "컨베이어", "모래시계", "진자"][rawValue])
    }
}

enum MenuBarMetric: String, CaseIterable {
    case cpu, gpu, ssd, network, codex

    /// Menu presentation order is independent of settings and saved identifiers.
    static let menuOrder: [Self] = [.codex, .cpu, .gpu, .ssd, .network]

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .network: return L10n.text("네트워크")
        case .codex: return "Codex"
        }
    }
}

struct MenuBarPreferences: Equatable {
    var style: MenuBarAnimationStyle = .rhythm
    var motionEnabled = true
    var intensity = 1.2
    var visibleMetrics: Set<MenuBarMetric> = Set(MenuBarMetric.allCases)

    private static let styleKey = "menuBarAnimationStyleV2"
    private static let motionKey = "menuBarMotionEnabledV2"
    private static let intensityKey = "menuBarMotionIntensityV2"
    private static let primaryMetricKey = "menuBarPrimaryMetricV1"
    private static let visibleMetricsKey = "menuBarVisibleMetricsV2"
    private static let legacyVisibleMetricsKey = "menuBarVisibleMetricsV1"

    static func load(defaults: UserDefaults = .standard) -> Self {
        let storedIntensity = defaults.object(forKey: intensityKey) as? Double ?? 1.2
        let visibleMetrics: Set<MenuBarMetric>
        if let stored = defaults.object(forKey: visibleMetricsKey) {
            if let values = stored as? [String], values.allSatisfy({ MenuBarMetric(rawValue: $0) != nil }) {
                visibleMetrics = Set(values.compactMap(MenuBarMetric.init(rawValue:)))
            } else {
                visibleMetrics = Set(MenuBarMetric.allCases)
            }
        } else if let values = defaults.stringArray(forKey: legacyVisibleMetricsKey),
                  values.allSatisfy({ MenuBarMetric(rawValue: $0) != nil }) {
            // Add the newly requested Codex item once; V2 preserves later opt-outs.
            visibleMetrics = Set(values.compactMap(MenuBarMetric.init(rawValue:))).union([.codex])
        } else {
            switch defaults.object(forKey: primaryMetricKey) as? Int {
            case 0: visibleMetrics = [.cpu, .ssd, .network, .codex]
            case 1: visibleMetrics = [.gpu, .ssd, .network, .codex]
            default: visibleMetrics = Set(MenuBarMetric.allCases)
            }
        }
        return Self(
            style: MenuBarAnimationStyle(rawValue: defaults.integer(forKey: styleKey)) ?? .rhythm,
            motionEnabled: defaults.object(forKey: motionKey) as? Bool ?? true,
            intensity: storedIntensity.isFinite ? max(0.75, min(1.5, storedIntensity)) : 1.2,
            visibleMetrics: visibleMetrics)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(motionEnabled, forKey: Self.motionKey)
        defaults.set(intensity.isFinite ? max(0.75, min(1.5, intensity)) : 1.2, forKey: Self.intensityKey)
        defaults.set(MenuBarMetric.allCases.filter(visibleMetrics.contains).map(\.rawValue), forKey: Self.visibleMetricsKey)
    }
}
