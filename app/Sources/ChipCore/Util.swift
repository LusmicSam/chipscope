import Foundation
import IOKit

public enum Sysctl {
    public static func raw(_ name: String) -> [UInt8]? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(size))
    }
    public static func int(_ name: String) -> Int? {
        guard let b = raw(name) else { return nil }
        var v: Int64 = 0
        for (i, x) in b.prefix(8).enumerated() { v |= Int64(x) << (8 * Int64(i)) }
        if b.count == 4 { v = Int64(Int32(truncatingIfNeeded: v)) }
        return Int(v)
    }
    public static func string(_ name: String) -> String? {
        guard let b = raw(name) else { return nil }
        return String(decoding: b.prefix { $0 != 0 }, as: UTF8.self)
    }
}

public enum IOReg {
    public static func props(_ e: io_registry_entry_t) -> [String: Any] {
        var ref: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(e, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = ref?.takeRetainedValue() as? [String: Any] else { return [:] }
        return d
    }
    public static func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    /// Calls `body` for every service of a class (handles are released afterwards).
    public static func each(_ cls: String, _ body: (io_service_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            body(s)
            IOObjectRelease(s)
        }
    }
    /// Only the named properties of the first service of a class (much cheaper than every property).
    public static func firstProps(_ cls: String, keys: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        var done = false
        each(cls) { s in
            guard !done else { return }
            done = true
            for k in keys { if let v = prop(s, k) { out[k] = v } }
        }
        return out
    }
    public static func firstProps(_ cls: String) -> [String: Any] {
        var out: [String: Any] = [:]
        each(cls) { s in if out.isEmpty { out = props(s) } }
        return out
    }
    public static func className(_ e: io_object_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(e, &buf)
        return String(cString: buf)
    }
    /// Children with only the named properties read (`keys` nil = all properties).
    public static func children(_ e: io_registry_entry_t, plane: String = "IOService", depth: Int = 2, keys: [String]? = nil) -> [(cls: String, props: [String: Any])] {
        var out: [(String, [String: Any])] = []
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(e, plane, &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while true {
            let c = IOIteratorNext(it)
            if c == 0 { break }
            if let keys {
                var p: [String: Any] = [:]
                for k in keys { if let v = prop(c, k) { p[k] = v } }
                out.append((className(c), p))
            } else { out.append((className(c), props(c))) }
            if depth > 1 { out.append(contentsOf: children(c, plane: plane, depth: depth - 1, keys: keys)) }
            IOObjectRelease(c)
        }
        return out
    }
    public static func parentClass(_ e: io_registry_entry_t) -> String? {
        var p: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(e, "IOService", &p) == KERN_SUCCESS, p != 0 else { return nil }
        defer { IOObjectRelease(p) }
        return className(p)
    }
}

/// Little-endian u32 from IORegistry data (or a plain number).
public func u32(_ v: Any?) -> Int? {
    if let d = v as? Data {
        var x: UInt32 = 0
        for (i, b) in d.prefix(4).enumerated() { x |= UInt32(b) << (8 * UInt32(i)) }
        return Int(x)
    }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

public func dataString(_ v: Any?) -> String? {
    if let d = v as? Data { return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self) }
    return v as? String
}

/// Run a command, return stdout (empty on failure).
public func shell(_ path: String, _ args: [String], timeout: Double = 10) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

public func median(_ v: [Double]) -> Double? {
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

public func percentile(_ v: [Double], _ p: Double) -> Double? {
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    return s[min(s.count - 1, Int(Double(s.count) * p / 100))]
}
