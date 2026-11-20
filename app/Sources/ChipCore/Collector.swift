import Foundation

public struct Fan { public var rpm = 0.0, min = 0.0, max = 0.0 }

public struct BoardFrame {
    public var battery = Battery()
    public var disk = DiskRates()
    public var wifi = (rx: 0.0, tx: 0.0)
    public var vm = VMInfo()
    public var procs: [Proc] = []
    public var load: [Double] = []
    public var selfCPU = 0.0
    public var fans: [Fan] = []
    public var ports: [MacPort] = []
    public var smcTemps: [String: Double] = [:]      // community-mapped die keys
    public var socMax: Double?, socAvg: Double?, ssdTemp: Double?, batteryTemp: Double?
    public init() {}
}

public struct Frame: Identifiable {
    public var id: Int
    public var t: Date
    public var chip: ChipFrame
    public var board: BoardFrame
}

public struct SensorSweep {
    public struct Row: Identifiable { public var id: String; public var key: String; public var category: String; public var value: Double?; public var type: String; public var us: Double; public var label: String? }
    public var smc: [Row] = []
    public var hid: [HIDTemp] = []
    public var latency: [String: (Double, Int)] = [:]  // family -> (median µs, count)
    public var date = Date()
    public init() {}
}

/// Owns every reader and the timers. Frames are delivered on the main queue.
public final class Collector {
    public let topo: Topology
    public var onFrame: ((Frame) -> Void)?
    public var onSweep: ((SensorSweep) -> Void)?

    private let ior = IOReportReader()
    private let smc = SMCReader()
    private let hid = HIDTempReader()
    private let sensorLock = NSLock()
    private let q = DispatchQueue(label: "chipscope.fast", qos: .utility)
    private let slowQ = DispatchQueue(label: "chipscope.slow", qos: .utility)
    private var timers: [DispatchSourceTimer] = []
    private var board = BoardFrame()
    private let boardLock = NSLock()
    private var prevDisk: [String: Double] = [:], prevDiskT = Date()
    private var prevNet: [String: (UInt32, UInt32)] = [:], prevNetT = Date()
    private var smcTempKeys: [String] = []
    private var smcSensorKeys: [String] = []
    private let selfCPU = SelfCPU()
    private var seq = 0
    private var tick = 0

    public init(topo: Topology) {
        self.topo = topo
    }

    public func start(hz: Double = 4) {
        slowQ.async { [self] in
            let keys = smc.keys()
            var temps: [String] = [], sensors: [String] = []
            for k in keys {
                guard let v = smc.read(k) else { continue }
                let cat = smcCategory(k, v.value, v.type)
                if cat != "other" { sensors.append(k) }
                if cat == "temperature" { temps.append(k) }
            }
            sensorLock.lock(); smcSensorKeys = sensors; smcTempKeys = temps; sensorLock.unlock()
            sweep()
        }
        // One board read first, so the very first frame already carries battery, memory and ports.
        slowQ.async { [self] in
            slow()
            timers.append(timer(q, every: 1 / hz) { [weak self] in self?.fast() })
            timers.append(timer(slowQ, every: 1, delay: 1) { [weak self] in self?.slow() })
        }
        timers.append(timer(DispatchQueue.global(qos: .utility), every: 15, delay: 15) { [weak self] in self?.sweep() })
    }

    public func stop() { timers.forEach { $0.cancel() }; timers.removeAll() }

    private func timer(_ queue: DispatchQueue, every: Double, delay: Double = 0, _ fn: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, repeating: every, leeway: .milliseconds(20))
        t.setEventHandler(handler: fn)
        t.resume()
        return t
    }

    private func fast() {
        let raw = ior.sample()
        let chip = buildChipFrame(topo, raw, gpu: BoardReader.gpuStats())
        boardLock.lock(); let b = board; boardLock.unlock()
        seq += 1
        let f = Frame(id: seq, t: Date(), chip: chip, board: b)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(f) }
    }

    private func slow() {
        tick += 1
        var b = BoardFrame()
        boardLock.lock(); let old = board; boardLock.unlock()
        b.battery = BoardReader.battery()
        let now = Date()
        let disk = BoardReader.diskCounters()
        if !prevDisk.isEmpty { b.disk = BoardReader.diskRates(prevDisk, disk, dt: now.timeIntervalSince(prevDiskT)) } else { b.disk = old.disk }
        prevDisk = disk; prevDiskT = now
        let net = BoardReader.netCounters()
        if let (rx, tx) = net["en0"], let (prx, ptx) = prevNet["en0"] {
            let dt = max(now.timeIntervalSince(prevNetT), 0.1)
            b.wifi = (Double(rx &- prx) / dt, Double(tx &- ptx) / dt)  // 32-bit counters: wrapping subtraction
        }
        prevNet = net; prevNetT = now
        b.vm = BoardReader.vm()
        b.procs = tick % 3 == 1 || old.procs.isEmpty ? BoardReader.processes() : old.procs
        b.load = BoardReader.loadavg()
        b.selfCPU = selfCPU.percent()
        b.ports = tick % 2 == 1 || old.ports.isEmpty ? PortReader.read() : old.ports
        sensorLock.lock()
        if let n = smc.read("FNum")?.value {
            for i in 0..<Int(n) {
                b.fans.append(Fan(rpm: smc.read("F\(i)Ac")?.value ?? 0, min: smc.read("F\(i)Mn")?.value ?? 0, max: smc.read("F\(i)Mx")?.value ?? 0))
            }
        }
        for k in COMMUNITY_TEMPS.keys { if let v = smc.read(k)?.value, v > 0, v < 130 { b.smcTemps[k] = v } }
        sensorLock.unlock()
        b.socMax = old.socMax; b.socAvg = old.socAvg; b.ssdTemp = old.ssdTemp; b.batteryTemp = old.batteryTemp
        boardLock.lock(); board = b; boardLock.unlock()
    }

    private func sweep() {
        var s = SensorSweep()
        sensorLock.lock()
        let keys = smcSensorKeys
        for k in keys {
            guard let v = smc.read(k) else { continue }
            s.smc.append(.init(id: k, key: k, category: smcCategory(k, v.value, v.type), value: v.value, type: v.type, us: v.us, label: COMMUNITY_TEMPS[k]))
        }
        s.hid = hid.read()
        sensorLock.unlock()
        var lat: [String: [Double]] = [:]
        lat["smc"] = s.smc.map(\.us)
        for h in s.hid { lat[h.place == "battery" ? "hid_battery" : h.place == "ssd" ? "hid_ssd" : "hid_pmu", default: []].append(h.us) }
        s.latency = lat.filter { !$0.value.isEmpty }.mapValues { (median($0)!, $0.count) }
        let soc = s.hid.filter { $0.place == "soc" }.map(\.c)
        boardLock.lock()
        board.socMax = soc.max(); board.socAvg = soc.isEmpty ? nil : soc.reduce(0, +) / Double(soc.count)
        board.ssdTemp = s.hid.first { $0.place == "ssd" }?.c
        board.batteryTemp = s.hid.filter { $0.place == "battery" }.map(\.c).max()
        boardLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onSweep?(s) }
    }

    /// Every temperature sensor right now (SMC temperature keys + HID), for heat-path runs (~0.1 s).
    public func readAllTemps() -> [TempSensor] {
        sensorLock.lock(); defer { sensorLock.unlock() }
        var out: [TempSensor] = []
        for k in smcTempKeys { if let v = smc.read(k)?.value, v > 1, v < 130 {
            out.append(TempSensor(id: "smc:" + k, name: COMMUNITY_TEMPS[k].map { "\(k) · \($0)" } ?? k, source: "SMC", family: String(k.prefix(2)), c: v))
        } }
        for h in hid.read() { out.append(TempSensor(id: "hid:" + h.name, name: h.name, source: "HID", family: h.place, c: h.c)) }
        return out
    }
}
