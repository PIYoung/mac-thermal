import Foundation

enum MenuBarAnimationStyle: Int, CaseIterable {
    case rhythm = 0
    case orbit = 1

    var title: String { L10n.text(self == .rhythm ? "리듬 막대" : "순환 점") }
}

enum MenuBarMetric: String, CaseIterable {
    case cpu, gpu, ssd, network

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .network: return L10n.text("네트워크")
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
    private static let visibleMetricsKey = "menuBarVisibleMetricsV1"

    static func load(defaults: UserDefaults = .standard) -> Self {
        let storedIntensity = defaults.object(forKey: intensityKey) as? Double ?? 1.2
        let visibleMetrics: Set<MenuBarMetric>
        if let stored = defaults.object(forKey: visibleMetricsKey) {
            if let values = stored as? [String], values.allSatisfy({ MenuBarMetric(rawValue: $0) != nil }) {
                visibleMetrics = Set(values.compactMap(MenuBarMetric.init(rawValue:)))
            } else {
                visibleMetrics = Set(MenuBarMetric.allCases)
            }
        } else {
            switch defaults.object(forKey: primaryMetricKey) as? Int {
            case 0: visibleMetrics = [.cpu, .ssd, .network]
            case 1: visibleMetrics = [.gpu, .ssd, .network]
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
