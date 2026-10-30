import Combine
import Darwin
import Foundation

/// **Map Ranking — CPU, RAM y disco** para la isla, solo locales y solo
/// mientras la isla está abierta (plegada no se muestran, así no se leen).
/// Lo mismo que `sysmetrics.rs` en Windows, con las fuentes de macOS.
struct IslandDisk: Equatable, Identifiable {
    var id: String
    var name: String
    var total: Int64
    var free: Int64
    var isRoot: Bool

    var usedFraction: Double {
        total > 0 ? min(1, max(0, Double(total - free) / Double(total))) : 0
    }
}

struct IslandSystemReading: Equatable {
    /// 0…1; nil en la primera lectura (hacen falta dos para saber el uso).
    var cpu: Double?
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var disks: [IslandDisk]

    var memoryFraction: Double {
        memoryTotal > 0 ? min(1, Double(memoryUsed) / Double(memoryTotal)) : 0
    }
}

enum IslandSystem {
    struct CPUTicks: Equatable {
        var busy: UInt64
        var total: UInt64
    }

    private static let host = mach_host_self()

    /// Los ticks de todos los núcleos desde el arranque.
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// El uso entre dos lecturas, 0…1.
    static func cpuFraction(from earlier: CPUTicks, to later: CPUTicks) -> Double? {
        guard later.total > earlier.total, later.busy >= earlier.busy else { return nil }
        return min(1, max(0, Double(later.busy - earlier.busy) / Double(later.total - earlier.total)))
    }

    /// La memoria usada como la cuenta el Monitor de Actividad: la de las apps,
    /// la fija y la comprimida.
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count)
        let purgeable = min(UInt64(stats.purgeable_count), appPages)
        let pages = appPages - purgeable + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        let total = ProcessInfo.processInfo.physicalMemory
        return (min(pages * page, total), total)
    }

    /// El disco de arranque primero y luego los demás locales (hasta tres).
    static func disks() -> [IslandDisk] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey, .volumeIsRootFileSystemKey,
        ]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        var disks: [IslandDisk] = []
        for url in volumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  let total = values.volumeTotalCapacity, total > 0
            else { continue }
            let free = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)
            let isRoot = values.volumeIsRootFileSystem == true
            disks.append(IslandDisk(id: url.path,
                                    name: isRoot ? "Disco" : (values.volumeName ?? url.lastPathComponent),
                                    total: Int64(total), free: max(0, free), isRoot: isRoot))
        }
        let ordered = disks.sorted { a, b in
            a.isRoot != b.isRoot ? a.isRoot : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(ordered.prefix(3))
    }

    /// Lo libre como lo dice Finder (GB de mil): con un decimal debajo de 100 GB.
    static func freeText(_ bytes: Int64) -> String {
        let gigabytes = Double(max(0, bytes)) / 1_000_000_000
        if gigabytes >= 1000 { return String(format: "%.1f TB", gigabytes / 1000) }
        if gigabytes >= 100 { return String(format: "%.0f GB", gigabytes) }
        return String(format: "%.1f GB", gigabytes)
    }

    static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

/// Lee cada 2 s mientras está activo (la isla abierta y «Sistema» encendido).
@MainActor
final class IslandSystemMonitor: ObservableObject {
    @Published private(set) var reading: IslandSystemReading?

    var active = false {
        didSet {
            guard active != oldValue else { return }
            if active { start() } else { stop() }
        }
    }

    private var timer: Timer?
    private var lastTicks: IslandSystem.CPUTicks?
    private var lastDiskRead: Date?
    private var disks: [IslandDisk] = []

    private func start() {
        refresh()
        // La CPU necesita dos lecturas: la segunda llega enseguida.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, self.active else { return }
            self.refresh()
        }
        let poll = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        poll.tolerance = 0.3
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// También al tocar un anillo del sistema.
    func refresh() {
        let ticks = IslandSystem.cpuTicks()
        var cpu: Double?
        if let ticks, let lastTicks { cpu = IslandSystem.cpuFraction(from: lastTicks, to: ticks) }
        if ticks != nil { lastTicks = ticks }
        if cpu == nil { cpu = reading?.cpu }
        // Los discos cambian despacio: cada 10 s basta.
        if lastDiskRead.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
            disks = IslandSystem.disks()
            lastDiskRead = Date()
        }
        let memory = IslandSystem.memory()
        let next = IslandSystemReading(cpu: cpu, memoryUsed: memory?.used ?? 0,
                                       memoryTotal: memory?.total ?? 0, disks: disks)
        if next != reading { reading = next }
    }
}
