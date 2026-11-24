import Foundation
import IOKit

/// Plain-text report of what chipscope reads to learn the machine: sysctl, device-tree CPUs, pmgr
/// frequency tables (raw), the resulting topology and every IOReport channel name. No personal data.
public func diagnosticDump() -> String {
    var out: [String] = []
    func line(_ s: String) { out.append(s) }
    line("== sysctl")
    for k in ["hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.nperflevels", "hw.ncpu", "kern.osproductversion"] {
        line("\(k) = \(Sysctl.string(k).flatMap { $0.isEmpty || $0.unicodeScalars.contains { $0.value < 32 } ? nil : $0 } ?? Sysctl.int(k).map(String.init) ?? "—")")
    }
    for i in 0..<(Sysctl.int("hw.nperflevels") ?? 2) {
        let p = "hw.perflevel\(i)."
        line("\(p)name=\(Sysctl.string(p + "name") ?? "—") physicalcpu=\(Sysctl.int(p + "physicalcpu") ?? -1) l2=\(Sysctl.int(p + "l2cachesize") ?? -1) cpusperl2=\(Sysctl.int(p + "cpusperl2") ?? -1)")
    }
    line("== device tree /cpus")
    let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
    if cpus != 0 {
        for (_, p) in IOReg.children(cpus, plane: "IODeviceTree", depth: 1) {
            let name = p["name"].flatMap(dataString) ?? "?"
            let reg = (p["reg"] as? Data).map { $0.prefix(4).map { String(format: "%02x", $0) }.joined() } ?? "—"
            line("\(name) cpu-id=\(u32(p["cpu-id"]) ?? -1) logical=\(u32(p["logical-cpu-id"]) ?? -1) type=\(dataString(p["cluster-type"]) ?? "?") cluster=\(u32(p["cluster-id"]) ?? -1) reg=\(reg)")
        }
        IOObjectRelease(cpus)
    }
    line("== pmgr voltage-states (first 3 raw values, entries)")
    for (k, v) in pmgrProps().sorted(by: { $0.key < $1.key }) where k.hasPrefix("voltage-states") || k == "acc-clusters" {
        guard let d = v as? Data else { continue }
        var raw: [UInt32] = []
        var i = 0
        while i + 8 <= d.count, raw.count < 3 { raw.append(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self) }); i += 8 }
        line("\(k): \(d.count / 8) entries, first \(raw)")
    }
    let t = TopologyReader.read()
    line("== topology as chipscope sees it")
    line("chip=\(t.chip) model=\(t.model) gpuCores=\(t.gpuCores) gpuFreqs=\(t.gpuFreqs) spec.known=\(t.spec.process.isEmpty ? "no" : "yes")")
    for c in t.clusters {
        line("\(c.id) \(c.type) ioreport=\(c.ioreport) energy=\(c.energy) amc=\(c.amc) freqs=\(c.freqs) cores=" +
             c.cores.map { $0.fused ? "\($0.slot):fused" : "\($0.slot):\($0.ioreport ?? "?")" }.joined(separator: ","))
    }
    line("== IOReport channels")
    let r = IOReportReader()
    guard r.ok else { line("IOReport unavailable"); return out.joined(separator: "\n") }
    Thread.sleep(forTimeInterval: 0.3)
    let ch = r.channels()
    line("\(ch.count) channels")
    for c in ch {
        line("[\(c.group) / \(c.subgroup)] \(c.name) \(c.unit)" + (c.states.isEmpty ? "" : " states=\(c.states.joined(separator: ","))"))
    }
    return out.joined(separator: "\n")
}

/// Properties of the power manager node that holds the DVFS tables ("pmgr"; "pmgr-child" on newer chips).
func pmgrProps() -> [String: Any] {
    for name in ["pmgr", "pmgr-child"] {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(name))
        guard s != 0 else { continue }
        let p = IOReg.props(s)
        IOObjectRelease(s)
        if p.keys.contains(where: { $0.hasPrefix("voltage-states") }) { return p }
    }
    return [:]
}
