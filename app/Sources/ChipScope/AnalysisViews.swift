import AppKit
import ChipCore
import Charts
import SwiftUI

// ------------------------------------------------------------------ memory-latency curve (log–log)
struct MemlatChart: View {
    var series: [(String, Color, [(size: Double, ns: Double, cpu: Int)])]
    var refs: [(Double, String)]
    var body: some View {
        if series.allSatisfy({ $0.2.isEmpty }) {
            Text("No probe results yet: open Signal timing and run the probes.").font(.system(size: 12)).foregroundStyle(Theme.muted)
        } else {
            Chart {
                ForEach(refs.filter { $0.0 > 0 }, id: \.1) { b, n in
                    RuleMark(x: .value("size", b)).foregroundStyle(Theme.muted.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading) { Text("\(n) \(Fmt.bytes(Int(b)))").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                }
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    ForEach(Array(s.2.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("size", p.size), y: .value("ns", p.ns), series: .value("s", s.0)).foregroundStyle(s.1)
                        PointMark(x: .value("size", p.size), y: .value("ns", p.ns)).foregroundStyle(s.1).symbolSize(16)
                    }
                }
            }
            .chartXScale(type: .log)
            .chartYScale(type: .log)
            .chartXAxis { AxisMarks(values: [4096.0, 65536.0, 1048576.0, 16777216.0, 268435456.0]) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.bytes(Int(d))) } } } }
            .chartYAxis { AxisMarks(position: .leading, values: [1.0, 10, 100, 1000]) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.ns(d)) } } } }
            .frame(height: 210)
            if series.count > 1 { HStack(spacing: 14) { ForEach(series, id: \.0) { LegendLine(color: $0.1, label: $0.0) } } }
        }
    }
}

// ------------------------------------------------------------------ signal timing
let GROUP_ANGLE: [String: Double] = ["accel": 0, "storage": 40, "sensors": 85, "network": 125, "cache": 190, "memory": 232, "cores": 268, "os": 315]
let GROUP_NAME: [String: String] = ["cache": "Caches", "cores": "Other cores", "memory": "Memory", "os": "OS / kernel", "accel": "GPU + Neural Engine",
                                    "storage": "Storage", "sensors": "Sensors", "network": "Network"]

struct AtlasView: View {
    @Environment(Hub.self) private var hub
    var body: some View {
        let entries = hub.atlasEntries
        Page(title: "Signal timing: how far away each part is, measured in time",
             lead: "Every component answers at a different speed. A value in L1 cache arrives in about a nanosecond, DRAM takes about a hundred, the SSD a hundred thousand. Timing those answers maps the machine: the cache sizes, the two P-clusters and the sensor buses all show up below, with no spec sheet.") {
            HStack(spacing: 12) {
                Button(hub.probeStep == nil ? "Run probes (~30 s)" : "Running…") { hub.runProbes() }.buttonStyle(.borderedProminent).disabled(hub.probeStep != nil)
                Text(status).font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            Card(title: "Signal distance from a CPU core", note: "Rings are powers of ten in time. Each dot is a measured round trip; the whisker is its p10–p90 spread. Hover a label for how it was measured.") {
                Radial(entries: entries).frame(height: 620)
            }
            LazyVGrid(columns: grid2, alignment: .leading, spacing: 14) {
                Card(title: "All timings, fastest first") { ladder(entries) }
                Card(title: "Core-to-core signal time (one way)", note: "Two threads bounce one cache line. Same-cluster pairs share an L2; cross-cluster pairs go through the fabric. Hatched = never observed (macOS decides where threads run).") { matrix }
                Card(title: "Memory hierarchy: latency vs working-set size", note: "Each step up is the next level: L1 → L2 → system cache → DRAM. On P-cores the L2 step shows before the documented 12 MB; the cause is not verified here.") {
                    MemlatChart(series: [("P-core", Theme.series[0], hub.probes?.memlatP ?? hub.probeLiveP), ("E-core", Theme.series[1], hub.probes?.memlatE ?? hub.probeLiveE)],
                                refs: [(Double(hub.topo.caches["perflevel0.l1dcachesize"] ?? 0), "P L1"), (Double(hub.topo.caches["perflevel0.l2cachesize"] ?? 0), "P L2"), (Double(hub.topo.spec.slcBytes), "SLC")])
                }
            }
        }
    }

    private var status: String {
        if let s = hub.probeStep { return "Running: \(s)…" }
        if let p = hub.probes { return "Last run \(p.date.formatted(date: .omitted, time: .shortened)) · load average then \(p.load.first.map { String(format: "%.1f", $0) } ?? "—") · busy machines give slower, noisier numbers" }
        return "Probes not run yet: only passive timings (SSD driver average, sensor reads) are shown."
    }

    private func ladder(_ e: [AtlasEntry]) -> some View {
        VStack(spacing: 4) {
            ForEach(e) { x in
                HStack(spacing: 8) {
                    Text(x.label).font(.system(size: 12)).lineLimit(1).frame(width: 190, alignment: .leading)
                    Text(Fmt.ns(x.ns)).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.read).frame(width: max(2, 110 * log10(max(1, x.ns)) / 8), height: 7)
                    Text(x.how).font(.system(size: 10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private var matrix: some View {
        let t = hub.topo
        let cores = t.liveCores.compactMap { $0.1.logical }.sorted()
        let m = hub.probes.map { c2cMatrix($0.c2c) } ?? [:]
        let vals = m.values.map(\.0)
        let lo = vals.min() ?? 1, hi = vals.max() ?? 1
        if m.isEmpty { Text("Run the probes to fill this in.").font(.system(size: 12)).foregroundStyle(Theme.muted) } else {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("")
                    ForEach(cores, id: \.self) { Text(t.coreName(logical: $0)).font(.system(size: 10)).foregroundStyle(Theme.muted) }
                }
                ForEach(cores, id: \.self) { a in
                    GridRow {
                        Text(t.coreName(logical: a)).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        ForEach(cores, id: \.self) { b in
                            let v = m["\(min(a, b))-\(max(a, b))"]
                            ZStack {
                                if a == b { RoundedRectangle(cornerRadius: 3).fill(Theme.surface2) }
                                else if let v {
                                    let x = hi > lo ? (log(v.0) - log(lo)) / (log(hi) - log(lo)) : 0.5
                                    RoundedRectangle(cornerRadius: 3).fill(blueRamp(x))
                                    Text("\(Int(v.0))").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(x < 0.45 ? .black : Theme.ink)
                                } else {
                                    GhostBlock(rect: CGRect(x: 0, y: 0, width: 40, height: 34), lines: [])
                                }
                            }
                            .frame(width: 40, height: 34)
                            .tip("c2c.\(a).\(b)") { Tip(value: v.map { Fmt.ns($0.0) } ?? (a == b ? "same core" : "not observed"), label: "\(t.coreName(logical: a)) ↔ \(t.coreName(logical: b)) (one way)", rows: v.map { [("Runs kept", "\($0.1)")] } ?? [], source: "cache-line ping-pong") }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("fast \(Fmt.ns(lo))"); ForEach(0..<8, id: \.self) { RoundedRectangle(cornerRadius: 2).fill(blueRamp(Double($0) / 7)).frame(width: 18, height: 10) }; Text("slow \(Fmt.ns(hi)) · cells in ns")
            }.font(.system(size: 10.5)).foregroundStyle(Theme.ink2)
        }
    }
}

/// Sequential blue (dataviz palette): light = fast, dark = slow on the dark surface.
func blueRamp(_ x: Double) -> Color {
    let steps: [UInt32] = [0xCDE2FB, 0x9EC5F4, 0x6DA7EC, 0x3987E5, 0x256ABF, 0x184F95, 0x104281, 0x0D366B]
    return Color(hex: steps[min(7, max(0, Int(x * 8)))])
}

struct Radial: View {
    var entries: [AtlasEntry]
    @Environment(UIState.self) private var ui
    var body: some View {
        DesignCanvas(size: CGSize(width: 1020, height: 820)) {
            let C = CGPoint(x: 510, y: 410), r0: CGFloat = 62, r1: CGFloat = 274
            let R: (Double) -> CGFloat = { ns in r0 + (r1 - r0) * CGFloat(log10(max(1, ns)) / 8) }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in 0...8 {
                        let r = R(pow(10, Double(e)))
                        ctx.stroke(Path(ellipseIn: CGRect(x: C.x - r, y: C.y - r, width: 2 * r, height: 2 * r)), with: .color(Theme.grid))
                        let a = 147 * Double.pi / 180
                        ctx.draw(Text(Fmt.ns(pow(10, Double(e)))).font(.system(size: 11)).foregroundColor(Theme.muted), at: CGPoint(x: C.x + r * cos(a), y: C.y + r * sin(a)))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: C.x - 18, y: C.y - 18, width: 36, height: 36)), with: .color(heatColor(0.7)))
                    ctx.draw(Text("core").font(.system(size: 11, weight: .semibold)).foregroundColor(.white), at: C)
                    let groups = Dictionary(grouping: entries, by: \.group)
                    for (g, list) in groups {
                        let ga = (GROUP_ANGLE[g] ?? 0) * Double.pi / 180
                        for (i, e) in list.enumerated() {
                            let a = ga + (Double(i) - Double(list.count - 1) / 2) * 14 * Double.pi / 180
                            let p = CGPoint(x: C.x + R(e.ns) * cos(a), y: C.y + R(e.ns) * sin(a))
                            if let s = e.spread {
                                ctx.stroke(line(CGPoint(x: C.x + R(s.0) * cos(a), y: C.y + R(s.0) * sin(a)), CGPoint(x: C.x + R(s.1) * cos(a), y: C.y + R(s.1) * sin(a))), with: .color(Color(hex: 0x6D6C66)), lineWidth: 2)
                            }
                            let lp = labelPoint(g, i, list.count, C, r1)
                            ctx.stroke(line(p, CGPoint(x: lp.x, y: lp.y - 4)), with: .color(Theme.axis), lineWidth: 1)
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.read))
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(Theme.surface), lineWidth: 2)
                        }
                    }
                }
                ForEach(Array(Dictionary(grouping: entries, by: \.group)), id: \.key) { g, list in
                    let ga = (GROUP_ANGLE[g] ?? 0) * Double.pi / 180
                    let hp = labelPoint(g, -1, list.count, C, r1)
                    Text(GROUP_NAME[g] ?? g).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .fixedSize().position(anchorPos(hp, ga))
                    ForEach(Array(list.enumerated()), id: \.offset) { i, e in
                        let lp = labelPoint(g, i, list.count, C, r1)
                        Text("\(e.label)  \(Fmt.ns(e.ns))").font(.system(size: 11.5)).foregroundStyle(Theme.ink2).fixedSize()
                            .position(anchorPos(lp, ga))
                            .tip("atlas.\(e.id)") { Tip(value: Fmt.ns(e.ns), label: e.label, rows: [("Method", e.how), ("Spread (p10–p90)", e.spread.map { "\(Fmt.ns($0.0)) – \(Fmt.ns($0.1))" } ?? "—")]) }
                    }
                }
            }
        }
    }

    /// Stacked label slots outside the rings: index -1 is the group header.
    private func labelPoint(_ g: String, _ i: Int, _ n: Int, _ C: CGPoint, _ r1: CGFloat) -> CGPoint {
        let ga = (GROUP_ANGLE[g] ?? 0) * Double.pi / 180
        let P = CGPoint(x: C.x + (r1 + 24) * cos(ga), y: C.y + (r1 + 24) * sin(ga))
        let k = CGFloat(i + 1), total = CGFloat(n + 1), lh: CGFloat = 16
        if abs(cos(ga)) < 0.35 { return sin(ga) < 0 ? CGPoint(x: P.x, y: P.y - (total - 1 - k) * lh) : CGPoint(x: P.x, y: P.y + 10 + k * lh) }
        return CGPoint(x: P.x + (cos(ga) > 0 ? 8 : -8), y: P.y + (k - (total - 1) / 2) * lh)
    }
    /// SwiftUI positions by centre; shift so text starts/ends at the slot like a leading/trailing anchor.
    private func anchorPos(_ p: CGPoint, _ ga: Double) -> CGPoint {
        if abs(cos(ga)) < 0.35 { return p }
        return CGPoint(x: p.x + (cos(ga) > 0 ? 110 : -110), y: p.y)
    }
}

// ------------------------------------------------------------------ optimize
struct OptimizeView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui
    var body: some View {
        Page(title: "Optimize", lead: "Things on this Mac that cost memory or CPU for no good reason, found from live process and memory data. Nothing is stopped without asking you first. RAM speed itself is fixed (soldered LPDDR5, no overclocking): the gain is keeping work out of compression and swap, which are 1,000× slower than RAM.") {
            if hub.findings.isEmpty {
                Card(title: "Nothing to fix right now") {
                    Text("No orphaned dev processes, no runaway CPU, memory pressure is normal.").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
            ForEach(hub.findings) { f in
                Card(title: f.title) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: f.severity == .high ? "exclamationmark.octagon.fill" : f.severity == .warn ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(f.severity == .high ? Theme.critical : f.severity == .warn ? Theme.warning : Theme.read).font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(f.detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 16) {
                                if f.memory > 0 { Text("holds \(Fmt.bytes(f.memory))").font(.system(size: 12, weight: .medium)) }
                                if f.cpu > 0 { Text(String(format: "%.0f%% of a core", f.cpu)).font(.system(size: 12, weight: .medium)) }
                            }
                        }
                        Spacer()
                        if case .kill(let pids) = f.action, let label = f.actionLabel {
                            Button(label) { confirmAndKill(pids, f.title) }.buttonStyle(.borderedProminent).tint(Theme.critical)
                        }
                    }
                }
            }
            if let f = hub.latest {
                Card(title: "Memory by app (helpers grouped)") {
                    let g = Dictionary(grouping: f.board.procs, by: Optimizer.appGroup).map { ($0.key, $0.value.reduce(0) { $0 + $1.rss }, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(12)
                    let mx = g.first?.1 ?? 1
                    VStack(spacing: 5) {
                        ForEach(Array(g), id: \.0) { name, mem, n in
                            HStack(spacing: 8) {
                                Text(name).font(.system(size: 12)).lineLimit(1).frame(width: 200, alignment: .leading)
                                GeometryReader { geo in RoundedRectangle(cornerRadius: 3).fill(Theme.series[1]).frame(width: max(2, geo.size.width * CGFloat(mem) / CGFloat(mx))) }.frame(height: 12)
                                Text("\(Fmt.bytes(mem)) · \(n)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 110, alignment: .trailing)
                            }
                        }
                    }
                    Text("Resident memory from ps (shared pages counted per process, so totals run a little high).").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func confirmAndKill(_ pids: [Int], _ what: String) {
        let a = NSAlert()
        a.messageText = "Stop \(pids.count) process\(pids.count == 1 ? "" : "es")?"
        a.informativeText = "\(what)\nPIDs: \(pids.map(String.init).joined(separator: ", ")). They get a normal quit signal (SIGTERM)."
        a.addButton(withTitle: "Stop"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for p in pids { kill(pid_t(p), SIGTERM) }
    }
}

// ------------------------------------------------------------------ sensors
struct SensorsView: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared
    var body: some View {
        let q = ui.sensorFilter.lowercased()
        let s = hub.sweep
        Page(title: "Every sensor this Mac exposes", lead: "Read without sudo; the full sweep refreshes every 15 seconds. Read time = how long each sensor took to answer.") {
            TextField("Filter (e.g. nand, Tp0, battery)", text: $ui.sensorFilter).textFieldStyle(.roundedBorder).frame(width: 320)
            LazyVGrid(columns: grid2, alignment: .leading, spacing: 14) {
                Card(title: "Named temperature sensors (HID) · \(s.hid.count)") {
                    Table(s.hid.filter { q.isEmpty || ($0.name + $0.place).lowercased().contains(q) }.map { HIDRow(h: $0) }) {
                        TableColumn("Sensor", value: \.h.name)
                        TableColumn("Place", value: \.h.place).width(60)
                        TableColumn("°C") { Text(String(format: "%.1f", $0.h.c)).monospacedDigit() }.width(50)
                        TableColumn("Read") { Text(String(format: "%.2f ms", $0.h.us / 1000)).monospacedDigit() }.width(70)
                    }.frame(height: 360)
                }
                Card(title: "SMC sensor keys · \(s.smc.count)") {
                    Table(s.smc.filter { q.isEmpty || ($0.key + $0.category + ($0.label ?? "")).lowercased().contains(q) }) {
                        TableColumn("Key", value: \.key).width(52)
                        TableColumn("Kind", value: \.category).width(80)
                        TableColumn("Value") { r in Text(r.value.map { abs($0) < 100 ? String(format: "%.2f", $0) : String(format: "%.0f", $0) } ?? "—").monospacedDigit() }.width(70)
                        TableColumn("Read") { r in Text(String(format: "%.2f ms", r.us / 1000)).monospacedDigit() }.width(70)
                        TableColumn("Label") { r in Text(r.label ?? "") }
                    }.frame(height: 360)
                }
            }
            Card(title: "How fast each sensor family answers") {
                KV(rows: s.latency.sorted { $0.value.0 < $1.value.0 }.map { k, v in
                    ([("smc", "SMC key"), ("hid_pmu", "PMU die sensor"), ("hid_battery", "Battery gas gauge"), ("hid_ssd", "NAND sensor")].first { $0.0 == k }?.1 ?? k,
                     String(format: "%.2f ms · %d sensors", v.0 / 1000, v.1))
                })
            }
        }
    }
}

struct HIDRow: Identifiable { var h: HIDTemp; var id: String { h.name } }

// ------------------------------------------------------------------ self-snapshots (no Screen Recording needed)
//   CHIPSCOPE_SNAPSHOT_DIR=/tmp/shots ChipScope.app/Contents/MacOS/ChipScope
enum Snapshots {
    static func runIfRequested() {
        if let r = ProcessInfo.processInfo.environment["CHIPSCOPE_ROUTE"] {
            let map: [String: Route] = ["mac": .mac, "soc": .soc, "gpu": .gpu, "memory": .memory, "thermal": .thermal, "atlas": .atlas, "ports": .ports, "optimize": .optimize, "sensors": .sensors]
            if let route = map[r] { UIState.shared.go(route) }
        }
        guard let dir = ProcessInfo.processInfo.environment["CHIPSCOPE_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = Hub.shared.topo
        let routes: [(String, Route)] = [("mac", .mac), ("soc", .soc), ("cluster", .cluster(t.clusters.first?.id ?? "pclu0")),
                                         ("core", .core(t.liveCores.first?.1.id ?? "")), ("gpu", .gpu), ("memory", .memory), ("ports", .ports),
                                         ("thermal", .thermal), ("atlas", .atlas), ("optimize", .optimize), ("sensors", .sensors)]
        var delay = 5.0
        for (name, r) in routes {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { UIState.shared.go(r) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.6) { save("\(dir)/\(name).png") }
            delay += 2.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { FileManager.default.createFile(atPath: "\(dir)/done", contents: nil) }
    }
    static func save(_ path: String) {
        // Render the window's whole layer tree (cacheDisplay skips layer-hosting views such as the
        // Core Animation flows and fans).
        guard let w = NSApp.windows.first(where: { $0.frame.width > 800 }), let v = w.contentView else {
            FileHandle.standardError.write("snapshot: no window (\(NSApp.windows.map { "\($0.frame.width) visible=\($0.isVisible)" }))\n".data(using: .utf8)!); return
        }
        if !w.isVisible { w.makeKeyAndOrderFront(nil) }
        guard let layer = v.layer else {
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            return
        }
        let scale = w.backingScaleFactor
        let size = CGSize(width: v.bounds.width * scale, height: v.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
