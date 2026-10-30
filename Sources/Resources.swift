import Foundation
import AppKit

struct MemorySnapshot {
    let totalBytes: Double?
    let usedBytes: Double?
    let compressedBytes: Double?
    let swapUsedBytes: Double?
    let pressureLevel: Int?

    static let pending = MemorySnapshot(totalBytes: nil, usedBytes: nil, compressedBytes: nil, swapUsedBytes: nil, pressureLevel: nil)
}

struct ResourceProcess {
    var name: String
    let pid: Int
    let cpuPercent: Double?
    let memoryBytes: Double
    var processCount: Int = 1
    var members: [ResourceProcess] = []
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

struct GPUSnapshot {
    let utilizationPercent: Double?
    let model: String?
    let coreCount: Int?

    static let pending = GPUSnapshot(utilizationPercent: nil, model: nil, coreCount: nil)
}

struct ResourceSnapshot {
    let memory: MemorySnapshot
    let processes: ProcessSnapshot
    let disk: DiskSnapshot
    let gpu: GPUSnapshot

    init(memory: MemorySnapshot, processes: ProcessSnapshot, disk: DiskSnapshot,
         gpu: GPUSnapshot = .pending) {
        self.memory = memory
        self.processes = processes
        self.disk = disk
        self.gpu = gpu
    }

    static let pending = ResourceSnapshot(memory: .pending, processes: .pending, disk: .pending)
}

enum ResourceSampler {
    static func sample() -> ResourceSnapshot {
        let memory = mt_memory_metrics_sample()
        let processes = mt_process_metrics_sample()
        let disk = mt_disk_metrics_sample()
        var gpu = mt_gpu_metrics_sample()

        let memorySnapshot = MemorySnapshot(
            totalBytes: memory.valid != 0 ? Double(memory.total_bytes) : nil,
            usedBytes: memory.valid != 0 ? Double(memory.used_bytes) : nil,
            compressedBytes: memory.valid != 0 ? Double(memory.compressed_bytes) : nil,
            swapUsedBytes: memory.swap_valid != 0 ? Double(memory.swap_used_bytes) : nil,
            pressureLevel: memory.pressure_valid != 0 ? Int(memory.pressure_level) : nil)

        func process(_ value: MTProcessEntry) -> ResourceProcess {
            var entry = value
            let pid = Int(entry.pid)
            let name = withUnsafePointer(to: &entry.name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 128) {
                    String(validatingCString: $0) ?? "PID \(pid)"
                }
            }
            let cpu = entry.cpu_usage_percent
            return ResourceProcess(name: name.isEmpty ? "PID \(pid)" : name,
                pid: pid, cpuPercent: entry.cpu_valid != 0 && cpu.isFinite ? max(0, min(100, cpu)) : nil,
                memoryBytes: Double(entry.memory_bytes), processCount: max(1, Int(entry.process_count)))
        }
        var cachedMembers: [Int32: [ResourceProcess]] = [:]
        func entries<T>(_ storage: T, count: Int32) -> [ResourceProcess] {
            withUnsafePointer(to: storage) { storagePointer in
                storagePointer.withMemoryRebound(to: MTProcessEntry.self, capacity: 3) { pointer in
                    (0..<max(0, min(3, Int(count)))).map { index in
                        let entry = pointer[index]
                        var group = process(entry)
                        // Prefer the running app's display name only for its outer
                        // bundle, never a nested helper's misleading localized name.
                        if let app = NSRunningApplication(processIdentifier: entry.pid),
                           app.bundleURL?.deletingPathExtension().lastPathComponent == group.name,
                           let displayName = app.localizedName, !displayName.isEmpty {
                            group.name = displayName
                        }
                        if let cached = cachedMembers[entry.pid] { group.members = cached }
                        else {
                            let count = min(32768, max(0, Int(mt_process_group_members(entry.pid, nil, 0))))
                            if count > 0 {
                                var members = [MTProcessEntry](repeating: MTProcessEntry(), count: count)
                                let copied = members.withUnsafeMutableBufferPointer {
                                    mt_process_group_members(entry.pid, $0.baseAddress, Int32(count))
                                }
                                if copied == count { group.members = members.map(process) }
                            }
                            cachedMembers[entry.pid] = group.members
                        }
                        return group
                    }
                }
            }
        }

        let processSnapshot = ProcessSnapshot(
            cpuTop: entries(processes.cpu_top, count: processes.cpu_count),
            memoryTop: entries(processes.memory_top, count: processes.memory_count),
            cpuReady: processes.cpu_ready != 0, readableCount: Int(processes.readable_count),
            skippedCount: Int(processes.skipped_count), available: processes.valid != 0)
        let diskSnapshot = DiskSnapshot(
            totalBytes: disk.capacity_valid != 0 ? Double(disk.total_bytes) : nil,
            availableBytes: disk.capacity_valid != 0 ? Double(disk.available_bytes) : nil,
            readBytesPerSecond: disk.io_valid != 0 ? disk.read_bytes_per_second : nil,
            writeBytesPerSecond: disk.io_valid != 0 ? disk.write_bytes_per_second : nil,
            deviceCount: Int(disk.device_count))
        let gpuModel = withUnsafePointer(to: &gpu.model) { modelPointer in
            modelPointer.withMemoryRebound(to: CChar.self, capacity: 128) {
                String(validatingCString: $0)
            }
        }
        let gpuSnapshot = GPUSnapshot(
            utilizationPercent: gpu.utilization_valid != 0 && gpu.utilization_percent.isFinite &&
                (0...100).contains(gpu.utilization_percent) ? gpu.utilization_percent : nil,
            model: gpuModel.flatMap { $0.isEmpty ? nil : $0 },
            coreCount: gpu.core_count > 0 ? Int(gpu.core_count) : nil)
        return ResourceSnapshot(memory: memorySnapshot, processes: processSnapshot,
                                disk: diskSnapshot, gpu: gpuSnapshot)
    }
}
