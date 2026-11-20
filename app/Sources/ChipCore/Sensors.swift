import CChip
import Foundation

public struct SMCValue { public var key: String; public var type: String; public var value: Double?; public var us: Double }

public final class SMCReader {
    public let ok: Bool
    public init() { ok = cc_smc_open() == 0 }

    public func read(_ key: String) -> SMCValue? {
        guard ok, key.utf8.count == 4 else { return nil }
        var type = [CChar](repeating: 0, count: 5)
        var bytes = [UInt8](repeating: 0, count: 32)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let n = key.withCString { k in cc_smc_read(k, &type, &bytes) }
        let us = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        guard n > 0 else { return nil }
        let ty = String(cString: type)
        return SMCValue(key: key, type: ty.trimmingCharacters(in: .whitespaces), value: decode(ty, Array(bytes.prefix(Int(n)))), us: us)
    }

    public func keys() -> [String] {
        guard ok else { return [] }
        var out: [String] = []
        var k = [CChar](repeating: 0, count: 5)
        for i in 0..<Int(cc_smc_key_count()) where cc_smc_key_at(Int32(i), &k) == 0 { out.append(String(cString: k)) }
        return out
    }
}

public func decode(_ type: String, _ b: [UInt8]) -> Double? {
    func be(_ n: Int) -> UInt64 { b.prefix(n).reduce(0) { $0 << 8 | UInt64($1) } }
    switch type.trimmingCharacters(in: .whitespaces) {
    case "flt" where b.count >= 4: return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
    case "ui8", "flag": return b.isEmpty ? nil : Double(b[0])
    case "ui16" where b.count >= 2: return Double(be(2))
    case "ui32" where b.count >= 4: return Double(be(4))
    case "si8": return b.isEmpty ? nil : Double(Int8(bitPattern: b[0]))
    case "si16" where b.count >= 2: return Double(Int16(bitPattern: UInt16(be(2))))
    case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(be(2)))) / 256
    case "fpe2" where b.count >= 2: return Double(be(2)) / 4
    default: return nil
    }
}

/// SMC keys by Apple's naming convention (first letter). "temperature" only for plausible °C values.
public func smcCategory(_ key: String, _ v: Double?, _ type: String) -> String {
    guard let c = key.first else { return "other" }
    switch c {
    case "T": return (type == "flt" || type == "sp78" || type == "fpe2") && (v ?? -1) > 1 && (v ?? 999) < 130 ? "temperature" : "other"
    case "F": return "fan"
    case "P": return type == "flt" ? "power" : "other"
    case "V": return type == "flt" ? "voltage" : "other"
    case "I": return type == "flt" ? "current" : "other"
    default: return "other"
    }
}

/// From the open-source "Stats" app's map for M1 Pro/Max. Not from Apple: shown as "community map".
public let COMMUNITY_TEMPS: [String: String] = [
    "Tp09": "E-core area 1", "Tp0T": "E-core area 2", "Tp01": "P-core area 1", "Tp05": "P-core area 2", "Tp0D": "P-core area 3",
    "Tp0H": "P-core area 4", "Tp0L": "P-core area 5", "Tp0P": "P-core area 6", "Tp0X": "P-core area 7", "Tp0b": "P-core area 8",
    "Tg05": "GPU area 1", "Tg0D": "GPU area 2", "Tg0L": "GPU area 3", "Tg0T": "GPU area 4",
]

public struct HIDTemp { public var name: String; public var c: Double; public var us: Double; public var place: String }

public final class HIDTempReader {
    public let names: [String]
    public init() {
        let n = Int(cc_hid_open())
        var raw = (0..<n).map { String(cString: cc_hid_name(Int32($0))) }
        var seen: [String: Int] = [:]
        for i in raw.indices { seen[raw[i], default: 0] += 1; if seen[raw[i]]! > 1 { raw[i] += " #\(seen[raw[i]]!)" } }
        names = raw
    }
    public func read() -> [HIDTemp] {
        var out: [HIDTemp] = []
        for (i, name) in names.enumerated() {
            var us = 0.0
            let c = cc_hid_read(Int32(i), &us)
            if c > -40 && c < 150 { out.append(HIDTemp(name: name, c: c, us: us, place: hidPlace(name))) }
        }
        return out
    }
}

public func hidPlace(_ name: String) -> String {
    let n = name.lowercased()
    if n.contains("nand") { return "ssd" }
    if n.contains("battery") || n.contains("gas gauge") { return "battery" }
    if n.contains("tdie") || n.contains("tdev") || n.contains("tcal") || n.contains("pmu") { return "soc" }
    return "board"
}
