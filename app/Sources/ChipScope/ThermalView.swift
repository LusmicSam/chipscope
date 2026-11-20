import ChipCore
import Charts
import SwiftUI

/// Heat paths: every temperature sensor live, plus a measured experiment that heats one block and
/// times when the heat reaches each sensor. Arrival order = the physical heat path.
struct ThermalView: View {
    @Environment(Hub.self) private var hub
    @Bindable private var ui = UIState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        Card(title: "Where the heat is now", note: "Pipe and fins are tinted from the hottest die sensor. Families placed by name only are marked (community).") { liveMap.aspectRatio(1180.0 / 820.0, contentMode: .fit) }
                        families
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 14) { experimentCard; resultsCard }.frame(maxWidth: .infinity)
                }
            }
            .padding(18)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heat paths").font(.system(size: 22, weight: .bold))
            Text("Apple publishes no map of its \(hub.sweep.smc.filter { $0.category == "temperature" }.count) SMC temperature keys. Instead of guessing from key names, heat a known block and time when each sensor warms up: sensors on the die react within a second, the package and spreader in a few seconds, the heat pipe and fins after that, the far side of the board last. That arrival order is the heat path, measured.")
                .font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(maxWidth: 980, alignment: .leading)
        }
    }

    // ------------------------------------------------------------ live board
    private var liveMap: some View {
        DesignCanvas(size: CGSize(width: 1180, height: 820)) {
            if let f = hub.current(ui) {
                ZStack(alignment: .topLeading) {
                    MacBody(f: f, topo: hub.topo, temps: nil)
                    sensorDot(CGPoint(x: 600, y: 300), "SoC die", f.board.socMax, "max of \(hub.sweep.hid.filter { $0.place == "soc" }.count) PMU die sensors")
                    sensorDot(CGPoint(x: 415, y: 300), "NAND", f.board.ssdTemp, "HID \"NAND CH0 temp\"")
                    sensorDot(CGPoint(x: 590, y: 610), "Battery", f.board.batteryTemp, "HID gas gauge sensors")
                    ForEach(0..<min(2, f.board.fans.count), id: \.self) { i in
                        FanView(center: CGPoint(x: i == 0 ? 170 : 1010, y: 210), radius: 78, rpm: f.board.fans[i].rpm, heat: 0)
                    }
                    if ui.cursor == nil, hub.heat.done || hub.heat.running { pathOverlay }
                }
            }
        }
    }

    private func sensorDot(_ p: CGPoint, _ label: String, _ c: Double?, _ src: String) -> some View {
        VStack(spacing: 3) {
            Circle().fill(tempColor(c)).frame(width: 30, height: 30).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)).shadow(color: tempColor(c), radius: 8)
            Text("\(label) \(Fmt.temp(c))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.black.opacity(0.6)))
        }
        .position(p)
        .tip("t.\(label)") { Tip(value: Fmt.temp(c), label: label, source: src) }
    }

    /// Animated heat flow along the pipe once a run has data.
    private var pathOverlay: some View {
        let r = hub.heat.results.filter { $0.arrival != nil }
        let maxRise = r.map(\.rise).max() ?? 1
        var p = Path(); p.move(to: CGPoint(x: 600, y: 230)); p.addCurve(to: CGPoint(x: 270, y: 150), control1: CGPoint(x: 500, y: 140), control2: CGPoint(x: 380, y: 150))
        var q = Path(); q.move(to: CGPoint(x: 640, y: 230)); q.addCurve(to: CGPoint(x: 910, y: 110), control1: CGPoint(x: 720, y: 130), control2: CGPoint(x: 820, y: 110))
        let strength = min(1, maxRise / 15) * 40e9
        return FlowLayer(flows: [Flow(path: p, rd: 0, wr: strength, offset: .zero, color: (Theme.power, Color(hex: 0xFF7B3A))),
                                 Flow(path: q, rd: 0, wr: strength, offset: .zero, color: (Theme.power, Color(hex: 0xFF7B3A)))])
    }

    // ------------------------------------------------------------ sensor families (live)
    private var families: some View {
        let temps = hub.sweep.smc.filter { $0.category == "temperature" }
        let groups = Dictionary(grouping: temps) { String($0.key.prefix(2)) }.map { k, v in (k, v.compactMap(\.value)) }.sorted { ($0.1.max() ?? 0) > ($1.1.max() ?? 0) }
        return Card(title: "Every SMC temperature, by key family", note: "Bar = range of the family's sensors; colour = its hottest one. Hover for names. Refreshes every 15 s.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(groups, id: \.0) { fam, vals in
                    let mx = vals.max() ?? 0, mn = vals.min() ?? 0
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(tempColor(mx)).frame(width: 8, height: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(fam)…  \(vals.count)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text(String(format: "%.0f–%.0f °C", mn, mx)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2))
                    .tip("fam.\(fam)") { Tip(value: String(format: "%.1f °C max", mx), label: "SMC keys \(fam)… (\(vals.count))", rows: [("Hint", SMC_FAMILY_HINT[fam] ?? "no public name")],
                                             explain: "Names come from reverse-engineering notes, not Apple. Run a heat-path experiment to see where these sensors really sit.", source: "SMC") }
                }
            }
        }
    }

    // ------------------------------------------------------------ experiment
    private var experimentCard: some View {
        let h = hub.heat
        return Card(title: "Trace a heat path", note: "Runs 75 s: 6 s baseline, 45 s of load on the block you pick, 24 s of cool-down. Every SMC and HID temperature is sampled twice a second. The load is light enough to be safe; fans may spin up.") {
            HStack(spacing: 10) {
                Picker("Heat source", selection: $ui.thermalSource) {
                    ForEach([LoadKind.pCores, .gpu, .ssd, .ane, .eCores]) { Text($0.label).tag($0) }
                }
                .frame(width: 220).disabled(h.running)
                Button(h.running ? "Running…" : "Run (75 s)") { hub.runHeatPath(ui.thermalSource) }
                    .buttonStyle(.borderedProminent).disabled(h.running)
                if h.running {
                    ProgressView(value: min(1, h.elapsed / 75)).frame(width: 160)
                    Text(h.elapsed < 6 ? "baseline" : h.elapsed < 51 ? "heating \(h.source.label)" : "cooling").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            if !h.series.isEmpty { liveTraces }
        }
    }

    /// The sensors that moved most, as °C over the run (one y-axis).
    private var liveTraces: some View {
        let h = hub.heat
        let ranked = h.series.map { id, pts -> (String, Double) in
            let base = pts.prefix(8).map(\.1).reduce(0, +) / Double(max(1, min(8, pts.count)))
            return (id, (pts.map(\.1).max() ?? base) - base)
        }.sorted { $0.1 > $1.1 }.prefix(6).map(\.0)
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                RectangleMark(xStart: .value("s", h.start), xEnd: .value("s", min(h.end, max(h.start, h.elapsed))))
                    .foregroundStyle(Color(hex: 0xF0412B).opacity(0.10))
                ForEach(Array(ranked.enumerated()), id: \.offset) { i, id in
                    ForEach(Array((h.series[id] ?? []).enumerated()), id: \.offset) { _, pt in
                        LineMark(x: .value("s", pt.0), y: .value("°C", pt.1), series: .value("id", id)).foregroundStyle(Theme.series[i % 8]).lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
            }
            .chartXScale(domain: 0...75)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: [0, 6, 25, 51, 75]) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) s") } } } }
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f °C", d)) } } } }
            .chartLegend(.hidden)
            .frame(height: 170)
            HStack(spacing: 12) {
                ForEach(Array(ranked.enumerated()), id: \.offset) { i, id in LegendLine(color: Theme.series[i % 8], label: short(h.names[id]?.0 ?? id)) }
            }.lineLimit(1)
            Text("Shaded = load on. The six sensors that moved most.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private func short(_ s: String) -> String { s.count > 18 ? String(s.prefix(17)) + "…" : s }

    private var resultsCard: some View {
        let h = hub.heat
        let onPath = h.results.filter { $0.arrival != nil }
        let stages = ["on the die (< 2 s)", "package & spreader (2–10 s)", "heat pipe & nearby board (10–30 s)", "far side (> 30 s)"]
        return Card(title: h.done ? "Heat path from the \(h.source.label)" : "Heat path", note: h.done ? "Arrival = seconds until a sensor rose 10% of its total rise (at least 0.3 °C). \(h.results.count - onPath.count) sensors did not move by 0.5 °C and are not on this path." : nil) {
            if !h.done {
                Text("Run an experiment to see the measured path. Try P-cores first, then GPU: sensors that answer one but not the other sit next to that block.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
            } else {
                Chart(onPath) { r in
                    PointMark(x: .value("arrival (s)", r.arrival!), y: .value("rise (°C)", r.rise))
                        .foregroundStyle(tempColor(r.peak)).symbolSize(70)
                }
                .chartXScale(domain: 0...50, type: .symmetricLog)
                .chartXAxis { AxisMarks(values: [0, 1, 2, 5, 10, 20, 50]) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) s") } } } }
                .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.grid); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "+%.0f °C", d)) } } } }
                .frame(height: 170)
                ForEach(stages, id: \.self) { st in
                    let items = onPath.filter { heatStage($0.arrival) == st }
                    if !items.isEmpty {
                        SectionTitle(text: "\(st) · \(items.count)")
                        ForEach(items.prefix(8)) { r in
                            HStack {
                                Circle().fill(tempColor(r.peak)).frame(width: 9, height: 9)
                                Text(r.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text(String(format: "+%.1f °C", r.rise)).monospacedDigit().font(.system(size: 12))
                                Text(String(format: "%.1f s", r.arrival!)).monospacedDigit().font(.system(size: 12)).foregroundStyle(Theme.ink2).frame(width: 52, alignment: .trailing)
                            }
                        }
                        if items.count > 8 { Text("+ \(items.count - 8) more").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                    }
                }
            }
        }
    }
}
