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
}

public struct Spec {
    public var gpuDieCores = 0, aneCores = 0, slcBytes = 0, memBusBits = 0, memPackages = 0
    public var memType = "", transistors = "", process = ""
    public var memPeakBW = 200e9
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

public func freqTable(_ v: Any?) -> [Int] {
    guard let d = v as? Data else { return [] }
    var out: [Int] = []
    var i = 0
    while i + 8 <= d.count {
        var hz: UInt32 = 0
        for k in 0..<4 { hz |= UInt32(d[d.startIndex + i + k]) << (8 * UInt32(k)) }
        out.append(Int(hz / 1_000_000))
        i += 8
    }
    return out
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
        var pmgr: [String: Any] = [:]
        let pm = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        if pm != 0 { pmgr = IOReg.props(pm); IOObjectRelease(pm) }
        let eF = freqTable(pmgr["voltage-states1-sram"]), pF = freqTable(pmgr["voltage-states5-sram"])
        t.gpuFreqs = freqTable(pmgr["voltage-states9"])
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
        var pIndex = 0
        for cid in Set(raws.map(\.clusterID)).sorted() {
            let members = raws.filter { $0.clusterID == cid }
            let isE = members.first?.type == "E"
            let id = isE ? "eclu" : "pclu\(pIndex)"
            let prefix = isE ? "ECPU0" : "PCPU\(pIndex)"
            let energy = isE ? "EACC" : "PACC\(pIndex)"
            let present = members.compactMap(\.slot).sorted()
            let slots = max((present.last.map { $0 + 1 }) ?? members.count, isE ? 2 : 4)
            var cores: [CoreSlot] = []
            for s in 0..<slots {
                if let m = members.first(where: { $0.slot == s }) {
                    cores.append(CoreSlot(id: "\(id).\(s)", slot: s, logical: m.logical, cpuID: m.cpuID, ioreport: "\(prefix)\(s)0",
                                          energy: "\(energy)_CPU\(s)", fused: false))
                } else {
                    cores.append(CoreSlot(id: "\(id).\(s)", slot: s, logical: nil, cpuID: nil, ioreport: nil, energy: nil, fused: true))
                }
            }
            t.clusters.append(Cluster(
                id: id, label: isE ? "E-cluster (efficiency)" : "P-cluster \(pIndex) (performance)", short: isE ? "E-cluster" : "P-cluster \(pIndex)",
                type: isE ? "E" : "P", ioreport: isE ? "ECPU" : (pIndex == 0 ? "PCPU" : "PCPU\(pIndex)"), energy: energy,
                amc: isE ? "ECPU" : "PCPU\(pIndex)", freqs: isE ? eF : pF,
                l2: Sysctl.int(isE ? "hw.perflevel1.l2cachesize" : "hw.perflevel0.l2cachesize") ?? 0,
                l2DeviceTree: members.first?.l2, cores: cores))
            if !isE { pIndex += 1 }
        }
        // P-clusters first, then E (drawing order).
        t.clusters.sort { ($0.type == "P" ? 0 : 1, $0.id) < ($1.type == "P" ? 0 : 1, $1.id) }
        let gpu = IOReg.firstProps("IOAccelerator")
        t.gpuCores = (gpu["gpu-core-count"] as? NSNumber)?.intValue ?? 0
        IOReg.each("IONVMeController") { s in
            if t.ssdModel.isEmpty, let m = IOReg.prop(s, "Model Number") as? String { t.ssdModel = m.trimmingCharacters(in: .whitespaces) }
        }
        if t.chip.contains("M1 Pro") {
            t.spec = Spec(gpuDieCores: 16, aneCores: 16, slcBytes: 24 << 20, memBusBits: 256, memPackages: 2,
                          memType: "LPDDR5-6400", transistors: "33.7 billion", process: "TSMC 5 nm", memPeakBW: 200e9)
        }
        if t.model == "MacBookPro18,3" {
            t.board = BoardSpec(name: "MacBook Pro 14\u{2033} (2021)", display: "Liquid Retina XDR 14.2\u{2033} · 3024×1964 · 120 Hz",
                                leftPorts: ["MagSafe 3", "Thunderbolt 4", "Thunderbolt 4", "Headphone jack"],
                                rightPorts: ["SDXC card", "HDMI", "Thunderbolt 4"])
        }
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
