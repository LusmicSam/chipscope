import Foundation
import IOKit

public struct CoreSlot: Identifiable, Hashable {
    public var id: String
    public var slot: Int
    public var logical: Int?
    public var cpuID: Int?
    public var ioreport: String?
    public var energy: String?
    public var fused: Bool
    public init(id: String, slot: Int, logical: Int?, cpuID: Int?, ioreport: String?, energy: String?, fused: Bool) {
        self.id = id; self.slot = slot; self.logical = logical; self.cpuID = cpuID; self.ioreport = ioreport; self.energy = energy; self.fused = fused
    }
}

public struct Cluster: Identifiable, Hashable {
    public var id: String          // eclu, pclu0, pclu1
    public var label: String
    public var short: String
    public var type: String        // "E" or "P"
    public var ioreport: String    // ECPU, PCPU, PCPU1
    public var energy: String      // EACC, PACC0, PACC1
    public var amc: String         // AMC agent name
    public var freqs: [Int]
    public var l2: Int
    public var l2DeviceTree: Int?
    public var cores: [CoreSlot]
    public init(id: String, label: String, short: String, type: String, ioreport: String, energy: String, amc: String,
                freqs: [Int], l2: Int, l2DeviceTree: Int?, cores: [CoreSlot]) {
        self.id = id; self.label = label; self.short = short; self.type = type; self.ioreport = ioreport; self.energy = energy
        self.amc = amc; self.freqs = freqs; self.l2 = l2; self.l2DeviceTree = l2DeviceTree; self.cores = cores
    }
}

public struct Spec {
    public var gpuDieCores = 0, aneCores = 0, slcBytes = 0, memBusBits = 0, memPackages = 0
    public var memType = "", transistors = "", process = ""
    public var memPeakBW = 0.0
    /// Core slots per cluster on the die (incl. fused-off ones), when known from die analysis; else 0.
    public var pSlots = 0, eSlots = 0
    public var known: Bool { !process.isEmpty }
    /// Scale for memory heat: Apple's peak, or a generous default when the chip is unknown.
    public var memScaleBW: Double { memPeakBW > 0 ? memPeakBW : 200e9 }
}

public struct BoardSpec {
    public var name = ""
    public var display = ""
    public var leftPorts: [String] = []
    public var rightPorts: [String] = []
}

public struct Topology {
    public var model = "", chip = "Apple Silicon"
    public var memoryBytes = 0
    public var clusters: [Cluster] = []
    public var caches: [String: Int] = [:]
    public var gpuCores = 0
    public var gpuFreqs: [Int] = []
    public var ssdModel = ""
    public var spec = Spec()
    public var board = BoardSpec()
    public var wifi = ""
    public var wifiLink = ""
    public init() {}

    public func cluster(_ id: String) -> Cluster? { clusters.first { $0.id == id } }
    public func core(_ id: String) -> (Cluster, CoreSlot)? {
        for c in clusters { if let k = c.cores.first(where: { $0.id == id }) { return (c, k) } }
        return nil
    }
    public func coreName(logical: Int) -> String {
        for c in clusters { for k in c.cores where !k.fused && k.logical == logical {
            return c.type == "P" ? "P\(c.id.last!).\(k.slot)" : "E\(k.slot)"
        } }
        return "cpu\(logical)"
    }
    public var liveCores: [(Cluster, CoreSlot)] { clusters.flatMap { c in c.cores.filter { !$0.fused }.map { (c, $0) } } }
}

/// pmgr DVFS table -> MHz. Entries are (frequency, voltage) u32 pairs. M1-M3 store Hz, M4+ store kHz
/// (macmon); the unit is told apart by size, so a future chip with either unit still reads right.
public func freqTable(_ v: Any?) -> [Int] {
    guard let d = v as? Data else { return [] }
    var raw: [UInt32] = []
    var i = 0
    while i + 8 <= d.count {
        var f: UInt32 = 0
        for k in 0..<4 { f |= UInt32(d[d.startIndex + i + k]) << (8 * UInt32(k)) }
        raw.append(f)
        i += 8
    }
    // 10 MHz in Hz = 1e7; 10 GHz in kHz = 1e7. Real tables top out between 0.4 and 4.6 GHz.
    let div: UInt32 = (raw.max() ?? 0) >= 10_000_000 ? 1_000_000 : 1_000
    return raw.map { Int($0 / div) }
}

/// pmgr key of the E and P CPU tables: voltage-states1/5-sram on M1-M4, else from acc-clusters
/// (8-byte entries: byte 0 = table index, byte 1 = tier; lowest tier = E, highest = P).
func cpuFreqKeys(_ pmgr: [String: Any]) -> (e: String, p: String) {
    if pmgr["voltage-states1-sram"] != nil && pmgr["voltage-states5-sram"] != nil { return ("voltage-states1-sram", "voltage-states5-sram") }
    guard let d = pmgr["acc-clusters"] as? Data, d.count >= 16 else { return ("voltage-states1-sram", "voltage-states5-sram") }
    var cl: [(tier: UInt8, key: String)] = []
    var i = 0
    while i + 8 <= d.count { cl.append((d[d.startIndex + i + 1], "voltage-states\(d[d.startIndex + i])-sram")); i += 8 }
    cl.sort { $0.tier < $1.tier }
    return (cl.first!.key, cl.last!.key)
}

public enum TopologyReader {
    public static func read() -> Topology {
        var t = Topology()
        t.model = Sysctl.string("hw.model") ?? ""
        t.chip = Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon"
        t.memoryBytes = Sysctl.int("hw.memsize") ?? 0
        for k in ["perflevel0.l1dcachesize", "perflevel0.l1icachesize", "perflevel0.l2cachesize", "perflevel1.l1dcachesize",
                  "perflevel1.l1icachesize", "perflevel1.l2cachesize", "cachelinesize", "pagesize"] {
            t.caches[k] = Sysctl.int("hw." + k)
        }
        // Frequency tables from the power manager's device-tree node.
        let pmgr = pmgrProps()
        let keys = cpuFreqKeys(pmgr)
        let eF = freqTable(pmgr[keys.e]), pF = freqTable(pmgr[keys.p])
        t.gpuFreqs = freqTable(pmgr["voltage-states9"])
        t.spec = chipSpec(t.chip, gpuCores: (IOReg.firstProps("IOAccelerator", keys: ["gpu-core-count"])["gpu-core-count"] as? NSNumber)?.intValue ?? 0)
        // CPU cores from the device tree; missing slots are fused-off cores.
        struct Raw { var cpuID: Int; var logical: Int; var type: String; var clusterID: Int; var slot: Int?; var l2: Int? }
        var raws: [Raw] = []
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            for (_, p) in IOReg.children(cpus, plane: "IODeviceTree", depth: 1) {
                guard let name = p["name"].flatMap(dataString) ?? (p["IORegistryEntryName"] as? String), name.hasPrefix("cpu") else { continue }
                let reg = p["reg"] as? Data
                raws.append(Raw(cpuID: u32(p["cpu-id"]) ?? 0, logical: (p["logical-cpu-id"] as? NSNumber)?.intValue ?? u32(p["logical-cpu-id"]) ?? -1,
                                type: dataString(p["cluster-type"]) ?? "?", clusterID: u32(p["cluster-id"]) ?? 0,
                                slot: reg.flatMap { $0.count >= 4 ? Int($0[$0.startIndex]) : nil }, l2: u32(p["l2-cache-size"])))
            }
            IOObjectRelease(cpus)
        }
        // Slots per cluster: from die analysis when known, else the widest cluster of that type.
        func widest(_ type: String) -> Int {
            Set(raws.filter { ($0.type == "E") == (type == "E") }.map(\.clusterID)).map { cid in
                let m = raws.filter { $0.clusterID == cid }
                return (m.compactMap(\.slot).max().map { $0 + 1 }) ?? m.count
            }.max() ?? 0
        }
        let slotsE = max(widest("E"), t.spec.eSlots), slotsP = max(widest("P"), t.spec.pSlots)
        var pIndex = 0, eIndex = 0
        for cid in Set(raws.map(\.clusterID)).sorted() {
            let members = raws.filter { $0.clusterID == cid }
            let isE = members.first?.type == "E"
            let n = isE ? eIndex : pIndex
            // Names below are the M1 Pro scheme; bindChannels() replaces them with what IOReport really has.
            let id = isE ? (n == 0 ? "eclu" : "eclu\(n)") : "pclu\(n)"
            let prefix = isE ? "ECPU\(n)" : "PCPU\(n)"
            let energy = isE ? (n == 0 ? "EACC" : "EACC\(n)") : "PACC\(n)"
            let slots = max(members.count, isE ? slotsE : slotsP)
            var cores: [CoreSlot] = []
            for s in 0..<slots {
                if let m = members.first(where: { $0.slot == s }) {
                    cores.append(CoreSlot(id: "\(id).\(s)", slot: s, logical: m.logical, cpuID: m.cpuID, ioreport: "\(prefix)\(s)0",
                                          energy: "\(energy)_CPU\(s)", fused: false))
                } else {
                    cores.append(CoreSlot(id: "\(id).\(s)", slot: s, logical: nil, cpuID: nil, ioreport: nil, energy: nil, fused: true))
                }
            }
            let eLevel = max(0, (Sysctl.int("hw.nperflevels") ?? 2) - 1)
            t.clusters.append(Cluster(
                id: id, label: isE ? "E-cluster\(n > 0 ? " \(n)" : "") (efficiency)" : "P-cluster \(n) (performance)",
                short: isE ? "E-cluster\(n > 0 ? " \(n)" : "")" : "P-cluster \(n)",
                type: isE ? "E" : "P", ioreport: isE ? (n == 0 ? "ECPU" : "ECPU\(n)") : (n == 0 ? "PCPU" : "PCPU\(n)"), energy: energy,
                amc: isE ? (n == 0 ? "ECPU" : "ECPU\(n)") : "PCPU\(n)", freqs: isE ? eF : pF,
                l2: Sysctl.int(isE ? "hw.perflevel\(eLevel).l2cachesize" : "hw.perflevel0.l2cachesize") ?? 0,
                l2DeviceTree: members.first?.l2, cores: cores))
            if isE { eIndex += 1 } else { pIndex += 1 }
        }
        // P-clusters first, then E (drawing order).
        t.clusters.sort { ($0.type == "P" ? 0 : 1, $0.id) < ($1.type == "P" ? 0 : 1, $1.id) }
        let gpu = IOReg.firstProps("IOAccelerator")
        t.gpuCores = (gpu["gpu-core-count"] as? NSNumber)?.intValue ?? 0
        IOReg.each("IONVMeController") { s in
            if t.ssdModel.isEmpty, let m = IOReg.prop(s, "Model Number") as? String { t.ssdModel = m.trimmingCharacters(in: .whitespaces) }
        }
        let ior = IOReportReader()
        if ior.ok { bindChannels(&t, ior.channels().map { ($0.subgroup.isEmpty ? $0.group : $0.subgroup, $0.name) }) }
        t.board = readBoard(model: t.model)
        return t
    }

    /// Wi-Fi chip from system_profiler (slow: call off the main thread).
    public static func wifi() -> (card: String, link: String) {
        let out = shell("/usr/sbin/system_profiler", ["-json", "SPAirPortDataType"], timeout: 20)
        guard let d = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let a = (d["SPAirPortDataType"] as? [[String: Any]])?.first,
              let ifs = a["spairport_airport_interfaces"] as? [[String: Any]] else { return ("", "") }
        for i in ifs {
            guard let card = i["spairport_wireless_card_type"] as? String else { continue }
            var name = card
            if let r = card.range(of: #"\((0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+)\)"#, options: .regularExpression) {
                let ids = card[r].dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if ids.count == 2, ids[0].uppercased() == "0X14E4" { name = "Broadcom BCM\(ids[1].dropFirst(2).uppercased())" }
            }
            let net = i["spairport_current_network_information"] as? [String: Any]
            let link = [net?["spairport_network_phymode"] as? String, (net?["spairport_network_channel"] as? String).map { "ch \($0)" }]
                .compactMap { $0 }.joined(separator: " · ")
            return (name, link)
        }
        return ("", "")
    }
}
