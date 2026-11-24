// Checks for the parts that turn raw counters into numbers, then a live smoke test.
//   swift run -c release ChipCheck
import ChipCore
import Foundation

// `ChipCheck --collect N`: run only the collector for N seconds and report its CPU cost.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--collect", let n = Double(CommandLine.arguments[2]) {
    let c = Collector(topo: TopologyReader.read())
    var frames = 0
    c.onFrame = { _ in frames += 1 }
    c.start()
    RunLoop.main.run(until: Date().addingTimeInterval(4))   // warm-up (first sweep enumerates every SMC key)
    let cpu = SelfCPU(); frames = 0
    RunLoop.main.run(until: Date().addingTimeInterval(n))
    print(String(format: "collector: %.1f%% of one core over %.0f s, %d frames", cpu.percent(), n, frames))
    exit(0)
}

// `ChipCheck --dump`: everything chipscope reads to learn the machine (send this when a Mac misbehaves).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--dump" {
    print(diagnosticDump())
    exit(0)
}

// `ChipCheck --bench`: CPU time per call of each reader (user + system).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--bench" {
    let topo = TopologyReader.read()
    let ior = IOReportReader(), smc = SMCReader(), hid = HIDTempReader()
    func cpuNow() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
    func bench(_ name: String, _ n: Int, perSec: Double, _ fn: () -> Void) {
        let a = cpuNow(); for _ in 0..<n { fn() }; let ms = (cpuNow() - a) / Double(n) * 1000
        print(name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: " %7.2f ms/call  × %.2f/s = %5.2f%% of a core", ms, perSec, ms * perSec / 10))
    }
    _ = ior.sample(); Thread.sleep(forTimeInterval: 0.25)
    bench("IOReport sample + frame", 40, perSec: 4) { _ = buildChipFrame(topo, ior.sample(), gpu: BoardReader.gpuStats()) }
    bench("  of which GPU stats", 40, perSec: 4) { _ = BoardReader.gpuStats() }
    bench("battery", 20, perSec: 1) { _ = BoardReader.battery() }
    bench("ports (+ PD info)", 20, perSec: 0.5) { _ = PortReader.read() }
    bench("vm + swap", 20, perSec: 1) { _ = BoardReader.vm() }
    bench("net", 20, perSec: 1) { _ = BoardReader.netCounters() }
    bench("disk", 20, perSec: 1) { _ = BoardReader.diskCounters() }
    bench("ps (process list)", 5, perSec: 0.2) { _ = BoardReader.processes() }
    bench("SMC fans + 14 die keys", 10, perSec: 1) { for k in ["FNum", "F0Ac", "F0Mn", "F0Mx", "F1Ac", "F1Mn", "F1Mx"] + Array(COMMUNITY_TEMPS.keys) { _ = smc.read(k) } }
    bench("HID temps (64)", 5, perSec: 1.0 / 15) { _ = hid.read() }
    exit(0)
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

let E = [600, 972, 1332, 1704, 2064], G = [0, 388, 486, 648, 777, 972, 1296]
do {
    let r = residencySummary([("IDLE", 50), ("V0P4", 25), ("V1P3", 0), ("V2P2", 0), ("V3P1", 0), ("V4P0", 25)], E)
    check(near(r.busy, 0.5) && near(r.mhz, (600 + 2064) / 2), "CPU busy + clock from residency")
    let full = residencySummary([("OFF", 0)] + (1...15).map { ("P\($0)", Int64($0 == 6 ? 100 : 0)) }, G)
    check(near(full.mhz, 1296), "GPU: 100% load in P6 = 1296 MHz (measured mapping)")
    let low = residencySummary([("OFF", 50), ("P1", 50)] + (2...15).map { ("P\($0)", Int64(0)) }, G)
    check(near(low.mhz, 388), "GPU: low state maps from the bottom")
    let amb = residencySummary([("OFF", 0)] + (1...15).map { ("P\($0)", Int64(10)) }, G)
    check(amb.mhz == nil, "GPU: ambiguous residency gives no clock")
}
do {
    check(decodePDO(167874860) == PDO(volts: 5, amps: 3, watts: 15), "USB-PD fixed PDO 5 V × 3 A")
    check(decodePDO(33964372)?.watts == 68, "USB-PD fixed PDO 20 V × 3.4 A")
    var ports = [MacPort(id: "USB-C@2", type: "USB-C", number: 2, connected: true, transports: ["CC"], connections: 6)]
    PortReader.attachPD(&ports, pci: [["PortControllerAttachCount": 1], ["PortControllerAttachCount": 6, "PortControllerMaxPower": 90000]],
                        adapter: ["Watts": 90, "UsbHvcHvcIndex": 1, "UsbHvcMenu": [["MaxVoltage": 5000, "MaxCurrent": 3000], ["MaxVoltage": 20000, "MaxCurrent": 4500]]])
    check(ports[0].direction == "into Mac" && ports[0].charger?.chosen?.watts == 90, "charger detected from PD controller, not the Power-In flag")
    var dev = [MacPort(id: "USB-C@1", type: "USB-C", number: 1, connected: true, transports: ["CC"], connections: 3)]
    PortReader.attachPD(&dev, pci: [["PortControllerAttachCount": 3, "PortControllerMaxPower": 0]], adapter: [:])
    check(dev[0].direction == "out to device" && dev[0].charger == nil, "device without a contract is powered by the Mac")
}
do {
    var s: [String: [(Double, Double)]] = [:]
    s["near"] = (0..<40).map { i -> (Double, Double) in let t = Double(i) * 0.5; return (t, t < 10 ? 50 : 50 + min(10, (t - 10) * 5)) }
    s["far"] = (0..<40).map { i -> (Double, Double) in let t = Double(i) * 0.5; return (t, t < 15 ? 40 : 40 + min(3, (t - 15) * 0.5)) }
    s["flat"] = (0..<40).map { (Double($0) * 0.5, 30) }
    let h = analyzeHeat(series: s, names: [:], start: 10, end: 19.5)
    check(h.first?.id == "near" && h[1].id == "far" && h.last?.arrival == nil, "heat path orders sensors by arrival time")
    check(near(h.first?.rise, 10, 0.01) && (h.first?.arrival ?? 99) < 1, "heat rise + arrival for the near sensor")
}
do {
    let ps = BoardReader.parsePS("  42     1  15.0  2048 13:05:58 alice /x/.venv/bin/python\n   7     1   0.0   100 02-09:21:39 root /sbin/launchd\n")
    check(ps.count == 2 && ps[0].age == 13 * 3600 + 5 * 60 + 58 && ps[1].age == 2 * 86400 + 9 * 3600 + 21 * 60 + 39, "ps rows + elapsed time")
    let f = Optimizer.analyze(ps, vm: VMInfo(), me: "alice", selfPID: 999)
    check(f.first?.id == "orphans", "orphaned .venv python is flagged")
}
do {
    let t = Topology()
    var r = ProbeResults()
    r.memlatP = [(Double(32 << 10), 1.0, 2), (Double(1 << 20), 5.5, 2), (Double(16 << 20), 60, 2), (Double(256 << 20), 125, 2)]
    let a = atlas(t, r, passive: [:], diskLifeUs: nil)
    check(a.map { $0.id } == ["p_l1", "p_l2", "slc", "dram"] && a.map { $0.ns } == [1, 5.5, 60, 125], "memory bands follow cache sizes")
}

do {
    // pmgr tables: M1-M3 in Hz, M4+ in kHz (macmon). Both must read as MHz.
    func table(_ v: [UInt32]) -> Data { Data(v.flatMap { f -> [UInt8] in (0..<4).map { UInt8((f >> (8 * $0)) & 0xff) } + [0, 0, 0, 0] }) }
    check(freqTable(table([600_000_000, 3_228_000_000])) == [600, 3228], "pmgr table in Hz (M1-M3)")
    check(freqTable(table([1_020_000, 4_512_000])) == [1020, 4512], "pmgr table in kHz (M4)")
    check(freqTable(table([0, 388_800_000, 1_296_000_000])) == [0, 388, 1296], "GPU table with an OFF entry")
}
do {
    // Fake topologies: clusters of `n` live cores (+ fused slots), as TopologyReader builds them.
    func topo(_ spec: [(String, Int, Int)]) -> Topology {
        var t = Topology()
        var pi = 0, ei = 0
        for (type, live, slots) in spec {
            let n = type == "E" ? ei : pi
            let id = type == "E" ? (n == 0 ? "eclu" : "eclu\(n)") : "pclu\(n)"
            let cores = (0..<slots).map { s in CoreSlot(id: "\(id).\(s)", slot: s, logical: s < live ? s : nil, cpuID: nil, ioreport: s < live ? "x" : nil, energy: nil, fused: s >= live) }
            t.clusters.append(Cluster(id: id, label: id, short: id, type: type, ioreport: "x", energy: "x", amc: "x", freqs: [], l2: 0, l2DeviceTree: nil, cores: cores))
            if type == "E" { ei += 1 } else { pi += 1 }
        }
        return t
    }
    func io(_ t: Topology) -> [String] { t.clusters.flatMap { c in c.cores.filter { !$0.fused }.map { $0.ioreport ?? "-" } } }
    func en(_ t: Topology) -> [String] { t.clusters.flatMap { c in c.cores.filter { !$0.fused }.map { $0.energy ?? "-" } } }
    let core = "CPU Core Performance States", cx = "CPU Complex Performance States", em = "Energy Model"

    // M1 Pro, names copied from `ChipCheck --dump` on this Mac. Must equal the old hard-coded scheme.
    var m1 = topo([("P", 3, 4), ("P", 3, 4), ("E", 2, 2)])
    bindChannels(&m1, ["ECPU000", "ECPU010", "PCPU000", "PCPU010", "PCPU020", "PCPU100", "PCPU110", "PCPU120"].map { (core, $0) }
                      + ["ECPU", "ECPM", "PCPU", "PCPM", "PCPU1", "PCPM1"].map { (cx, $0) }
                      + ["EACC_CPU0", "EACC_CPU1", "PACC0_CPU0", "PACC0_CPU1", "PACC0_CPU2", "PACC0_CPU3", "PACC1_CPU0", "PACC1_CPU1", "PACC1_CPU2", "PACC1_CPU3",
                         "EACC_CPM", "PACC0_CPM", "PACC1_CPM", "EACC_CPU", "PACC0_CPU", "PACC1_CPU", "ECPUDTL00", "PCPU1DTL2e", "CPU Energy"].map { (em, $0) })
    check(io(m1) == ["PCPU000", "PCPU010", "PCPU020", "PCPU100", "PCPU110", "PCPU120", "ECPU000", "ECPU010"], "M1 Pro core channels unchanged")
    check(m1.clusters.map(\.ioreport) == ["PCPU", "PCPU1", "ECPU"] && m1.clusters.map(\.energy) == ["PACC0", "PACC1", "EACC"], "M1 Pro cluster channels unchanged")
    check(en(m1) == ["PACC0_CPU0", "PACC0_CPU1", "PACC0_CPU2", "PACC1_CPU0", "PACC1_CPU1", "PACC1_CPU2", "EACC_CPU0", "EACC_CPU1"], "M1 Pro per-core energy unchanged")

    // M4-style: 4P + 6E, one P-cluster with an un-numbered prefix and single-number core names (10 sorts after 9).
    var m4 = topo([("P", 4, 4), ("E", 6, 6)])
    bindChannels(&m4, (0..<6).map { (core, "ECPU\($0)") } + (0..<4).map { (core, "PCPU\($0)") } + [(cx, "ECPU"), (cx, "PCPU")]
                      + (0..<6).map { (em, "EACC_CPU\($0)") } + (0..<4).map { (em, "PACC_CPU\($0)") })
    check(io(m4) == ["PCPU0", "PCPU1", "PCPU2", "PCPU3", "ECPU0", "ECPU1", "ECPU2", "ECPU3", "ECPU4", "ECPU5"], "M4-style names bound by order")
    check(en(m4).first == "PACC_CPU0" && en(m4).last == "EACC_CPU5" && m4.clusters.map(\.energy) == ["PACC", "EACC"], "M4-style energy prefixes")
    var many = topo([("P", 6, 6), ("P", 6, 6), ("E", 4, 4)])
    bindChannels(&many, (0..<12).map { (core, "PCPU\($0)") } + (0..<4).map { (core, "ECPU\($0)") })
    check(io(many)[9] == "PCPU9" && io(many)[10] == "PCPU10", "natural order past 9 cores")

    // Ultra: "DIE_N_" prefixes.
    var ultra = topo([("P", 4, 4), ("P", 4, 4), ("E", 2, 2), ("P", 4, 4), ("P", 4, 4), ("E", 2, 2)])
    let uc = (0..<2).flatMap { d in (0..<2).flatMap { c in (0..<4).map { (core, "DIE_\(d)_PCPU\(c)_CPU\($0)") } } + (0..<2).map { (core, "DIE_\(d)_ECPU_CPU\($0)") } }
    bindChannels(&ultra, uc + (0..<2).flatMap { d in [(cx, "DIE_\(d)_PCPU"), (cx, "DIE_\(d)_PCPU1"), (cx, "DIE_\(d)_ECPU"), (cx, "DIE_\(d)_PCPM")] })
    check(io(ultra)[0] == "DIE_0_PCPU0_CPU0" && io(ultra)[8] == "DIE_0_ECPU_CPU0" && io(ultra)[17] == "DIE_1_PCPU1_CPU3", "Ultra core channels by die")
    check(ultra.clusters.filter { $0.type == "E" }.map(\.ioreport) == ["DIE_0_ECPU", "DIE_1_ECPU"], "Ultra cluster channels skip CPM")

    // Count mismatch: keep the defaults rather than guess.
    var odd = topo([("P", 4, 4), ("E", 4, 4)])
    bindChannels(&odd, (0..<3).map { (core, "PCPU\($0)") })
    check(io(odd).allSatisfy { $0 == "x" }, "mismatched channel count leaves names alone")
}
do {
    check(chipSpec("Apple M1 Pro", gpuCores: 14).memPeakBW == 200e9 && chipSpec("Apple M1 Pro", gpuCores: 14).pSlots == 4, "M1 Pro spec kept")
    check(chipSpec("Apple M4 Max", gpuCores: 32).memPeakBW == 410e9 && chipSpec("Apple M4 Max", gpuCores: 40).memPeakBW == 546e9, "M4 Max bin picks its bus")
    check(!chipSpec("Apple M9", gpuCores: 10).known && chipSpec("Apple M9", gpuCores: 10).memScaleBW > 0, "unknown chip: no spec, still a heat scale")
}

// ---------------------------------------------------------------- live smoke test
let topo = TopologyReader.read()
check(topo.clusters.count >= 2 && !topo.liveCores.isEmpty, "topology: \(topo.chip), \(topo.liveCores.count) cores, \(topo.clusters.flatMap(\.cores).filter(\.fused).count) fused")
let reader = IOReportReader()
Thread.sleep(forTimeInterval: 0.5)
let f = buildChipFrame(topo, reader.sample(), gpu: BoardReader.gpuStats())
check(f.cores.count == topo.liveCores.count && f.cpuW > 0, "IOReport live: \(f.cores.count) cores, CPU \(String(format: "%.2f", f.cpuW)) W, DRAM \(String(format: "%.1f", f.mem.dram / 1e9)) GB/s")
let afc = f.fabric["AFC"]
check(afc.map { $0.total > 0 && abs($0.members - $0.total) / $0.total < 0.05 } ?? false, "CPU fabric port = sum of its clusters (±5%)")
let ports = PortReader.read()
check(ports.contains { $0.type == "USB-C" }, "ports: " + ports.filter(\.connected).map { "\($0.id) \($0.direction ?? "")" }.joined(separator: ", "))
let smc = SMCReader()
check(smc.read("FNum")?.value != nil, "SMC answers (fans: \(Int(smc.read("FNum")?.value ?? 0)))")
let hid = HIDTempReader()
check(hid.names.count > 10, "HID temperature sensors: \(hid.names.count)")
check(Helper.url != nil || ProcessInfo.processInfo.environment["NO_HELPER"] != nil, "probe helper found next to the binary")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
