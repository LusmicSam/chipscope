import ChipCore
import SwiftUI

/// Explain texts, filled from the real topology at launch (see makeExplain).
nonisolated(unsafe) var EXPLAIN: [String: String] = [:]

func makeExplain(_ t: Topology) -> [String: String] {
    let s = t.spec
    func slots(_ type: String) -> String {
        let cl = t.clusters.filter { $0.type == type }
        guard let c = cl.first else { return "" }
        let live = c.cores.filter { !$0.fused }.count, fused = c.cores.count - live
        let l2 = c.l2 > 0 ? " sharing one \(c.l2 >> 20) MB L2" : ""
        return "Each \(type)-cluster has \(c.cores.count) core slots\(l2)" + (fused > 0 ? "; on this chip \(fused) per cluster \(fused == 1 ? "is" : "are") fused off." : ".")
    }
    let gpuFused = s.gpuDieCores > t.gpuCores ? "The die has \(s.gpuDieCores) cores; \(t.gpuCores) are enabled. " : "\(t.gpuCores) cores. "
    let peak = s.memPeakBW > 0 ? "\(s.memType) on a \(s.memBusBits)-bit bus = \(Int(s.memPeakBW / 1e9)) GB/s peak (Apple spec). Heat is linear against that."
                               : "Peak bandwidth for this chip isn't in chipscope's table, so heat uses 200 GB/s as the scale."
    var e = BASE_EXPLAIN
    e["pclu"] = "Performance cores: wide out-of-order cores for heavy work. " + slots("P")
    e["eclu"] = "Efficiency cores: lower clock, a fraction of the power. macOS runs background work here. " + slots("E")
    e["gpu"] = "The GPU. " + gpuFused + "macOS reports one utilisation for the whole GPU, so every core shows the same value."
    e["ane"] = "Neural Engine\(s.aneCores > 0 ? " (\(s.aneCores) cores)" : ""). Runs Core ML and Vision models; idle unless an app runs one. Heat = power against a 3 W reference."
    e["slc"] = "System level cache\(s.slcBytes > 0 ? ": \(s.slcBytes >> 20) MB" : "") shared by every agent. Requests that hit here never reach DRAM. Hit rate is derived: 1 − DRAM traffic ÷ all agent traffic."
    e["mc"] = "Memory controllers: the traffic that actually reaches DRAM. " + peak
    e["dram"] = "Unified memory\(s.memPackages > 0 ? ": \(s.memPackages) \(s.memType) packages" : "") on the SoC package, shared by CPU, GPU and everything else - there is no separate video memory."
    return e
}

private let BASE_EXPLAIN: [String: String] = [
    "core": "One CPU core. Busy = share of time not idle. Clock = average frequency while busy, from the time spent in each voltage/frequency state.",
    "l2": "L2 cache shared by the cluster. Its traffic to the fabric is what the memory controller counts for this cluster.",
    "afc": "CPU side of the on-chip fabric (coherent). On the M1 Pro its counter equals the sum of the CPU clusters - checked live.",
    "afr": "GPU side of the fabric: two ports, each matching one GPU memory port.",
    "afi": "I/O and media side of the fabric: Neural Engine, display, camera, video, SSD, PCIe and USB-C traffic.",
    "media": "Fixed-function media engines: video decode/encode, ProRes, JPEG, scaling. Counters are their memory traffic.",
    "disp": "Display engines read the frame buffer from memory on every refresh.",
    "isp": "Image signal processor for the FaceTime camera; busy only while the camera is on.",
    "ans": "Apple's NVMe storage controller, inside the SoC. The NAND chips sit on the logic board.",
    "pcie": "PCIe links to the Wi-Fi/Bluetooth module and, where fitted, the SD card reader.",
    "atc": "USB-C / Thunderbolt port controllers.",
    "smc": "System Management Controller: a small processor inside the SoC running fans, sensors and power policy. ~2,000 keys; each read is a round trip to it.",
    "sep": "Secure Enclave: keys and Touch ID. Exposes no performance counters, by design.",
    "dcp": "Display coprocessor: firmware that drives the display pipeline.",
    "pmgr": "Power manager: sets every block's clock and voltage. The frequency tables here come from its device-tree node.",
]

struct SoCView: View {
    @Environment(Hub.self) private var hub
    @Environment(UIState.self) private var ui

    var body: some View {
        let t = hub.topo
        DesignCanvas(size: CGSize(width: 1180, height: 820)) {
            if let f = hub.current(ui) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    header(t)
                    Substrate(rect: CGRect(x: 20, y: 44, width: 1145, height: 766))
                    Die(rect: CGRect(x: 40, y: 72, width: 860, height: 715))
                    FlowLayer(flows: flows(f))
                    cpu(t, f)
                    gpu(t, f)
                    fabric(t, f)
                    dram(t, f)
                    bottom(t, f)
                }
            }
        }
        .padding(14)
    }

    private func header(_ t: Topology) -> some View {
        let p = t.liveCores.filter { $0.0.type == "P" }.count, e = t.liveCores.count - p
        return HStack(alignment: .firstTextBaseline) {
            Text("\(t.chip)").font(.system(size: 22, weight: .bold))
            Text(["\(p)P + \(e)E CPU", "\(t.gpuCores)-core GPU", t.spec.aneCores > 0 ? "\(t.spec.aneCores)-core Neural Engine" : "", t.spec.process].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(Theme.ink2)
            Spacer()
            Text("architectural layout · click any block").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(width: 1140).position(x: 590, y: 20)
    }

    // ------------------------------------------------------------ CPU
    @ViewBuilder private func cpu(_ t: Topology, _ f: Frame) -> some View {
        let g = cpuGrid(t)
        let layout: [(Cluster, CGFloat, CGFloat)] = {
            var x: CGFloat = 60
            return t.clusters.map { c in let w = g.width(c); defer { x += w + 12 }; return (c, x, w) }
        }()
        ForEach(layout, id: \.0.id) { c, x, w in
            let cs = f.chip.clusters[c.id]
            SiliconBlock(rect: CGRect(x: x, y: 92, width: w, height: 268), heat: nil, radius: 8)
                .onTapGesture { ui.go(.cluster(c.id)) }
                .tip(c.id) { Tip(value: Fmt.pct(cs?.busy) + " avg busy", label: c.label,
                                 rows: [("Cluster clock", Fmt.mhz(cs?.mhz)), ("Cores power (model)", Fmt.w(cs?.wCores)), ("Shared logic power", Fmt.w(cs?.wShared)),
                                        ("L2 ↔ fabric", Fmt.bps(f.chip.agentBW(c.amc)))],
                                 explain: EXPLAIN[c.type == "P" ? "pclu" : "eclu"], source: "IOReport CPU Complex States · Energy Model \(c.energy)") }
            Text(w >= CGFloat(c.short.count) * 8 + 12 ? c.short : c.short.replacingOccurrences(of: "-cluster", with: "")).font(.system(size: 13, weight: .semibold)).lineLimit(1).position(x: x + w / 2, y: 106)
            ForEach(Array(c.cores.enumerated()), id: \.1.id) { i, k in
                let r = g.rect(x, i)
                if k.fused {
                    GhostBlock(rect: r, lines: r.width >= 60 ? ["fused off", "slot \(k.slot)"] : ["off"])
                        .tip(k.id) { Tip(value: "Fused off", label: "\(c.label), slot \(k.slot)",
                                         rows: [("Evidence", "no cpu node in the device tree"), ("Energy channel", "\(c.energy)_CPU\(k.slot) reads 0")],
                                         explain: "Disabled at the factory in one-time fuses (binning). Nothing in software can turn it on.", source: "device tree /cpus") }
                } else {
                    let s = f.chip.cores[k.id]
                    SiliconBlock(rect: r, title: "\(c.type)\(k.slot)", lines: r.width >= 70 ? [Fmt.pct(s?.busy), Fmt.mhz(s?.mhz)] : r.width >= 44 ? [Fmt.pct(s?.busy)] : [],
                                 heat: ui.coreHeat(s, type: c.type, freqs: c.freqs), titleSize: r.width >= 44 ? 13 : 10)
                        .onTapGesture { ui.go(.core(k.id)) }
                        .tip(k.id) { coreTip(c, k, s) }
                }
            }
            let l2 = f.chip.bw[c.amc] ?? BW()
            SiliconBlock(rect: CGRect(x: x + 12, y: 298, width: w - 24, height: 50), title: c.l2 > 0 ? "\(c.l2 >> 20) MB L2" : "L2", lines: f.chip.hasBW ? [Fmt.bps(l2.total)] : [], heat: f.chip.hasBW ? lin(l2.total, 100e9) : nil)
                .onTapGesture { ui.go(.cluster(c.id)) }
                .tip(c.id + ".l2") { Tip(value: Fmt.bps(l2.total), label: "\(c.short) L2 ↔ fabric",
                                         rows: [("Read", Fmt.bps(l2.rd)), ("Write", Fmt.bps(l2.wr)), ("…reached DRAM", Fmt.bps(l2.dcsRd + l2.dcsWr))],
                                         explain: EXPLAIN["l2"], source: "IOReport AMC Stats \(c.amc)") }
        }
    }

    /// Core tiles for every cluster, sized so all clusters fit the CPU band (x 60…594, y 120…290)
    /// whatever the core counts: 2+4+4 on an M1 Pro, 6+4 on an M4, 4+6+6 on an M4 Max, 20 on an Ultra.
    struct CPUGrid {
        var rows = 2, w: CGFloat = 80, h: CGFloat = 80, gap: CGFloat = 6
        func cols(_ c: Cluster) -> Int { max(1, (c.cores.count + rows - 1) / rows) }
        func width(_ c: Cluster) -> CGFloat { CGFloat(cols(c)) * (w + gap) - gap + 24 }
        func rect(_ x: CGFloat, _ i: Int) -> CGRect {
            CGRect(x: x + 12 + CGFloat(i / rows) * (w + gap), y: 120 + CGFloat(i % rows) * (h + gap), width: w, height: h)
        }
    }
    private func cpuGrid(_ t: Topology) -> CPUGrid {
        let k = CGFloat(max(1, t.clusters.count))
        var best = CPUGrid()
        var bestSide: CGFloat = -1
        for rows in 1...5 {
            var g = CPUGrid(rows: rows)
            let cols = t.clusters.reduce(0) { $0 + g.cols($1) }
            let w = (534 - 12 * (k - 1) - 24 * k - g.gap * CGFloat(cols - Int(k))) / CGFloat(max(1, cols))
            let h = (170 - g.gap * CGFloat(rows - 1)) / CGFloat(rows)
            g.w = min(w, 110); g.h = min(h, 80)
            if min(g.w, g.h) > bestSide { bestSide = min(g.w, g.h); best = g }
        }
        return best
    }

    func coreTip(_ c: Cluster, _ k: CoreSlot, _ s: CoreSample?) -> Tip {
        Tip(value: Fmt.pct(s?.busy) + " busy", label: "\(c.type)-core \(k.slot) · \(c.label)",
            rows: [("Clock (while busy)", "\(Fmt.mhz(s?.mhz)) of \(Fmt.mhz(Double(c.freqs.max() ?? 0)))"), ("Power (Apple model)", Fmt.w(s?.w)),
                   ("Logical CPU", k.logical.map(String.init) ?? "—")],
            explain: EXPLAIN["core"], source: "IOReport CPU Core States \(k.ioreport ?? "") · Energy Model \(k.energy ?? "")")
    }

    // ------------------------------------------------------------ GPU
    @ViewBuilder private func gpu(_ t: Topology, _ f: Frame) -> some View {
        let g = f.chip.gpu
        let die = max(t.spec.gpuDieCores, t.gpuCores)
        let h = ui.gpuHeat(g, freqs: t.gpuFreqs)
        let gt = Tip(value: Fmt.pct(g.util ?? g.busy) + " utilised", label: "GPU (\(t.gpuCores) of \(die) cores)",
                     rows: [("Clock", Fmt.mhz(g.mhz)), ("Powered on", Fmt.pct(g.busy)), ("Power (model)", Fmt.w(g.w)), ("Memory in use", Fmt.bytes(g.memUsed)),
                            ("Memory traffic", Fmt.bps(f.chip.agentsBW(["GFX", "GFX1"])))],
                     explain: EXPLAIN["gpu"], source: "IOKit AGX PerformanceStatistics · IOReport GPU States")
        SiliconBlock(rect: CGRect(x: 614, y: 92, width: 266, height: 268), heat: nil, radius: 8)
            .onTapGesture { ui.go(.gpu) }.tip("gpu") { gt }
        Text("GPU · \(t.gpuCores) of \(die) cores").font(.system(size: 13, weight: .semibold)).position(x: 700, y: 106)
        let gc = gpuCols(die)
        let side = min(54, (238 - CGFloat(gc - 1) * 6) / CGFloat(gc)), hgt = min(48, (212 - CGFloat((die + gc - 1) / gc - 1) * 6) / CGFloat((die + gc - 1) / gc))
        ForEach(0..<die, id: \.self) { i in
            let r = CGRect(x: 628 + CGFloat(i % gc) * (side + 6), y: 120 + CGFloat(i / gc) * (hgt + 6), width: side, height: hgt)
            if i >= t.gpuCores {
                GhostBlock(rect: r, lines: ["?"])
                    .tip("gpu-ghost") { Tip(value: "\(die - t.gpuCores) of \(die) fused off", label: "GPU core slots",
                                            explain: "Which positions are off is not exposed, so these tiles are placeholders.", source: "IOKit gpu-core-count · Apple spec") }
            } else {
                SiliconBlock(rect: r, heat: h, radius: 4).onTapGesture { ui.go(.gpu) }.tip("gpu") { gt }
            }
        }
        Text("\(Fmt.pct(g.util ?? g.busy)) · \(Fmt.mhz(g.mhz)) · \(Fmt.w(g.w))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2).position(x: 747, y: 346)
    }

    /// GPU columns that give the biggest tiles in the 238 × 212 GPU area (4 for 8–16 cores, 8 for 40, 10 for 80).
    private func gpuCols(_ n: Int) -> Int {
        guard n > 0 else { return 4 }
        return (1...12).max { a, b in
            func side(_ c: Int) -> CGFloat { let r = (n + c - 1) / c; return min((238 - CGFloat(c - 1) * 6) / CGFloat(c), (212 - CGFloat(r - 1) * 6) / CGFloat(r)) }
            return side(a) < side(b)
        } ?? 4
    }

    // ------------------------------------------------------------ fabric, SLC, memory controllers
    @ViewBuilder private func fabric(_ t: Topology, _ f: Frame) -> some View {
        let fab = f.chip.fabric
        let afc = fab["AFC"] ?? FabricSample(), afrA = fab["AFR_A"] ?? FabricSample(), afrB = fab["AFR_B"] ?? FabricSample(), afi = fab["AF_I"] ?? FabricSample()
        bar(CGRect(x: 60, y: 392, width: 534, height: 20), "CPU fabric · AFC", lin(afc.total, 200e9)).tip("afc") { fabricTip(afc, "CPU fabric (coherent)", "afc") }
        bar(CGRect(x: 614, y: 392, width: 266, height: 20), "GPU fabric · AFR", lin(afrA.total + afrB.total, 200e9))
            .tip("afr") { fabricTip(FabricSample(rd: afrA.rd + afrB.rd, wr: afrA.wr + afrB.wr, members: afrA.members + afrB.members), "GPU fabric (2 ports)", "afr") }
        bar(CGRect(x: 60, y: 556, width: 820, height: 20), "I/O + media fabric · AF_I", lin(afi.total, 50e9)).tip("afi") { fabricTip(afi, "I/O + media fabric", "afi") }
        let m = f.chip.mem
        SiliconBlock(rect: CGRect(x: 60, y: 450, width: 640, height: 66), title: "System Level Cache" + (t.spec.slcBytes > 0 ? " · \(t.spec.slcBytes >> 20) MB" : ""),
                     lines: !f.chip.hasBW ? ["traffic counters not exposed on this chip"] : ["\(Fmt.bps(m.agentsTotal)) from all agents", m.slcHit.map { "≈ \(Fmt.pct($0)) served on-chip (derived)" } ?? "hit rate: — (little traffic)"],
                     heat: lin(m.agentsTotal, 200e9))
            .onTapGesture { ui.selection = "slc" }
            .tip("slc") { Tip(value: m.slcHit.map { Fmt.pct($0) + " served on-chip" } ?? "—", label: "System level cache (derived hit rate)",
                              rows: [("All agent traffic", Fmt.bps(m.agentsTotal)), ("Reached DRAM", Fmt.bps(m.dram)), ("Cache + controller power", Fmt.w(m.amccW))],
                              explain: EXPLAIN["slc"], source: "IOReport AMC Stats: agents vs DCS") }
        SiliconBlock(rect: CGRect(x: 712, y: 450, width: 168, height: 66), title: "Memory controllers", lines: !f.chip.hasBW ? ["not exposed"] : [Fmt.bps(m.dram)] + (t.spec.memPeakBW > 0 ? ["\(Fmt.pct(m.dram / t.spec.memPeakBW)) of peak"] : []),
                     heat: f.chip.hasBW ? lin(m.dram, t.spec.memScaleBW) : nil)
            .onTapGesture { ui.go(.memory) }
            .tip("mc") { Tip(value: Fmt.bps(m.dram), label: "Traffic reaching DRAM", rows: [("Read", Fmt.bps(m.dramRd)), ("Write", Fmt.bps(m.dramWr)),
                                                                                         ("Controller power", Fmt.w(m.dcsW))], explain: EXPLAIN["mc"], source: "IOReport AMC Stats DCS") }
    }

    private func bar(_ r: CGRect, _ title: String, _ heat: Double) -> some View {
        SiliconBlock(rect: r, title: title, heat: heat, radius: 4, titleSize: 11)
    }

    private func fabricTip(_ s: FabricSample, _ label: String, _ key: String) -> Tip {
        Tip(value: Fmt.bps(s.total), label: label,
            rows: [("Read", Fmt.bps(s.rd)), ("Write", Fmt.bps(s.wr)), ("Sum of its agents", Fmt.bps(s.members)),
                   ("Check", s.total > 1e6 ? String(format: "%.1f%% of port traffic", s.members / s.total * 100) : "—")],
            explain: EXPLAIN[key], source: "IOReport AMC Stats fabric port counters")
    }

    // ------------------------------------------------------------ DRAM packages (off the die, on the package)
    @ViewBuilder private func dram(_ t: Topology, _ f: Frame) -> some View {
        let m = f.chip.mem
        Text("Unified memory · \(Fmt.bytes(t.memoryBytes))").font(.system(size: 13, weight: .semibold)).position(x: 1037, y: 96)
        Text(t.spec.memPeakBW > 0 ? "\(t.spec.memType) · \(t.spec.memBusBits)-bit · \(Fmt.bps(t.spec.memPeakBW)) peak" : "").font(.system(size: 10.5)).foregroundStyle(Theme.muted).position(x: 1037, y: 112)
        ForEach(0..<min(2, max(1, t.spec.memPackages)), id: \.self) { i in
            MemoryPackage(rect: CGRect(x: 930, y: 130 + CGFloat(i) * 300, width: 215, height: 260), heat: lin(m.dram, t.spec.memScaleBW),
                          lines: [!f.chip.hasBW ? "traffic not exposed" : t.spec.memPackages == 2 ? "\(Fmt.bps(m.dram / 2)) (share)" : "\(Fmt.bps(m.dram)) total", "DRAM \(Fmt.w(m.dramW)) total"], kind: memKind(t))
                .onTapGesture { ui.go(.memory) }
                .tip("dram") { Tip(value: Fmt.bps(m.dram), label: "DRAM traffic (both packages)", rows: [("DRAM power", Fmt.w(m.dramW))], explain: EXPLAIN["dram"], source: "IOReport AMC Stats DCS · Energy Model DRAM0") }
        }
    }

    // ------------------------------------------------------------ accelerators, I/O, infrastructure
    @ViewBuilder private func bottom(_ t: Topology, _ f: Frame) -> some View {
        let B: CGFloat = 610
        SiliconBlock(rect: CGRect(x: 60, y: B, width: 150, height: 112), title: "Neural Engine", heat: nil)
            .onTapGesture { ui.selection = "ane" }
            .tip("ane") { Tip(value: Fmt.w(f.chip.aneW), label: t.spec.aneCores > 0 ? "Neural Engine (\(t.spec.aneCores) cores)" : "Neural Engine", rows: [("Memory traffic", Fmt.bps(f.chip.agentBW("ANE0")))],
                              explain: EXPLAIN["ane"], source: "Energy Model ANE0 · AMC Stats ANE0") }
        ForEach(0..<16, id: \.self) { i in
            SiliconBlock(rect: CGRect(x: 72 + CGFloat(i % 8) * 16.5, y: B + 30 + CGFloat(i / 8) * 18, width: 13, height: 14), heat: lin(f.chip.aneW, 3), radius: 2)
                .allowsHitTesting(false)
        }
        Text(Fmt.w(f.chip.aneW)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink2).position(x: 90, y: B + 96)
        let io: [(String, String, CGFloat, CGFloat, [String], Double, String?)] = [
            ("media", "Media", 218, 150, ["VDEC", "VENC0", "STRM CODEC", "JPG0", "JPG1", "MSR0"], 20e9, Fmt.w(f.chip.aveW + f.chip.msrW)),
            ("disp", "Display", 376, 110, ["DISP", "EXT DISP0", "EXT DISP1"], 10e9, nil),
            ("isp", "Camera ISP", 494, 80, ["ISP"], 5e9, Fmt.w(f.chip.ispW)),
            ("ans", "SSD ctrl", 582, 80, ["ANS"], 7e9, nil),
            ("pcie", "PCIe", 670, 70, ["PCIE LN"], 4e9, Fmt.w(f.chip.pcieW)),
            ("atc", "USB-C / TB", 748, 132, ["ATC0", "ATC1", "ATC2", "ATC3"], 10e9, nil),
        ]
        ForEach(io, id: \.0) { id, label, x, w, agents, peak, extra in
            let bw = f.chip.agentsBW(agents)
            SiliconBlock(rect: CGRect(x: x, y: B, width: w, height: 112), title: label, lines: [Fmt.bps(bw)] + (extra.map { [$0] } ?? []), heat: lin(bw, peak))
                .onTapGesture { ui.selection = id }
                .tip(id) { Tip(value: Fmt.bps(bw), label: "\(label) memory traffic",
                               rows: agents.filter { f.chip.bw[$0] != nil }.map { (AGENT_BY_ID[$0]!.label + (AGENT_BY_ID[$0]!.guessed ? " (name guessed)" : ""), Fmt.bps(f.chip.agentBW($0))) },
                               explain: EXPLAIN[id], source: "IOReport AMC Stats \(agents.joined(separator: ", "))") }
        }
        ForEach(Array([("smc", "SMC · fans & sensors"), ("sep", "Secure Enclave"), ("dcp", "Display coprocessor"), ("pmgr", "Power manager")].enumerated()), id: \.offset) { i, item in
            SiliconBlock(rect: CGRect(x: 60 + CGFloat(i) * 207, y: 736, width: 200, height: 34), title: item.1, heat: nil, titleSize: 12)
                .onTapGesture { ui.selection = item.0 }
                .tip(item.0) { Tip(value: item.0 == "smc" ? "sensor hub" : "no load counters", label: item.1, explain: EXPLAIN[item.0]) }
        }
    }

    // ------------------------------------------------------------ transport
    private func flows(_ f: Frame) -> [Flow] {
        let c = f.chip
        var out: [Flow] = []
        var x: CGFloat = 60
        for cl in hub.topo.clusters {
            let w: CGFloat = cl.type == "P" ? 190 : 130
            let b = c.bw[cl.amc] ?? BW()
            out.append(Flow(path: line(CGPoint(x: x + w / 2, y: 360), CGPoint(x: x + w / 2, y: 392)), rd: b.rd, wr: b.wr, offset: CGSize(width: 4, height: 0)))
            x += w + 12
        }
        let g0 = c.bw["GFX"] ?? BW(), g1 = c.bw["GFX1"] ?? BW()
        out.append(Flow(path: line(CGPoint(x: 694, y: 360), CGPoint(x: 694, y: 392)), rd: g0.rd, wr: g0.wr, offset: CGSize(width: 4, height: 0)))
        out.append(Flow(path: line(CGPoint(x: 800, y: 360), CGPoint(x: 800, y: 392)), rd: g1.rd, wr: g1.wr, offset: CGSize(width: 4, height: 0)))
        let fab = c.fabric
        if let a = fab["AFC"] { out.append(Flow(path: line(CGPoint(x: 327, y: 412), CGPoint(x: 327, y: 450)), rd: a.rd, wr: a.wr, offset: CGSize(width: 5, height: 0))) }
        let ra = (fab["AFR_A"]?.rd ?? 0) + (fab["AFR_B"]?.rd ?? 0), wa = (fab["AFR_A"]?.wr ?? 0) + (fab["AFR_B"]?.wr ?? 0)
        out.append(Flow(path: line(CGPoint(x: 747, y: 412), CGPoint(x: 747, y: 450)), rd: ra, wr: wa, offset: CGSize(width: 5, height: 0)))
        if let i = fab["AF_I"] { out.append(Flow(path: line(CGPoint(x: 380, y: 556), CGPoint(x: 380, y: 516)), rd: i.rd, wr: i.wr, offset: CGSize(width: 5, height: 0))) }
        out.append(Flow(path: line(CGPoint(x: 700, y: 483), CGPoint(x: 712, y: 483)), rd: c.mem.dramRd, wr: c.mem.dramWr, offset: CGSize(width: 0, height: 4)))
        var pa = Path(); pa.move(to: CGPoint(x: 880, y: 470)); pa.addCurve(to: CGPoint(x: 930, y: 260), control1: CGPoint(x: 905, y: 470), control2: CGPoint(x: 905, y: 260))
        var pb = Path(); pb.move(to: CGPoint(x: 880, y: 500)); pb.addCurve(to: CGPoint(x: 930, y: 560), control1: CGPoint(x: 905, y: 500), control2: CGPoint(x: 905, y: 560))
        out.append(Flow(path: pa, rd: c.mem.dramRd / 2, wr: c.mem.dramWr / 2, offset: CGSize(width: 0, height: 4)))
        out.append(Flow(path: pb, rd: c.mem.dramRd / 2, wr: c.mem.dramWr / 2, offset: CGSize(width: 0, height: 4)))
        let ioX: [(CGFloat, [String])] = [(293, ["VDEC", "VENC0", "STRM CODEC", "JPG0", "JPG1", "MSR0"]), (431, ["DISP", "EXT DISP0", "EXT DISP1"]), (534, ["ISP"]),
                                          (622, ["ANS"]), (705, ["PCIE LN"]), (814, ["ATC0", "ATC1", "ATC2", "ATC3"]), (135, ["ANE0"])]
        for (x, agents) in ioX {
            let rd = agents.reduce(0) { $0 + (c.bw[$1]?.rd ?? 0) }, wr = agents.reduce(0) { $0 + (c.bw[$1]?.wr ?? 0) }
            out.append(Flow(path: line(CGPoint(x: x, y: 610), CGPoint(x: x, y: 576)), rd: rd, wr: wr, peak: 10e9, offset: CGSize(width: 4, height: 0)))
        }
        return out
    }
}

// ------------------------------------------------------------------ physical pieces
struct Substrate: View {
    var rect: CGRect
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(hex: 0x1B1D21), Theme.substrate], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in   // gold contact pads along the package edge
                for x in stride(from: CGFloat(24), to: size.width - 20, by: 14) {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 5, width: 6, height: 3), cornerRadius: 1), with: .color(Color(hex: 0x9C7A3C).opacity(0.55)))
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: size.height - 8, width: 6, height: 3), cornerRadius: 1), with: .color(Color(hex: 0x9C7A3C).opacity(0.55)))
                }
            }
            RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0x34332F))
            Text("SoC package").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 30).padding(.top, 12)
        }
        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

struct Die: View {
    var rect: CGRect
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(hex: 0x1D1D24), Color(hex: 0x16161B), Color(hex: 0x1F1F27)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Canvas { ctx, size in   // standard-cell rows, drawn once for the whole die (like a die photo)
                var y: CGFloat = 8
                while y < size.height - 8 { ctx.fill(Path(CGRect(x: 8, y: y, width: size.width - 16, height: 0.6)), with: .color(.white.opacity(0.03))); y += 3.5 }
            }
            RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x5A5866), lineWidth: 1.5)   // seal ring
            RoundedRectangle(cornerRadius: 4).stroke(Color(hex: 0x3B3A45), lineWidth: 1).padding(5)
            Text("die").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
        }
        .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
}

struct MemoryPackage: View {
    var rect: CGRect
    var heat: Double
    var lines: [String]
    var kind = "DRAM"
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Color(hex: 0x1A1A1D), Theme.epoxy], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 8).fill(heatColor(heat)).opacity(0.18 + 0.7 * heat)
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10))
            Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6).offset(x: 12, y: 12)   // pin-1 mark
            VStack(alignment: .leading, spacing: 3) {
                Text(kind).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6)) }
            }
            .padding(.leading, 14).padding(.top, 28)
        }
        .frame(width: rect.width, height: rect.height)
        .contentShape(Rectangle())
        .position(x: rect.midX, y: rect.midY)
    }
}

/// "LPDDR5X-8533" -> "LPDDR5X"; unknown chip -> "DRAM".
func memKind(_ t: Topology) -> String { t.spec.memType.split(separator: "-").first.map(String.init) ?? "DRAM" }
