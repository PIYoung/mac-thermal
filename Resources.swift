import Foundation

struct MemorySnapshot {
    let totalBytes: Double?
    let usedBytes: Double?
    let compressedBytes: Double?
    let swapUsedBytes: Double?
    let pressureLevel: Int?

    static let pending = MemorySnapshot(totalBytes: nil, usedBytes: nil, compressedBytes: nil, swapUsedBytes: nil, pressureLevel: nil)
}

struct ResourceProcess {
    let name: String
    let pid: Int
    let cpuPercent: Double?
    let memoryBytes: Double
}

struct ProcessSnapshot {
    let cpuTop: [ResourceProcess]
    let memoryTop: [ResourceProcess]
    let cpuReady: Bool
    let readableCount: Int
    let skippedCount: Int
    let available: Bool

    static let pending = ProcessSnapshot(cpuTop: [], memoryTop: [], cpuReady: false, readableCount: 0, skippedCount: 0, available: false)
}

struct DiskSnapshot {
    let totalBytes: Double?
    let availableBytes: Double?
    let readBytesPerSecond: Double?
    let writeBytesPerSecond: Double?
    let deviceCount: Int

    static let pending = DiskSnapshot(totalBytes: nil, availableBytes: nil, readBytesPerSecond: nil, writeBytesPerSecond: nil, deviceCount: 0)
}

struct ResourceSnapshot {
    let memory: MemorySnapshot
    let processes: ProcessSnapshot
    let disk: DiskSnapshot

    static let pending = ResourceSnapshot(memory: .pending, processes: .pending, disk: .pending)
}

enum ResourceSampler {
    static func sample() -> ResourceSnapshot {
        let memory = mt_memory_metrics_sample()
        let processes = mt_process_metrics_sample()
        let disk = mt_disk_metrics_sample()

        let memorySnapshot = MemorySnapshot(
            totalBytes: memory.valid != 0 ? Double(memory.total_bytes) : nil,
            usedBytes: memory.valid != 0 ? Double(memory.used_bytes) : nil,
            compressedBytes: memory.valid != 0 ? Double(memory.compressed_bytes) : nil,
            swapUsedBytes: memory.swap_valid != 0 ? Double(memory.swap_used_bytes) : nil,
            pressureLevel: memory.pressure_valid != 0 ? Int(memory.pressure_level) : nil)

        func entries<T>(_ storage: T, count: Int32, cpuReady: Bool) -> [ResourceProcess] {
            withUnsafePointer(to: storage) { storagePointer in
                storagePointer.withMemoryRebound(to: MTProcessEntry.self, capacity: 3) { pointer in
                    (0..<max(0, min(3, Int(count)))).map { index in
                        var entry = pointer[index]
                        let pid = Int(entry.pid)
                        let name = withUnsafePointer(to: &entry.name) { namePointer in
                            namePointer.withMemoryRebound(to: CChar.self, capacity: 128) {
                                String(validatingCString: $0) ?? "PID \(pid)"
                            }
                        }
                        let cpu = entry.cpu_usage_percent
                        return ResourceProcess(name: name.isEmpty ? "PID \(pid)" : name,
                            pid: pid, cpuPercent: cpuReady && cpu.isFinite ? max(0, min(100, cpu)) : nil,
                            memoryBytes: Double(entry.memory_bytes))
                    }
                }
            }
        }

        let processSnapshot = ProcessSnapshot(
            cpuTop: entries(processes.cpu_top, count: processes.cpu_count, cpuReady: processes.cpu_ready != 0),
            memoryTop: entries(processes.memory_top, count: processes.memory_count, cpuReady: processes.cpu_ready != 0),
            cpuReady: processes.cpu_ready != 0, readableCount: Int(processes.readable_count),
            skippedCount: Int(processes.skipped_count), available: processes.valid != 0)
        let diskSnapshot = DiskSnapshot(
            totalBytes: disk.capacity_valid != 0 ? Double(disk.total_bytes) : nil,
            availableBytes: disk.capacity_valid != 0 ? Double(disk.available_bytes) : nil,
            readBytesPerSecond: disk.io_valid != 0 ? disk.read_bytes_per_second : nil,
            writeBytesPerSecond: disk.io_valid != 0 ? disk.write_bytes_per_second : nil,
            deviceCount: Int(disk.device_count))
        return ResourceSnapshot(memory: memorySnapshot, processes: processSnapshot, disk: diskSnapshot)
    }
}
