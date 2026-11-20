import Foundation

/// One temperature sensor, from either the SMC or the HID event system.
public struct TempSensor: Identifiable, Hashable {
    public var id: String          // "smc:Tp01" / "hid:PMU tdie3"
    public var name: String
    public var source: String      // "SMC" / "HID"
    public var family: String      // SMC key prefix (Tp, Tg, TB...) or HID place
    public var c: Double
}

/// What each SMC temperature-key family is called in public reverse-engineering notes. Unverified here:
/// the heat-path experiment is what actually places a sensor.
public let SMC_FAMILY_HINT: [String: String] = [
    "Tp": "CPU die (community)", "Tg": "GPU die (community)", "Tm": "memory (community)", "TB": "battery (community)",
    "TW": "Wi-Fi (community)", "TH": "SSD / NAND (community)", "Ts": "skin / palm rest (community)", "Ta": "airflow / ambient (community)",
    "TR": "charger / power (community)", "TV": "voltage regulators (community)", "TP": "power manager (community)",
]

/// Result of a heat-path run for one sensor.
public struct HeatResult: Identifiable {
    public var id: String
    public var name: String
    public var family: String
    public var base: Double         // °C before the load
    public var peak: Double
    public var rise: Double
    public var arrival: Double?     // s after load start until the sensor has risen 10% of its rise (≥ 0.3 °C)
    public var half: Double?        // s until 50% of its rise
}

/// series: id -> [(t seconds since run start, °C)]; the load runs from `start` to `end` (same clock).
public func analyzeHeat(series: [String: [(Double, Double)]], names: [String: (String, String)], start: Double, end: Double,
                        minRise: Double = 0.5) -> [HeatResult] {
    var out: [HeatResult] = []
    for (id, pts) in series {
        let before = pts.filter { $0.0 >= start - 6 && $0.0 < start }.map(\.1)
        let after = pts.filter { $0.0 >= start }
        guard before.count >= 3, after.count >= 3 else { continue }
        let base = before.reduce(0, +) / Double(before.count)
        let peak = after.map(\.1).max() ?? base
        let rise = peak - base
        var r = HeatResult(id: id, name: names[id]?.0 ?? id, family: names[id]?.1 ?? "", base: base, peak: peak, rise: rise)
        if rise >= minRise {
            let th10 = base + max(0.3, 0.1 * rise), th50 = base + 0.5 * rise
            r.arrival = after.first { $0.1 >= th10 }.map { $0.0 - start }
            r.half = after.first { $0.1 >= th50 }.map { $0.0 - start }
        }
        out.append(r)
    }
    return out.sorted { ($0.arrival ?? .infinity, -$0.rise) < ($1.arrival ?? .infinity, -$1.rise) }
}

/// Group sensors on the path into stages by arrival time.
public func heatStage(_ arrival: Double?) -> String {
    guard let a = arrival else { return "not reached" }
    switch a {
    case ..<2: return "on the die (< 2 s)"
    case ..<10: return "package & spreader (2–10 s)"
    case ..<30: return "heat pipe & nearby board (10–30 s)"
    default: return "far side (> 30 s)"
    }
}
