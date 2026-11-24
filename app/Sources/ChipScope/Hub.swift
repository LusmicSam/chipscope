import ChipCore
import AppKit
import Foundation
import Observation

/// Owns the collector and everything the views read. Main-thread only.
@Observable final class Hub {
    static let shared = Hub()

    let topo: Topology
    @ObservationIgnored let collector: Collector
    @ObservationIgnored let loads = Loads()
    static let maxFrames = 1200   // 5 minutes at 4/s

    /// Every frame at 4/s for replay. Not observed directly: views watch `tick`, which moves at 2/s and
    /// only while the window is on screen (redrawing SwiftUI is the app's main cost).
    @ObservationIgnored var frames: [Frame] = []
    var latest: Frame?
    var tick = 0
    var summary = (busy: 0.0, socW: 0.0)   // menu bar, 1/s even when the window is hidden
    var sweep = SensorSweep()
    var wifi = ""
    var wifiLink = ""
    var loadStatus: [LoadKind: Date] = [:]
    var findings: [Finding] = []

    // signal timing
    var probes: ProbeResults?
    var probeStep: String?
    var probeLiveP: [(size: Double, ns: Double, cpu: Int)] = []
    var probeLiveE: [(size: Double, ns: Double, cpu: Int)] = []

    // heat path
    var heat = HeatRun()

    private init() {
        topo = ProcessInfo.processInfo.environment["CHIPSCOPE_PREVIEW_CHIP"].flatMap(previewTopology) ?? TopologyReader.read()
        EXPLAIN = makeExplain(topo)
        collector = Collector(topo: topo)
    }

    func start() {
        collector.onFrame = { [weak self] f in self?.push(f) }
        collector.onSweep = { [weak self] s in
            guard let self else { return }
            var s = s
            if s.smc.isEmpty { s.smc = sweep.smc; s.latency["smc"] = sweep.latency["smc"] }   // partial sweep: keep SMC rows
            sweep = s
        }
        collector.start()
        DispatchQueue.global(qos: .utility).async {
            let w = TopologyReader.wifi()
            DispatchQueue.main.async { self.wifi = w.card; self.wifiLink = w.link }
        }
    }

    private func push(_ f: Frame) {
        frames.append(f)
        if frames.count > Hub.maxFrames {
            frames.removeFirst(frames.count - Hub.maxFrames)
            if let c = UIState.shared.cursor { UIState.shared.cursor = max(0, c - 1) }
        }
        if f.id % 4 == 0 {
            summary = (f.chip.cores.values.map(\.busy).reduce(0, +) / Double(max(1, f.chip.cores.count)), f.chip.socW)
        }
        // Redraw 2×/s while chipscope is the active app, 1×/s when visible behind it, never when covered.
        guard f.id % (NSApp.isActive || alwaysDraw ? 2 : 4) == 0, windowVisible() else { return }
        latest = f
        tick += 1
        loadStatus = loads.status()
        if f.id % 8 == 0 { findings = Optimizer.analyze(f.board.procs, vm: f.board.vm) }
    }

    private let alwaysDraw = ProcessInfo.processInfo.environment["CHIPSCOPE_SNAPSHOT_DIR"] != nil
    private func windowVisible() -> Bool {
        alwaysDraw || NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.width > 600 } || latest == nil
    }

    func current(_ ui: UIState) -> Frame? {
        if let c = ui.cursor, frames.indices.contains(c) { return frames[c] }
        return latest
    }

    func window(_ n: Int, _ ui: UIState) -> ArraySlice<Frame> {
        _ = tick   // observe redraw ticks
        let end = ui.cursor.map { min($0 + 1, frames.count) } ?? frames.count
        return frames[max(0, end - n)..<end]
    }

    func toggleLoad(_ k: LoadKind) {
        if loadStatus[k] != nil { loads.stop(k) } else { loads.start(k, seconds: 20) }
        loadStatus = loads.status()
    }

    // ------------------------------------------------------------ probes
    func runProbes() {
        guard probeStep == nil else { return }
        probeStep = "starting"
        probeLiveP = []; probeLiveE = []
        let load = latest?.board.load ?? []
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ProbeSuite.run(load: load) { step, pt in
                DispatchQueue.main.async {
                    self.probeStep = step
                    if let pt { if step.contains("P-cores") { self.probeLiveP.append(pt) } else { self.probeLiveE.append(pt) } }
                }
            }
            DispatchQueue.main.async { self.probes = r; self.probeStep = nil }
        }
    }

    var atlasEntries: [AtlasEntry] {
        atlas(topo, probes, passive: sweep.latency, diskLifeUs: latest?.board.disk.lifeRdLatUs)
    }

    // ------------------------------------------------------------ heat path
    struct HeatRun {
        var running = false
        var source: LoadKind = .pCores
        var t0 = Date()
        var start = 6.0, end = 51.0          // load window, seconds since t0
        var elapsed = 0.0
        var series: [String: [(Double, Double)]] = [:]
        var names: [String: (String, String)] = [:]
        var results: [HeatResult] = []
        var done = false
    }

    func runHeatPath(_ source: LoadKind) {
        guard !heat.running else { return }
        heat = HeatRun(running: true, source: source, t0: Date())
        let total = 75.0   // 6 s baseline, 45 s load, 24 s afterwards
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            var started = false
            while true {
                let t = Date().timeIntervalSince(t0)
                if t > total { break }
                if !started && t >= 6 { started = true; DispatchQueue.main.async { self.loads.start(source, seconds: 45) } }
                let temps = self.collector.readAllTemps()
                DispatchQueue.main.async {
                    for s in temps {
                        self.heat.series[s.id, default: []].append((t, s.c))
                        self.heat.names[s.id] = (s.name, s.family)
                    }
                    self.heat.elapsed = t
                }
                Thread.sleep(forTimeInterval: max(0.05, 0.5 - Date().timeIntervalSince(t0.addingTimeInterval(t))))
            }
            DispatchQueue.main.async {
                self.heat.results = analyzeHeat(series: self.heat.series, names: self.heat.names, start: self.heat.start, end: self.heat.end)
                self.heat.running = false
                self.heat.done = true
            }
        }
    }
}
