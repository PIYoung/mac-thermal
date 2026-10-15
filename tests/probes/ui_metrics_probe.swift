import Foundation

@main
enum UIMetricsProbe {
    static func main() {
        precondition(SystemUptime.label(0, language: .korean) == "부팅 후 1분 미만")
        precondition(SystemUptime.label(59, language: .korean) == "부팅 후 1분 미만")
        precondition(SystemUptime.label(60, language: .korean) == "부팅 후 1분")
        precondition(SystemUptime.label(3_600, language: .korean) == "부팅 후 1시간 0분")
        precondition(SystemUptime.label(86_400, language: .korean) == "부팅 후 1일 0시간 0분")
        precondition(SystemUptime.label(90_060, language: .korean) == "부팅 후 1일 1시간 1분")
        precondition(SystemUptime.label(.nan, language: .korean) == "부팅 후 시간 확인 불가")
        precondition(SystemUptime.label(-1, language: .korean) == "부팅 후 시간 확인 불가")
        precondition(SystemUptime.label(nil, language: .korean) == "부팅 후 시간 확인 불가")
        let before = SystemUptime.seconds()!
        Thread.sleep(forTimeInterval: 0.1)
        let after = SystemUptime.seconds()!
        precondition(before > 0 && after > before && after - before < 2)

        var history = CPUUsageHistory()
        history.append(nil, at: 1_000)
        precondition(history.runs.isEmpty) // Missing baseline must not become 0%.
        history.append(0, at: 1_002)
        history.append(100, at: 1_004)
        precondition(history.runs.count == 1 && history.runs[0].count == 2)
        history.append(nil, at: 1_006)
        history.append(35, at: 1_008)
        precondition(history.runs.count == 2) // Failed reads break the line.
        history.append(40, at: 1_020)
        precondition(history.runs.count == 3) // Suspend/resume is not interpolated.
        history.append(10, at: 1_100)
        precondition(history.points.count == 1) // Older than one minute is gone.
        history.append(10, at: 999)
        precondition(history.points.count == 1) // Backward clock starts fresh.
        history.append(.infinity, at: 1_001)
        precondition(history.points.last?.percent == nil)
        for i in 0..<500 { history.append(10, at: 1_100 + Double(i) * 0.3) }
        precondition(history.points.count <= 120)
        print("Uptime formatting/continuous clock and CPU history baseline/gaps/retention checks passed")
    }
}
