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
    let ps = BoardReader.parsePS("  42     1  15.0  2048 13:05:58 shivam /x/.venv/bin/python\n   7     1   0.0   100 02-09:21:39 root /sbin/launchd\n")
    check(ps.count == 2 && ps[0].age == 13 * 3600 + 5 * 60 + 58 && ps[1].age == 2 * 86400 + 9 * 3600 + 21 * 60 + 39, "ps rows + elapsed time")
    let f = Optimizer.analyze(ps, vm: VMInfo(), me: "shivam", selfPID: 999)
    check(f.first?.id == "orphans", "orphaned .venv python is flagged")
}
do {
    let t = Topology()
    var r = ProbeResults()
    r.memlatP = [(Double(32 << 10), 1.0, 2), (Double(1 << 20), 5.5, 2), (Double(16 << 20), 60, 2), (Double(256 << 20), 125, 2)]
    let a = atlas(t, r, passive: [:], diskLifeUs: nil)
    check(a.map { $0.id } == ["p_l1", "p_l2", "slc", "dram"] && a.map { $0.ns } == [1, 5.5, 60, 125], "memory bands follow cache sizes")
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
