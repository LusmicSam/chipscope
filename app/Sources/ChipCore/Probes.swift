import Foundation

/// The native probe/load helper (native/probe.m), shipped inside the app bundle.
public enum Helper {
    public static var url: URL? {
        if let u = Bundle.main.url(forAuxiliaryExecutable: "chipscope-probe"), FileManager.default.isExecutableFile(atPath: u.path) { return u }
        let dev = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("chipscope-probe")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }
    public static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("chipscope")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var ssdFile: String { cacheDir.appendingPathComponent("ssd-probe.bin").path }

    /// Run the helper and call `line` for every JSON object it prints (on a background thread). Blocks until exit.
    @discardableResult
    public static func run(_ args: [String], timeout: Double = 120, line: (([String: Any]) -> Void)? = nil) -> [[String: Any]] {
        guard let url else { return [] }
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var out: [[String: Any]] = []
        var buffer = Data()
        let h = pipe.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let l = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let o = try? JSONSerialization.jsonObject(with: l) as? [String: Any] { out.append(o); line?(o) }
            }
        }
        p.waitUntilExit()
        killer.cancel()
        return out
    }
}

public enum LoadKind: String, CaseIterable, Identifiable {
    case pCores = "cpu-p", eCores = "cpu-e", memory = "mem", gpu = "gpu", ane = "ane", ssd = "ssd"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .pCores: "P-cores"; case .eCores: "E-cores"; case .memory: "Memory"; case .gpu: "GPU"; case .ane: "Neural Engine"; case .ssd: "SSD" }
    }
    public var short: String { self == .ane ? "ANE" : label }
    public var args: [String] {
        switch self {
        case .pCores: ["burn", "cpu", "--qos", "p", "--threads", "6"]
        case .eCores: ["burn", "cpu", "--qos", "e", "--threads", "2"]
        case .memory: ["burn", "mem", "--threads", "4"]
        case .gpu: ["burn", "gpu"]
        case .ane: ["burn", "ane"]
        case .ssd: ["burn", "ssd", "--file", Helper.ssdFile]
        }
    }
}

/// Load generators: one helper process per kind, capped at 60 s, stopped on quit.
public final class Loads {
    private var procs: [LoadKind: (Process, Date)] = [:]
    private let lock = NSLock()
    public init() {}

    public func start(_ k: LoadKind, seconds: Int = 20) {
        guard let url = Helper.url else { return }
        lock.lock(); defer { lock.unlock() }
        if let (p, _) = procs[k], p.isRunning { return }
        let p = Process()
        p.executableURL = url
        p.arguments = k.args + ["--seconds", String(max(3, min(seconds, 60)))]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { procs[k] = (p, Date().addingTimeInterval(Double(max(3, min(seconds, 60))))) }
    }
    public func stop(_ k: LoadKind? = nil) {
        lock.lock(); defer { lock.unlock() }
        for (kind, (p, _)) in procs where k == nil || k == kind { if p.isRunning { p.terminate() } }
    }
    /// Running loads and when they end.
    public func status() -> [LoadKind: Date] {
        lock.lock(); defer { lock.unlock() }
        return procs.compactMapValues { $0.0.isRunning ? $0.1 : nil }
    }
}

// ------------------------------------------------------------------ signal-timing atlas
public struct AtlasEntry: Identifiable {
    public var id: String, label: String, group: String, block: String, how: String
    public var ns: Double
    public var spread: (Double, Double)?
}

public struct ProbeResults {
    public var date = Date()
    public var load: [Double] = []
    public var misc: [String: [String: Any]] = [:]
    public var memlatP: [(size: Double, ns: Double, cpu: Int)] = []
    public var memlatE: [(size: Double, ns: Double, cpu: Int)] = []
    public var c2c: [(a: Int, b: Int, ns: Double)] = []
    public var c2cDrops: [String: Int] = [:]
    public var ssd: [String: Any] = [:]
    public var gpu: [String: [String: Any]] = [:]
    public var ane: [String: Any] = [:]
    public var net: [String: Double] = [:]
    public init() {}
}

func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }

/// Ping the default gateway (Wi-Fi radio + router round trip), microseconds.
public func pingGateway() -> [String: Double] {
    let r = shell("/sbin/route", ["-n", "get", "default"])
    guard let line = r.split(separator: "\n").first(where: { $0.contains("gateway:") }),
          let gw = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return [:] }
    let out = shell("/sbin/ping", ["-c", "8", "-i", "0.2", "-t", "5", gw])
    guard let eq = out.range(of: "= ", options: .backwards) else { return [:] }
    let v = out[eq.upperBound...].split(separator: "/").compactMap { Double($0) }
    return v.count >= 3 ? ["p10": v[0] * 1000, "p50": v[1] * 1000, "p90": v[2] * 1000] : [:]
}

public enum ProbeSuite {
    /// Runs every probe (~25 s). `progress(step, memlat point?)` is called from a background thread.
    public static func run(load: [Double], progress: @escaping (String, (Double, Double, Int)?) -> Void) -> ProbeResults {
        var r = ProbeResults()
        r.load = load
        progress("kernel + timer", nil)
        for d in Helper.run(["misc"], timeout: 30) { if let k = d["kind"] as? String { r.misc[k] = d } }
        for q in ["p", "e"] {
            progress(q == "p" ? "memory hierarchy on P-cores" : "memory hierarchy on E-cores", nil)
            Helper.run(["memlat", "--qos", q, "--max-mb", q == "p" ? "256" : "128"], timeout: 120) { d in
                guard let s = num(d, "size"), let ns = num(d, "ns") else { return }
                let pt = (s, ns, (d["cpu"] as? NSNumber)?.intValue ?? -1)
                if q == "p" { r.memlatP.append(pt) } else { r.memlatE.append(pt) }
                progress(q == "p" ? "memory hierarchy on P-cores" : "memory hierarchy on E-cores", pt)
            }
        }
        progress("core-to-core", nil)
        for d in Helper.run(["c2c", "--seconds", "4"], timeout: 30) {
            if let a = (d["a"] as? NSNumber)?.intValue, let b = (d["b"] as? NSNumber)?.intValue, let ns = num(d, "ns") { r.c2c.append((a, b, ns)) }
            if let why = d["drop"] as? String { r.c2cDrops[why, default: 0] += 1 }
        }
        progress("SSD", nil)
        r.ssd = Helper.run(["ssdlat", "--file", Helper.ssdFile, "--mb", "128", "--n", "400"], timeout: 60).first { $0["kind"] != nil } ?? [:]
        progress("GPU", nil)
        for d in Helper.run(["gpulat", "--n", "200"], timeout: 60) { if let k = d["kind"] as? String { r.gpu[k] = d } }
        progress("Neural Engine", nil)
        r.ane = Helper.run(["anelat", "--n", "20"], timeout: 60).first { $0["kind"] != nil } ?? [:]
        progress("Wi-Fi", nil)
        r.net = pingGateway()
        r.date = Date()
        return r
    }
}

public struct C2CClasses { public var sameP: [Double] = [], crossP: [Double] = [], pE: [Double] = [], sameE: [Double] = [] }

public func c2cClasses(_ t: Topology, _ pairs: [(a: Int, b: Int, ns: Double)]) -> C2CClasses {
    var m: [Int: (String, String)] = [:]
    for (c, k) in t.liveCores { if let l = k.logical { m[l] = (c.id, c.type) } }
    var g = C2CClasses()
    for p in pairs {
        guard let (ca, ta) = m[p.a], let (cb, tb) = m[p.b] else { continue }
        if ca == cb { if ta == "E" { g.sameE.append(p.ns) } else { g.sameP.append(p.ns) } }
        else if ta == "P" && tb == "P" { g.crossP.append(p.ns) }
        else { g.pE.append(p.ns) }
    }
    return g
}

public func band(_ pts: [(size: Double, ns: Double, cpu: Int)], _ lo: Double, _ hi: Double) -> Double? {
    median(pts.filter { $0.size >= lo && $0.size <= hi }.map(\.ns))
}

/// Every component placed by measured signal time (ns). `passive` adds sensor-read and SSD-driver timings.
public func atlas(_ t: Topology, _ r: ProbeResults?, passive: [String: (Double, Int)], diskLifeUs: Double?) -> [AtlasEntry] {
    var e: [AtlasEntry] = []
    func add(_ id: String, _ label: String, _ ns: Double?, _ group: String, _ block: String, _ how: String, _ spread: (Double, Double)? = nil) {
        if let ns { e.append(AtlasEntry(id: id, label: label, group: group, block: block, how: how, ns: ns, spread: spread)) }
    }
    let c = t.caches
    let pL1 = Double(c["perflevel0.l1dcachesize"] ?? 131072), pL2 = Double(c["perflevel0.l2cachesize"] ?? 12 << 20)
    let eL1 = Double(c["perflevel1.l1dcachesize"] ?? 65536), eL2 = Double(c["perflevel1.l2cachesize"] ?? 4 << 20)
    let slc = Double(t.spec.slcBytes > 0 ? t.spec.slcBytes : 24 << 20)
    if let r {
        add("p_l1", "P-core L1 cache", band(r.memlatP, 0, pL1 / 2), "cache", "pclu0", "pointer chase, sets ≤ \(Int(pL1 / 2048)) KiB")
        add("p_l2", "P-cluster L2 cache", band(r.memlatP, pL1 * 4, pL2 / 4), "cache", "pclu0", "pointer chase, sets \(Int(pL1 * 4 / 1024)) KiB–\(Int(pL2 / 4) >> 20) MiB")
        add("slc", "System level cache", band(r.memlatP, pL2, slc * 0.75), "memory", "slc", "pointer chase, sets \(Int(pL2) >> 20)–\(Int(slc * 0.75) >> 20) MiB")
        add("dram", "DRAM (LPDDR5)", band(r.memlatP, slc * 4, 1e15), "memory", "dram", "pointer chase, sets ≥ \(Int(slc * 4) >> 20) MiB (incl. TLB misses)")
        add("e_l1", "E-core L1 cache", band(r.memlatE, 0, eL1 / 2), "cache", "eclu", "pointer chase on an E-core")
        add("e_l2", "E-cluster L2 cache", band(r.memlatE, eL1 * 4, eL2 / 4), "cache", "eclu", "pointer chase on an E-core")
        let g = c2cClasses(t, r.c2c)
        for (id, label, v, block) in [("c2c_sp", "Core ↔ core, same P-cluster", g.sameP, "pclu0"), ("c2c_xp", "Core ↔ core, across P-clusters", g.crossP, "fabric"),
                                      ("c2c_pe", "P-core ↔ E-core", g.pE, "fabric"), ("c2c_ee", "E-core ↔ E-core", g.sameE, "eclu")] where !v.isEmpty {
            add(id, label, median(v), "cores", block, "cache-line ping-pong, one way, \(v.count) runs", (percentile(v, 10)!, percentile(v, 90)!))
        }
        if let v = r.misc["timer_read"].flatMap({ num($0, "p50") }) { add("timer", "System timer read", v, "os", "pclu0", "mach_absolute_time() loop") }
        if let v = r.misc["syscall"].flatMap({ num($0, "p50") }) { add("syscall", "Kernel (one syscall)", v, "os", "pclu0", "getppid() loop") }
        if let w = r.misc["thread_wake"], let v = num(w, "p50") {
            add("wake", "Wake another thread", v * 1000, "os", "pclu0", "semaphore ping-pong, one way", (num(w, "p10")! * 1000, num(w, "p90")! * 1000))
        }
        if let v = num(r.ssd, "p50") { add("nand", "SSD NAND read (16 KiB)", v * 1000, "storage", "ans", "uncached random read", (num(r.ssd, "p10")! * 1000, num(r.ssd, "p90")! * 1000)) }
        if let g = r.gpu["gpu_roundtrip"], let v = num(g, "p50") {
            add("gpu_rt", "GPU round trip", v * 1000, "accel", "gpu", "empty Metal dispatch, commit → completed", (num(g, "p10")! * 1000, num(g, "p90")! * 1000))
        }
        if let v = r.gpu["gpu_exec"].flatMap({ num($0, "p50") }) { add("gpu_exec", "GPU kernel execution", v * 1000, "accel", "gpu", "GPU timestamps") }
        if let v = num(r.ane, "p50") { add("ane", "Neural Engine via Vision", v * 1e6, "accel", "ane", "image classification round trip (incl. CPU work)", (num(r.ane, "p10")! * 1e6, num(r.ane, "p90")! * 1e6)) }
        if let v = r.net["p50"] { add("wifi", "Wi-Fi → router and back", v * 1000, "network", "wifi", "ping to the default gateway", (r.net["p10"]! * 1000, r.net["p90"]! * 1000)) }
    }
    if let d = diskLifeUs { add("nand_life", "SSD read, lifetime average", d * 1000, "storage", "ans", "driver counters: read time ÷ reads (passive)") }
    let names = ["smc": "SMC sensor key", "hid_battery": "Battery gas gauge", "hid_pmu": "PMU die sensor", "hid_ssd": "NAND temperature sensor"]
    for (k, (us, n)) in passive { if let l = names[k] { add("s_" + k, l, us * 1000, "sensors", k == "hid_ssd" ? "ans" : "smc", "read round trip, \(n) sensors") } }
    return e.sorted { $0.ns < $1.ns }
}

/// Median one-way time per core pair, keyed "a-b" with a < b.
public func c2cMatrix(_ pairs: [(a: Int, b: Int, ns: Double)]) -> [String: (Double, Int)] {
    var cells: [String: [Double]] = [:]
    for p in pairs { cells["\(min(p.a, p.b))-\(max(p.a, p.b))", default: []].append(p.ns) }
    return cells.mapValues { (median($0)!, $0.count) }
}
