import CChip
import Foundation

// ------------------------------------------------------------------ agents (memory-controller clients)
public struct Agent { public let id: String; public let label: String; public let block: String; public let kind: String; public let guessed: Bool }

public let AGENTS: [Agent] = [
    Agent(id: "PCPU0", label: "P-cluster 0", block: "pclu0", kind: "cpu", guessed: false),
    Agent(id: "PCPU1", label: "P-cluster 1", block: "pclu1", kind: "cpu", guessed: false),
    Agent(id: "ECPU", label: "E-cluster", block: "eclu", kind: "cpu", guessed: false),
    Agent(id: "GFX", label: "GPU port A", block: "gpu", kind: "gpu", guessed: false),
    Agent(id: "GFX1", label: "GPU port B", block: "gpu", kind: "gpu", guessed: false),
    Agent(id: "ANE0", label: "Neural Engine", block: "ane", kind: "ane", guessed: false),
    Agent(id: "ANS", label: "SSD controller", block: "ans", kind: "io", guessed: false),
    Agent(id: "PCIE LN", label: "PCIe (Wi-Fi, SD card)", block: "pcie", kind: "io", guessed: false),
    Agent(id: "ATC0", label: "USB-C / Thunderbolt 0", block: "atc", kind: "io", guessed: false),
    Agent(id: "ATC1", label: "USB-C / Thunderbolt 1", block: "atc", kind: "io", guessed: false),
    Agent(id: "ATC2", label: "USB-C / Thunderbolt 2", block: "atc", kind: "io", guessed: false),
    Agent(id: "ATC3", label: "USB-C / Thunderbolt 3", block: "atc", kind: "io", guessed: true),
    Agent(id: "DISP", label: "Built-in display engine", block: "disp", kind: "display", guessed: false),
    Agent(id: "EXT DISP0", label: "External display 0", block: "disp", kind: "display", guessed: false),
    Agent(id: "EXT DISP1", label: "External display 1", block: "disp", kind: "display", guessed: false),
    Agent(id: "ISP", label: "Camera image processor", block: "isp", kind: "media", guessed: false),
    Agent(id: "VDEC", label: "Video decoder", block: "media", kind: "media", guessed: false),
    Agent(id: "VENC0", label: "Video encoder", block: "media", kind: "media", guessed: false),
    Agent(id: "STRM CODEC", label: "Stream codec", block: "media", kind: "media", guessed: true),
    Agent(id: "JPG0", label: "JPEG codec 0", block: "media", kind: "media", guessed: false),
    Agent(id: "JPG1", label: "JPEG codec 1", block: "media", kind: "media", guessed: false),
    Agent(id: "MSR0", label: "Scaler / rotator", block: "media", kind: "media", guessed: true),
]
public let AGENT_BY_ID = Dictionary(uniqueKeysWithValues: AGENTS.map { ($0.id, $0) })

public struct FabricPort { public let id: String; public let label: String; public let members: [String] }
public let FABRIC: [FabricPort] = [
    FabricPort(id: "AFC", label: "CPU fabric (coherent)", members: ["PCPU0", "PCPU1", "ECPU"]),
    FabricPort(id: "AFR_A", label: "GPU fabric A", members: ["GFX"]),
    FabricPort(id: "AFR_B", label: "GPU fabric B", members: ["GFX1"]),
    FabricPort(id: "AF_I", label: "I/O + media fabric", members: AGENTS.filter { ["io", "display", "media", "ane"].contains($0.kind) }.map(\.id)),
]

// ------------------------------------------------------------------ raw IOReport delta
public struct RawSample {
    public var dt = 0.25
    public var amc: [String: Double] = [:]       // bytes/s
    public var energy: [String: Double] = [:]    // watts
    public var coreStates: [String: [(String, Int64)]] = [:]
    public var clusterStates: [String: [(String, Int64)]] = [:]
    public var gpuStates: [(String, Int64)] = []
    public var pcie: [String: Double] = [:]
    public init() {}
}

public final class IOReportReader {
    private let buf = UnsafeMutablePointer<cc_item>.allocate(capacity: 640)
    public let ok: Bool
    public init() { ok = cc_ior_open() == 0 }

    private static func str<T>(_ t: T) -> String {
        withUnsafeBytes(of: t) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
    }

    public func sample() -> RawSample {
        var r = RawSample()
        guard ok else { return r }
        var dt = 0.25
        let n = Int(cc_ior_sample(buf, 640, &dt))
        r.dt = dt
        for i in 0..<max(0, n) {
            let it = buf[i]
            let group = Self.str(it.group), name = Self.str(it.name)
            if it.format == 1 {
                let unit = Self.str(it.unit)
                let v = Double(it.value)
                switch group {
                case "AMC Stats": if unit == "B" { r.amc[name] = v / dt }
                case "Energy Model":
                    if name.contains("DTL") { continue }
                    let s: Double? = unit == "mJ" ? 1e-3 : unit == "uJ" ? 1e-6 : unit == "nJ" ? 1e-9 : nil
                    if let s { r.energy[name] = v * s / dt }
                case "Bandwidth": r.pcie[name] = v * (unit == "MiB" ? 1_048_576 : unit == "KiB" ? 1024 : 1) / dt
                default: break
                }
            } else if it.format == 2 {
                let sub = Self.str(it.subgroup)
                var states: [(String, Int64)] = []
                withUnsafeBytes(of: it.snames) { names in
                    withUnsafeBytes(of: it.sres) { res in
                        let rp = res.bindMemory(to: Int64.self)
                        for s in 0..<Int(it.nstates) {
                            let p = names.baseAddress!.advanced(by: s * 16).assumingMemoryBound(to: CChar.self)
                            states.append((String(cString: p), rp[s]))
                        }
                    }
                }
                if sub == "CPU Core Performance States" { r.coreStates[name] = states }
                else if sub == "CPU Complex Performance States" { r.clusterStates[name] = states }
                else if sub == "GPU Performance States" && name == "GPUPH" { r.gpuStates = states }
            }
        }
        return r
    }
}

// ------------------------------------------------------------------ residency -> busy + clock
public let IDLE_STATES: Set<String> = ["IDLE", "OFF", "DOWN"]

/// (busy fraction, average MHz while active, share per state). Clock is nil when the state list
/// cannot be mapped onto the frequency table without guessing.
public func residencySummary(_ states: [(String, Int64)], _ freqsMHz: [Int]) -> (busy: Double, mhz: Double?, share: [(String, Double)]) {
    let total = Double(states.reduce(0) { $0 + $1.1 })
    guard total > 0 else { return (0, nil, []) }
    let active = states.filter { !IDLE_STATES.contains($0.0) }
    let actTotal = Double(active.reduce(0) { $0 + $1.1 })
    let busy = actTotal / total
    var mhz: Double? = nil
    let freqs = freqsMHz.filter { $0 > 0 }.map(Double.init)
    if !active.isEmpty, actTotal > 0, !freqs.isEmpty {
        func weighted(_ s: ArraySlice<(String, Int64)>) -> Double {
            let t = Double(s.reduce(0) { $0 + $1.1 })
            return zip(s, freqs).reduce(0) { $0 + Double($1.0.1) * $1.1 } / max(t, 1)
        }
        if active.count == freqs.count {
            mhz = weighted(active[...])
        } else if active.count > freqs.count {
            // M1 Pro GPU: P1..P15 vs 6 clocks. A 100% load sits in P6 (measured), so P1..P6 carry the
            // clocks. Map whichever end holds the time; if both ends do, report no clock.
            let n = freqs.count
            let rest = Double(active[n...].reduce(0) { $0 + $1.1 }), low = Double(active[..<(active.count - n)].reduce(0) { $0 + $1.1 })
            if rest <= 0.01 * actTotal { mhz = weighted(active[..<n]) }
            else if low <= 0.01 * actTotal { mhz = weighted(active[(active.count - n)...]) }
        }
    }
    return (busy, mhz, states.map { ($0.0, Double($0.1) / total) })
}

// ------------------------------------------------------------------ chip frame
public struct CoreSample { public var busy = 0.0; public var mhz: Double?; public var w = 0.0; public var states: [(String, Double)] = [] }
public struct ClusterSample { public var busy = 0.0, active = 0.0; public var mhz: Double?; public var wCores = 0.0, wShared = 0.0 }
public struct GPUSample {
    public var busy = 0.0; public var mhz: Double?; public var w = 0.0, wSram = 0.0
    public var util: Double?; public var renderer: Int?; public var tiler: Int?; public var memUsed: Int?
    public var states: [(String, Double)] = []
}
public struct MemSample {
    public var dramW = 0.0, amccW = 0.0, dcsW = 0.0
    public var dramRd = 0.0, dramWr = 0.0, agentsTotal = 0.0
    public var slcHit: Double?
    public var dram: Double { dramRd + dramWr }
}
/// Read, write, read-that-reached-DRAM, write-that-reached-DRAM (bytes/s).
public struct BW {
    public var rd = 0.0, wr = 0.0, dcsRd = 0.0, dcsWr = 0.0
    public var total: Double { rd + wr }
    public init(rd: Double = 0, wr: Double = 0, dcsRd: Double = 0, dcsWr: Double = 0) { self.rd = rd; self.wr = wr; self.dcsRd = dcsRd; self.dcsWr = dcsWr }
}
public struct FabricSample {
    public var rd = 0.0, wr = 0.0, members = 0.0
    public var total: Double { rd + wr }
    public init(rd: Double = 0, wr: Double = 0, members: Double = 0) { self.rd = rd; self.wr = wr; self.members = members }
}

public struct ChipFrame {
    public var cores: [String: CoreSample] = [:]
    public var clusters: [String: ClusterSample] = [:]
    public var gpu = GPUSample()
    public var cpuW = 0.0, aneW = 0.0, aveW = 0.0, ispW = 0.0, msrW = 0.0, pcieW = 0.0
    public var mem = MemSample()
    public var bw: [String: BW] = [:]
    public var fabric: [String: FabricSample] = [:]
    public init() {}
    public func agentBW(_ id: String) -> Double { bw[id]?.total ?? 0 }
    public func agentsBW(_ ids: [String]) -> Double { ids.reduce(0) { $0 + agentBW($1) } }
    public var socW: Double { cpuW + gpu.w + aneW }
}

public func buildChipFrame(_ t: Topology, _ raw: RawSample, gpu: [String: Any]) -> ChipFrame {
    var f = ChipFrame()
    let e = raw.energy
    for cl in t.clusters {
        var busyL: [Double] = []
        for c in cl.cores where !c.fused {
            let (busy, mhz, share) = residencySummary(raw.coreStates[c.ioreport ?? ""] ?? [], cl.freqs)
            busyL.append(busy)
            f.cores[c.id] = CoreSample(busy: busy, mhz: mhz, w: e[c.energy ?? ""] ?? 0, states: share.filter { $0.1 > 0.0005 })
        }
        let (cb, cm, _) = residencySummary(raw.clusterStates[cl.ioreport] ?? [], cl.freqs)
        f.clusters[cl.id] = ClusterSample(busy: busyL.isEmpty ? 0 : busyL.reduce(0, +) / Double(busyL.count), active: cb, mhz: cm,
                                          wCores: e["\(cl.energy)_CPU"] ?? 0, wShared: e["\(cl.energy)_CPM"] ?? 0)
    }
    let (gb, gm, gs) = residencySummary(raw.gpuStates, t.gpuFreqs)
    let perf = gpu
    f.gpu = GPUSample(busy: gb, mhz: gm, w: e["GPU Energy"] ?? e["GPU0"] ?? 0, wSram: e["GPU SRAM0"] ?? 0,
                      util: (perf["Device Utilization %"] as? NSNumber).map { $0.doubleValue / 100 },
                      renderer: (perf["Renderer Utilization %"] as? NSNumber)?.intValue, tiler: (perf["Tiler Utilization %"] as? NSNumber)?.intValue,
                      memUsed: (perf["In use system memory"] as? NSNumber)?.intValue, states: gs.filter { $0.1 > 0.0005 })
    f.cpuW = e["CPU Energy"] ?? 0
    f.aneW = e["ANE0"] ?? 0
    f.aveW = e["AVE0"] ?? 0; f.ispW = e["ISP0"] ?? 0; f.msrW = e["MSR0"] ?? 0
    f.pcieW = e.filter { $0.key.contains("PCIe") || $0.key.contains("apciec") }.values.reduce(0, +)
    let amc = raw.amc
    for a in AGENTS {
        guard amc["\(a.id) RD"] != nil || amc["\(a.id) WR"] != nil else { continue }
        f.bw[a.id] = BW(rd: amc["\(a.id) RD"] ?? 0, wr: amc["\(a.id) WR"] ?? 0, dcsRd: amc["\(a.id) DCS RD"] ?? 0, dcsWr: amc["\(a.id) DCS WR"] ?? 0)
    }
    for p in FABRIC {
        guard let rd = amc["\(p.id) RD"] else { continue }
        f.fabric[p.id] = FabricSample(rd: rd, wr: amc["\(p.id) WR"] ?? 0, members: f.agentsBW(p.members))
    }
    let agentsTotal = f.bw.values.reduce(0) { $0 + $1.total }
    let dRd = amc["DCS RD"] ?? 0, dWr = amc["DCS WR"] ?? 0
    f.mem = MemSample(dramW: e["DRAM0"] ?? 0, amccW: e["AMCC0"] ?? 0, dcsW: e["DCS0"] ?? 0, dramRd: dRd, dramWr: dWr, agentsTotal: agentsTotal,
                      slcHit: agentsTotal > 50e6 ? max(0, min(1, 1 - (dRd + dWr) / agentsTotal)) : nil)
    return f
}
