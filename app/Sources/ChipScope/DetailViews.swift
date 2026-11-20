import ChipCore
import Charts
import SwiftUI

let HIST = 240   // 60 s at 4/s

struct Page<Content: View>: View {
    var title: String
    var lead: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 22, weight: .bold))
                if let lead { Text(lead).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(maxWidth: 980, alignment: .leading) }
                content()
            }
            .padding(18)
        }
    }
}

let grid2 = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

// ------------------------------------------------------------------ cluster
struct ClusterView: View {
    var id: String
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        if let c = hub.topo.cluster(id), let f = hub.current(ui) {
            Page(title: c.label, lead: EXPLAIN[c.type == "P" ? "pclu" : "eclu"]) {
                HStack(spacing: 14) {
                    ForEach(c.cores) { k in
                        if k.fused {
                            GhostBlock(rect: CGRect(x: 0, y: 0, width: 220, height: 230), lines: ["slot \(k.slot): fused off", "disabled at the factory"]).frame(width: 220, height: 230)
                        } else {
                            CoreTile(cluster: c, core: k, s: f.chip.cores[k.id]).onTapGesture { ui.go(.core(k.id)) }
                        }
                    }
                }
                let l2 = f.chip.bw[c.amc] ?? BW()
                SiliconBlock(rect: CGRect(x: 0, y: 0, width: CGFloat(c.cores.count) * 234 - 14, height: 60), title: "L2 cache · \(Fmt.bytes(c.l2)) shared",
                             lines: ["\(Fmt.bps(l2.total)) to the fabric (read \(Fmt.bps(l2.rd)), write \(Fmt.bps(l2.wr)))"], heat: lin(l2.total, 100e9))
                    .frame(width: CGFloat(c.cores.count) * 234 - 14, height: 60)
                if let dt = c.l2DeviceTree, dt != c.l2 {
                    Text("L2 size: sysctl says \(Fmt.bytes(c.l2)), the device tree says \(Fmt.bytes(dt)); sysctl matches public M1 Pro analysis.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                LazyVGrid(columns: grid2, spacing: 14) {
                    ForEach(c.cores.filter { !$0.fused }) { k in
                        Card(title: "\(c.type)-core \(k.slot) busy") {
                            HistoryChart(series: [Series(name: "Busy", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.cores[k.id]?.busy })], yMax: 1, format: { Fmt.pct($0) })
                        }
                    }
                    Card(title: "Cluster clock", note: "Average frequency while the cluster is active.") {
                        HistoryChart(series: [Series(name: "Clock", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.clusters[id]?.mhz })],
                                     yMax: Double(c.freqs.max() ?? 1), format: { $0 > 0 ? Fmt.mhz($0) : "0" })
                    }
                    Card(title: "Cluster power", note: "Apple energy model: cores + shared logic.") {
                        HistoryChart(series: [Series(name: "Power", color: Theme.ink2, values: hub.window(HIST, ui).map { fr in fr.chip.clusters[id].map { $0.wCores + $0.wShared } })], format: { Fmt.w($0) })
                    }
                }
            }
        }
    }
}

struct CoreTile: View {
    var cluster: Cluster
    var core: CoreSlot
    var s: CoreSample?
    @Environment(UIState.self) private var ui
    var body: some View {
        let h = ui.coreHeat(s, type: cluster.type, freqs: cluster.freqs)
        ZStack(alignment: .topLeading) {
            SiliconBlock(rect: CGRect(x: 0, y: 0, width: 220, height: 230), heat: h, radius: 10).frame(width: 220, height: 230)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(cluster.type)-core \(core.slot) · cpu\(core.logical ?? -1)").font(.system(size: 13, weight: .semibold))
                Text(Fmt.pct(s?.busy)).font(.system(size: 40, weight: .bold)).monospacedDigit()
                Text("\(Fmt.mhz(s?.mhz)) while busy").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.8))
                Text("\(Fmt.w(s?.w)) (model)").font(.system(size: 12)).foregroundStyle(Theme.ink.opacity(0.8))
                Spacer()
                StateBars(states: s?.states ?? [], freqs: cluster.freqs, height: 56, labels: false)
            }
            .padding(14)
        }
        .frame(width: 220, height: 230)
        .contentShape(Rectangle())
        .tip(core.id) { SoCView().coreTip(cluster, core, s) }
    }
}

/// Time in each DVFS state. CPU "V<i>P<j>" is clock step i; GPU "P<i>" is step i-1 (states with no time are absent).
struct StateBars: View {
    var states: [(String, Double)]
    var freqs: [Int]
    var height: CGFloat = 110
    var labels = true
    var body: some View {
        let active = freqs.filter { $0 > 0 }
        let steps = active.count
        let byStep: [Int: Double] = states.reduce(into: [:]) { acc, s in if let k = step(s.0) { acc[k, default: 0] += s.1 } }
        let idle = states.filter { IDLE_STATES.contains($0.0) }.map(\.1).reduce(0, +)
        let mx = max(0.01, (Array(byStep.values) + [idle]).max() ?? 0.01)
        HStack(alignment: .bottom, spacing: 2) {
            bar(idle / mx, "idle", Theme.axis, idle)
            ForEach(0..<max(0, steps), id: \.self) { k in
                let v = byStep[k] ?? 0
                bar(v / mx, String(format: "%.1f", Double(active[k]) / 1000), heatColor(Double(active[k]) / Double(active.max() ?? 1)), v, mhz: active[k])
            }
        }
        .frame(height: height)
    }
    private func step(_ n: String) -> Int? {
        if n.hasPrefix("V"), let p = n.firstIndex(of: "P"), let i = Int(n[n.index(after: n.startIndex)..<p]) { return i }
        if n.hasPrefix("P"), let i = Int(n.dropFirst()) { return i - 1 }
        return nil
    }
    private func bar(_ x: Double, _ label: String, _ color: Color, _ share: Double, mhz: Int? = nil) -> some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2).fill(color).frame(height: max(1, (height - (labels ? 16 : 2)) * x))
            if labels { Text(label).font(.system(size: 9)).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: 34)
        .tip("state.\(label)") { Tip(value: Fmt.pct(share), label: mhz.map { "at \(Fmt.mhz(Double($0)))" } ?? "idle (asleep)", source: "IOReport state residency") }
    }
}

// ------------------------------------------------------------------ core
struct CoreView: View {
    var id: String
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        if let (c, k) = hub.topo.core(id), !k.fused, let f = hub.current(ui) {
            let s = f.chip.cores[id]
            Page(title: "\(c.type)-core \(k.slot) · \(c.label) · logical CPU \(k.logical ?? -1)", lead: EXPLAIN["core"]) {
                HStack(spacing: 30) {
                    Stat(value: Fmt.pct(s?.busy), label: "busy")
                    Stat(value: Fmt.mhz(s?.mhz), label: "clock while busy (max \(Fmt.mhz(Double(c.freqs.max() ?? 0))))")
                    Stat(value: Fmt.w(s?.w), label: "power (Apple model)")
                    Stat(value: Fmt.bytes(c.type == "P" ? hub.topo.caches["perflevel0.l1dcachesize"] : hub.topo.caches["perflevel1.l1dcachesize"]), label: "L1 data cache")
                }
                LazyVGrid(columns: grid2, spacing: 14) {
                    Card(title: "Busy, last 60 s") { HistoryChart(series: [Series(name: "Busy", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.cores[id]?.busy })], yMax: 1, format: { Fmt.pct($0) }) }
                    Card(title: "Clock while busy, last 60 s") {
                        HistoryChart(series: [Series(name: "Clock", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.cores[id]?.mhz })], yMax: Double(c.freqs.max() ?? 1), format: { $0 > 0 ? Fmt.mhz($0) : "0" })
                    }
                    Card(title: "Power, last 60 s", note: "Apple energy model estimate.") { HistoryChart(series: [Series(name: "W", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.cores[id]?.w })], format: { Fmt.w($0) }) }
                    Card(title: "Time in each clock state (now)", note: "Each bar is one voltage/frequency step from the power manager's table.") { StateBars(states: s?.states ?? [], freqs: c.freqs) }
                    Card(title: "Memory hierarchy seen from a \(c.type)-core", note: "Pointer-chase latency vs working-set size (Signal timing probes). macOS can't pin a thread to one core, so this is a core of this type.") {
                        MemlatChart(series: hub.probes.map { [("\(c.type)-core", Theme.ink2, c.type == "P" ? $0.memlatP : $0.memlatE)] } ?? [], refs: refs(c))
                    }
                    Card(title: "Signal time from cpu\(k.logical ?? -1) to the other cores", note: "One-way cache-line transfer.") { c2cRow(k.logical ?? -1) }
                }
            }
        }
    }
    private func refs(_ c: Cluster) -> [(Double, String)] {
        let pre = c.type == "P" ? "perflevel0" : "perflevel1"
        return [(Double(hub.topo.caches["\(pre).l1dcachesize"] ?? 0), "L1"), (Double(c.l2), "L2"), (Double(hub.topo.spec.slcBytes), "SLC")]
    }
    @ViewBuilder private func c2cRow(_ me: Int) -> some View {
        if let p = hub.probes {
            let m = c2cMatrix(p.c2c)
            KV(rows: hub.topo.liveCores.compactMap { _, k in
                guard let l = k.logical, l != me else { return nil }
                let v = m["\(min(me, l))-\(max(me, l))"]
                return ("cpu\(l) (\(hub.topo.coreName(logical: l)))", v.map { "\(Fmt.ns($0.0)) · \($0.1) runs" } ?? "not observed")
            })
        } else { Text("Run the Signal timing probes first.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
    }
}

// ------------------------------------------------------------------ GPU
struct GPUView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        if let f = hub.current(ui) {
            let t = hub.topo, g = f.chip.gpu
            let die = max(t.spec.gpuDieCores, t.gpuCores)
            Page(title: "GPU · \(t.gpuCores) of \(die) cores enabled", lead: EXPLAIN["gpu"]) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 10), count: 8), alignment: .leading, spacing: 10) {
                    ForEach(0..<die, id: \.self) { i in
                        if i < t.gpuCores {
                            SiliconBlock(rect: CGRect(x: 0, y: 0, width: 118, height: 92), title: "core \(i)", heat: ui.gpuHeat(g, freqs: t.gpuFreqs), titleSize: 11).frame(width: 118, height: 92)
                        } else {
                            GhostBlock(rect: CGRect(x: 0, y: 0, width: 118, height: 92), lines: ["fused off", "(position unknown)"]).frame(width: 118, height: 92)
                        }
                    }
                }
                HStack(spacing: 30) {
                    Stat(value: Fmt.pct(g.util ?? g.busy), label: "utilised"); Stat(value: Fmt.mhz(g.mhz), label: "clock"); Stat(value: Fmt.w(g.w), label: "power (model)")
                    Stat(value: Fmt.bytes(g.memUsed), label: "memory in use"); Stat(value: "\(g.renderer ?? 0)% / \(g.tiler ?? 0)%", label: "renderer / tiler")
                }
                LazyVGrid(columns: grid2, spacing: 14) {
                    Card(title: "Utilisation, last 60 s") { HistoryChart(series: [Series(name: "Util", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.gpu.util })], yMax: 1, format: { Fmt.pct($0) }) }
                    Card(title: "Clock, last 60 s", note: "P1–P6 carry the 6 clocks (a 100% load sits in P6, measured). Empty while the GPU is off.") {
                        HistoryChart(series: [Series(name: "Clock", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.gpu.mhz })], yMax: Double(t.gpuFreqs.max() ?? 1), format: { $0 > 0 ? Fmt.mhz($0) : "0" })
                    }
                    Card(title: "Power, last 60 s") { HistoryChart(series: [Series(name: "W", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.gpu.w })], format: { Fmt.w($0) }) }
                    Card(title: "Time in each power state (now)") { StateBars(states: g.states, freqs: t.gpuFreqs) }
                }
            }
        }
    }
}

// ------------------------------------------------------------------ memory
struct MemoryView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        if let f = hub.current(ui) {
            let m = f.board.vm, t = hub.topo
            Page(title: "Unified memory · \(Fmt.bytes(t.memoryBytes)) \(t.spec.memType)", lead: EXPLAIN["dram"]) {
                LazyVGrid(columns: grid2, spacing: 14) {
                    Card(title: "What the memory holds", note: "\"Apps\" = anonymous memory. \"Cached files\" can be dropped at any time. \"Compressed\" = squeezed by the compressor to avoid swapping.") {
                        let parts: [(String, Int, Color)] = [("Wired (kernel)", m.wired, Theme.series[0]), ("Apps", m.app, Theme.series[1]), ("Compressed", m.compressed, Theme.series[2]),
                                                             ("Cached files", m.fileBacked, Theme.series[3]), ("Free", m.free, Theme.axis)]
                        GeometryReader { geo in
                            HStack(spacing: 2) {
                                ForEach(parts, id: \.0) { n, v, c in
                                    RoundedRectangle(cornerRadius: 3).fill(c).frame(width: max(0, geo.size.width * CGFloat(v) / CGFloat(max(1, m.total)) - 2))
                                        .tip("mem.\(n)") { Tip(value: Fmt.bytes(v), label: n, rows: [("Share", Fmt.pct(Double(v) / Double(max(1, m.total))))], source: "host_statistics64") }
                                }
                            }
                        }.frame(height: 30)
                        HStack(spacing: 12) { ForEach(parts, id: \.0) { n, v, c in HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text("\(n) \(Fmt.bytes(v))") } } }
                            .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                    }
                    Card(title: "Pressure and swap") {
                        let lvl: (String, Color) = m.pressure >= 4 ? ("Critical", Theme.critical) : m.pressure >= 2 ? ("Warning", Theme.warning) : ("Normal", Theme.good)
                        HStack(spacing: 6) { Circle().fill(lvl.1).frame(width: 10, height: 10); Text("Memory pressure: \(lvl.0)").font(.system(size: 14, weight: .semibold)) }
                        KV(rows: [("Swap used", "\(Fmt.bytes(m.swapUsed)) of \(Fmt.bytes(m.swapTotal))"), ("Kernel free-memory level", "\(m.freePercent)%"),
                                  ("Pages swapped in / out since boot", "\(big(m.swapins)) / \(big(m.swapouts))")])
                    }
                    Card(title: "Who moves data through the memory system", note: "Each agent's traffic at the memory controller. Darker share reached DRAM; the rest hit the 24 MB system cache.") { agentBars(f) }
                    Card(title: "DRAM traffic, last 60 s", note: "Peak \(Fmt.bps(t.spec.memPeakBW)) (Apple spec).") {
                        HistoryChart(series: [Series(name: "Read", color: Theme.read, values: hub.window(HIST, ui).map { $0.chip.mem.dramRd }),
                                              Series(name: "Write", color: Theme.write, values: hub.window(HIST, ui).map { $0.chip.mem.dramWr })], format: { Fmt.bps($0) })
                        HStack(spacing: 14) { LegendLine(color: Theme.read, label: "Read"); LegendLine(color: Theme.write, label: "Write") }
                    }
                    Card(title: "Served by the system cache, last 60 s", note: "Derived: 1 − DRAM ÷ all agent traffic; empty under 50 MB/s.") {
                        HistoryChart(series: [Series(name: "On-chip", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.mem.slcHit })], yMax: 1, format: { Fmt.pct($0) })
                    }
                    Card(title: "DRAM power, last 60 s") { HistoryChart(series: [Series(name: "W", color: Theme.ink2, values: hub.window(HIST, ui).map { $0.chip.mem.dramW })], format: { Fmt.w($0) }) }
                }
            }
        }
    }
    private func big(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000) k" : "\(n)" }
    private func agentBars(_ f: Frame) -> some View {
        let rows = f.chip.bw.filter { $0.value.total > 1e5 }.sorted { $0.value.total > $1.value.total }
        let mx = rows.first?.value.total ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(rows, id: \.key) { a, v in
                HStack(spacing: 8) {
                    Text(AGENT_BY_ID[a]?.label ?? a).font(.system(size: 11)).foregroundStyle(Theme.ink2).frame(width: 150, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x5598E7)).frame(width: max(1, geo.size.width * v.total / mx))
                            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x184F95)).frame(width: max(0, geo.size.width * min(v.total, v.dcsRd + v.dcsWr) / mx))
                        }
                    }.frame(height: 14)
                    Text(Fmt.bps(v.total)).font(.system(size: 11)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                .tip("agent.\(a)") { Tip(value: Fmt.bps(v.total), label: AGENT_BY_ID[a]?.label ?? a, rows: [("Read", Fmt.bps(v.rd)), ("Write", Fmt.bps(v.wr)), ("Reached DRAM", Fmt.bps(v.dcsRd + v.dcsWr))], source: "IOReport AMC Stats \(a)") }
            }
        }
    }
}

// ------------------------------------------------------------------ ports & power
struct PortsView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        if let f = hub.current(ui) {
            let b = f.board.battery
            Page(title: "Ports & power", lead: "Live state of every port: what is plugged in (identified over USB Power Delivery), whether it carries data, and which way power flows. The charger's contract comes from the battery controller.") {
                HStack(spacing: 30) {
                    Stat(value: Fmt.w(b.sysInW), label: "adapter in"); Stat(value: Fmt.w(b.sysLoadW), label: "system load")
                    Stat(value: b.battW.map { ($0 >= 0 ? "+" : "") + Fmt.w($0) } ?? "—", label: "battery"); Stat(value: "\(b.percent ?? 0)%", label: b.charging ? "charging" : "charge")
                }
                LazyVGrid(columns: grid2, spacing: 14) {
                    ForEach(f.board.ports) { p in
                        Card(title: p.type == "USB-C" ? "USB-C port \(p.number)" : p.type) {
                            HStack(spacing: 8) {
                                Circle().fill(!p.connected ? Theme.axis : p.sink ? Theme.good : Theme.warning).frame(width: 10, height: 10)
                                Text(!p.connected ? "nothing connected" : p.sink ? "charger → charging the Mac" : "device connected").font(.system(size: 14, weight: .semibold))
                            }
                            if p.connected {
                                KV(rows: [("Device", [p.vendor, p.productID.map { "product \($0)" }].compactMap { $0 }.joined(separator: " · ")), ("Cable", p.cable ?? "—"),
                                          ("Data", p.usbData ? (p.superSpeed ? "USB SuperSpeed" : "USB") : "none (power only)"), ("Power", p.direction ?? "—"),
                                          ("Plug orientation", p.orientation == 1 ? "normal" : p.orientation == 2 ? "flipped" : "—")])
                                if let c = p.charger {
                                    SectionTitle(text: "Charger · \(c.ratedW) W \(c.kind)")
                                    HStack(spacing: 6) {
                                        ForEach(c.menu, id: \.self) { m in
                                            VStack(spacing: 1) { Text("\(Int(m.volts)) V").font(.system(size: 13, weight: .semibold)); Text("\(String(format: "%.1f", m.amps)) A · \(Int(m.watts)) W").font(.system(size: 10)) }
                                                .padding(6).frame(maxWidth: .infinity)
                                                .background(RoundedRectangle(cornerRadius: 6).fill(m == c.chosen ? Theme.good.opacity(0.25) : Theme.surface2))
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(m == c.chosen ? Theme.good : Theme.hair))
                                        }
                                    }
                                    Text("Highlighted = the contract in use.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                }
                            }
                            Text("Plugged in \(p.connections)× since boot").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Text("Power going out to a device the Mac is charging: no per-port counter found yet (still to check with a phone plugged straight into the Mac). USB-C port numbers are macOS's own; which physical socket is which is not exposed.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).frame(maxWidth: 980, alignment: .leading)
            }
        }
    }
}

// ------------------------------------------------------------------ inspector
struct InspectorView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        ScrollView {
            if let f = hub.current(ui) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(hub.topo.board.name.isEmpty ? hub.topo.model : hub.topo.board.name).font(.system(size: 15, weight: .semibold))
                    Text("\(hub.topo.chip) · \(Fmt.bytes(hub.topo.memoryBytes)) · \(hub.topo.ssdModel)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    if let sel = ui.selection, let e = EXPLAIN[sel] {
                        SectionTitle(text: "Selected")
                        Text(e).font(.system(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    SectionTitle(text: "Power (Apple energy model)")
                    KV(rows: [("CPU", Fmt.w(f.chip.cpuW)), ("GPU", Fmt.w(f.chip.gpu.w)), ("Neural Engine", Fmt.w(f.chip.aneW)), ("DRAM", Fmt.w(f.chip.mem.dramW)),
                              ("Cache + memory controllers", Fmt.w(f.chip.mem.amccW + f.chip.mem.dcsW)), ("Whole Mac (battery controller)", Fmt.w(f.board.battery.sysLoadW))])
                    SectionTitle(text: "Thermal")
                    KV(rows: [("Die sensors (max)", Fmt.temp(f.board.socMax)), ("NAND", Fmt.temp(f.board.ssdTemp)), ("Battery", Fmt.temp(f.board.batteryTemp))]
                         + f.board.fans.enumerated().map { ("Fan \($0.offset + 1)", "\(Int($0.element.rpm)) rpm") })
                    SectionTitle(text: "Memory")
                    KV(rows: [("Apps", Fmt.bytes(f.board.vm.app)), ("Compressed", Fmt.bytes(f.board.vm.compressed)), ("Swap", Fmt.bytes(f.board.vm.swapUsed)),
                              ("Pressure", ["—", "normal", "warning", "—", "critical"][min(4, max(0, f.board.vm.pressure))])])
                    SectionTitle(text: "Who is using memory bandwidth")
                    KV(rows: f.chip.bw.filter { $0.value.total > 1e5 }.sorted { $0.value.total > $1.value.total }.prefix(7).map { (AGENT_BY_ID[$0.key]?.label ?? $0.key, Fmt.bps($0.value.total)) })
                    SectionTitle(text: "Top processes (CPU)")
                    ForEach(f.board.procs.sorted { $0.cpu > $1.cpu }.prefix(10)) { p in
                        HStack { Text(p.name).lineLimit(1); Spacer(); Text(String(format: "%.0f%%", p.cpu)).monospacedDigit(); Text(Fmt.bytes(p.rss)).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 64, alignment: .trailing) }
                            .font(.system(size: 12))
                    }
                    Text("ps %CPU (100% = one core) · load \(f.board.load.map { String(format: "%.2f", $0) }.joined(separator: " / ")) · chipscope itself: \(String(format: "%.1f", f.board.selfCPU))% of a core")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted).padding(.top, 4)
                }
                .padding(14)
            }
        }
        .background(Theme.surface)
    }
}
