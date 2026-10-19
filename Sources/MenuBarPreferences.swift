import Foundation

enum MenuBarAnimationStyle: Int, CaseIterable {
    case rhythm = 0
    case orbit = 1

    var title: String { L10n.text(self == .rhythm ? "리듬 막대" : "순환 점") }
}

enum MenuBarPrimaryMetric: Int, CaseIterable {
    case cpu = 0
    case gpu = 1
    case cpuAndGPU = 2

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .cpuAndGPU: return L10n.text("CPU + GPU")
        }
    }

    var showsCPU: Bool { self != .gpu }
    var showsGPU: Bool { self != .cpu }
}

struct MenuBarPreferences: Equatable {
    var style: MenuBarAnimationStyle = .rhythm
    var motionEnabled = true
    var intensity = 1.2
    var primaryMetric: MenuBarPrimaryMetric = .cpuAndGPU

    private static let styleKey = "menuBarAnimationStyleV2"
    private static let motionKey = "menuBarMotionEnabledV2"
    private static let intensityKey = "menuBarMotionIntensityV2"
    private static let primaryMetricKey = "menuBarPrimaryMetricV1"

    static func load(defaults: UserDefaults = .standard) -> Self {
        let storedIntensity = defaults.object(forKey: intensityKey) as? Double ?? 1.2
        let storedMetric = defaults.object(forKey: primaryMetricKey) as? Int
        return Self(
            style: MenuBarAnimationStyle(rawValue: defaults.integer(forKey: styleKey)) ?? .rhythm,
            motionEnabled: defaults.object(forKey: motionKey) as? Bool ?? true,
            intensity: storedIntensity.isFinite ? max(0.75, min(1.5, storedIntensity)) : 1.2,
            primaryMetric: storedMetric.flatMap(MenuBarPrimaryMetric.init(rawValue:)) ?? .cpuAndGPU)
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: Self.styleKey)
        defaults.set(motionEnabled, forKey: Self.motionKey)
        defaults.set(intensity.isFinite ? max(0.75, min(1.5, intensity)) : 1.2, forKey: Self.intensityKey)
        defaults.set(primaryMetric.rawValue, forKey: Self.primaryMetricKey)
    }
}
