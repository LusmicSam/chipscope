import Darwin
import Foundation
import IOKit

public struct Battery {
    public init() {}
    public var percent: Int?; public var charging = false; public var plugged = false
    public var volts: Double?; public var amps: Double?; public var tempC: Double?; public var cycles: Int?; public var health: Double?
    public var sysInW: Double?; public var sysLoadW: Double?; public var battW: Double?; public var adapterW: Int?
}

public struct DiskRates {
    public init() {}
    public init(rdBps: Double, wrBps: Double, rdIOPS: Double, wrIOPS: Double) { self.rdBps = rdBps; self.wrBps = wrBps; self.rdIOPS = rdIOPS; self.wrIOPS = wrIOPS }
    public var rdBps = 0.0, wrBps = 0.0, rdIOPS = 0.0, wrIOPS = 0.0; public var rdLatUs: Double?, wrLatUs: Double?, lifeRdLatUs: Double? }

public struct VMInfo {
    public var total = 0, free = 0, active = 0, inactive = 0, wired = 0, compressed = 0, fileBacked = 0, anonymous = 0, purgeable = 0, speculative = 0
    public var swapTotal = 0, swapUsed = 0, swapins = 0, swapouts = 0
    public var pressure = 0, freePercent = 0
    public var app: Int { max(0, anonymous - purgeable) }
    public init() {}
}

public struct Proc: Identifiable { public var pid: Int; public var ppid: Int; public var name: String; public var path: String; public var cpu: Double; public var rss: Int; public var age: Int; public var user: String; public var id: Int { pid } }

public enum BoardReader {
    public static func battery() -> Battery {
        var b = Battery()
        let p = IOReg.firstProps("AppleSmartBattery", keys: ["CurrentCapacity", "IsCharging", "ExternalConnected", "Voltage", "Amperage", "Temperature",
                                                             "CycleCount", "AppleRawMaxCapacity", "DesignCapacity", "PowerTelemetryData", "AdapterDetails"])
        guard !p.isEmpty else { return b }
        b.percent = (p["CurrentCapacity"] as? NSNumber)?.intValue
        b.charging = (p["IsCharging"] as? Bool) ?? false
        b.plugged = (p["ExternalConnected"] as? Bool) ?? false
        if let v = (p["Voltage"] as? NSNumber)?.doubleValue { b.volts = v / 1000 }
        if let a = (p["Amperage"] as? NSNumber)?.int64Value { b.amps = Double(a) / 1000 }
        if let t = (p["Temperature"] as? NSNumber)?.doubleValue { b.tempC = t / 100 }
        b.cycles = (p["CycleCount"] as? NSNumber)?.intValue
        if let raw = (p["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue, let d = (p["DesignCapacity"] as? NSNumber)?.doubleValue, d > 0 { b.health = raw / d }
        if let tel = p["PowerTelemetryData"] as? [String: Any] {
            b.sysInW = (tel["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 }
            b.sysLoadW = (tel["SystemLoad"] as? NSNumber).map { $0.doubleValue / 1000 }
            b.battW = (tel["BatteryPower"] as? NSNumber).map { $0.doubleValue / 1000 }
        }
        b.adapterW = ((p["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.intValue
        return b
    }

    public static func batteryPD() -> (pci: [[String: Any]], adapter: [String: Any]) {
        let p = IOReg.firstProps("AppleSmartBattery", keys: ["PortControllerInfo", "AdapterDetails"])
        return ((p["PortControllerInfo"] as? [[String: Any]]) ?? [], (p["AdapterDetails"] as? [String: Any]) ?? [:])
    }

    public static func gpuStats() -> [String: Any] {
        var out: [String: Any] = [:]
        IOReg.each("IOAccelerator") { s in if out.isEmpty { out = (IOReg.prop(s, "PerformanceStatistics") as? [String: Any]) ?? [:] } }
        return out
    }

    /// Cumulative counters of the internal NVMe SSD's block driver.
    public static func diskCounters() -> [String: Double] {
        var tot: [String: Double] = [:]
        IOReg.each("IOBlockStorageDriver") { s in
            guard (IOReg.parentClass(s) ?? "").contains("NVMe"), let st = IOReg.prop(s, "Statistics") as? [String: Any] else { return }
            for (k, key) in [("rdB", "Bytes (Read)"), ("wrB", "Bytes (Write)"), ("rdOps", "Operations (Read)"), ("wrOps", "Operations (Write)"),
                             ("rdNs", "Total Time (Read)"), ("wrNs", "Total Time (Write)")] {
                tot[k, default: 0] += (st[key] as? NSNumber)?.doubleValue ?? 0
            }
        }
        return tot
    }

    public static func diskRates(_ a: [String: Double], _ b: [String: Double], dt: Double) -> DiskRates {
        func d(_ k: String) -> Double { (b[k] ?? 0) - (a[k] ?? 0) }
        var r = DiskRates(rdBps: d("rdB") / dt, wrBps: d("wrB") / dt, rdIOPS: d("rdOps") / dt, wrIOPS: d("wrOps") / dt)
        if d("rdOps") > 0 { r.rdLatUs = d("rdNs") / d("rdOps") / 1000 }
        if d("wrOps") > 0 { r.wrLatUs = d("wrNs") / d("wrOps") / 1000 }
        if let ops = b["rdOps"], ops > 0 { r.lifeRdLatUs = (b["rdNs"] ?? 0) / ops / 1000 }
        return r
    }

    /// Byte counters per interface (32-bit, wraps: use deltas).
    public static func netCounters() -> [String: (UInt32, UInt32)] {
        var out: [String: (UInt32, UInt32)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let i = p {
            if let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = i.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                out[String(cString: i.pointee.ifa_name)] = (d.ifi_ibytes, d.ifi_obytes)
            }
            p = i.pointee.ifa_next
        }
        return out
    }

    public static func vm() -> VMInfo {
        var v = VMInfo()
        var s = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Sysctl.int("hw.pagesize") ?? 16384
        if r == KERN_SUCCESS {
            v.free = Int(s.free_count) * page; v.active = Int(s.active_count) * page; v.inactive = Int(s.inactive_count) * page
            v.wired = Int(s.wire_count) * page; v.compressed = Int(s.compressor_page_count) * page
            v.fileBacked = Int(s.external_page_count) * page; v.anonymous = Int(s.internal_page_count) * page
            v.purgeable = Int(s.purgeable_count) * page; v.speculative = Int(s.speculative_count) * page
            v.swapins = Int(s.swapins); v.swapouts = Int(s.swapouts)
        }
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 { v.swapTotal = Int(sw.xsu_total); v.swapUsed = Int(sw.xsu_used) }
        v.total = Sysctl.int("hw.memsize") ?? 0
        v.pressure = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 0
        v.freePercent = Sysctl.int("kern.memorystatus_level") ?? 0
        return v
    }

    public static func loadavg() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        return getloadavg(&l, 3) == 3 ? l : []
    }

    /// Every process: pid, parent, %CPU (ps' decaying average, 100 = one core), RSS, age, user, path.
    public static func processes() -> [Proc] {
        parsePS(shell("/bin/ps", ["-Ao", "pid=,ppid=,pcpu=,rss=,etime=,user=,comm="]))
    }

    public static func parsePS(_ text: String) -> [Proc] {
        var out: [Proc] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard p.count == 7, let pid = Int(p[0]), let ppid = Int(p[1]), let cpu = Double(p[2]), let rss = Int(p[3]) else { continue }
            let path = String(p[6]).trimmingCharacters(in: .whitespaces)
            out.append(Proc(pid: pid, ppid: ppid, name: (path as NSString).lastPathComponent, path: path, cpu: cpu, rss: rss * 1024,
                            age: parseEtime(String(p[4])), user: String(p[5])))
        }
        return out
    }

    /// ps etime "[[dd-]hh:]mm:ss" -> seconds
    public static func parseEtime(_ s: String) -> Int {
        var days = 0, rest = Substring(s)
        if let dash = s.firstIndex(of: "-") { days = Int(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        var secs = 0
        for x in parts { secs = secs * 60 + x }
        return days * 86400 + secs
    }
}

/// CPU time of this app (and children) as % of one core, between calls.
public final class SelfCPU {
    private var last: (Double, Double)
    public init() { last = SelfCPU.now() }
    private static func now() -> (Double, Double) {
        var a = rusage(), c = rusage()
        getrusage(RUSAGE_SELF, &a); getrusage(RUSAGE_CHILDREN, &c)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return (ProcessInfo.processInfo.systemUptime, s(a.ru_utime) + s(a.ru_stime) + s(c.ru_utime) + s(c.ru_stime))
    }
    public func percent() -> Double {
        let n = SelfCPU.now()
        defer { last = n }
        return 100 * (n.1 - last.1) / max(n.0 - last.0, 1e-3)
    }
}
