import Foundation

struct CPUUsageHistory {
    struct Point {
        let time: TimeInterval
        let percent: Double?
    }
    private(set) var points: [Point] = []
    private(set) var endTime: TimeInterval = 0

    mutating func append(_ percent: Double?, at time: TimeInterval?) {
        guard let time, time.isFinite, time >= 0 else { return }
        if time < endTime { points.removeAll() }
        endTime = time
        points.removeAll { $0.time < time - 60 }
        let valid = percent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        // Coalesce rapid manual refreshes without growing history indefinitely.
        if let last = points.last, time - last.time < 0.25 { points.removeLast() }
        points.append(Point(time: time, percent: valid))
        if points.count > 120 { points.removeFirst(points.count - 120) }
    }

    /// Missing samples and suspend/resume gaps are visibly disconnected.
    var runs: [[Point]] {
        var result: [[Point]] = []
        var current: [Point] = []
        for point in points {
            if point.percent == nil || (current.last.map { point.time - $0.time > 6 } ?? false) {
                if !current.isEmpty { result.append(current) }
                current = []
            }
            if point.percent != nil { current.append(point) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
