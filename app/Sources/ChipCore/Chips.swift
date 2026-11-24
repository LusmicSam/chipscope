import CoreGraphics
import Foundation

// ------------------------------------------------------------------ IOReport channel binding
// CPU channel names differ by chip (macmon #47): M1 Pro "PCPU120" (cluster 1, core 2), per-core
// energy "PACC1_CPU2"; Ultra prefixes "DIE_N_" and splits "PCPU1_CPU0"; M5 adds "MCPU". So the
// names are not built from a pattern but discovered: every core channel of a type, in natural
// order, is matched to that type's live cores in (cluster, slot) order - only when the counts agree.

private func cpuType(_ name: String) -> String? {
    if name.contains("PCPU") { return "P" }
    if name.contains("ECPU") || name.contains("MCPU") { return "E" }
    return nil
}

private func natural(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedAscending }

/// `channels`: (subgroup, or group when there is none; channel name).
public func bindChannels(_ t: inout Topology, _ channels: [(String, String)]) {
    let coreCh = channels.filter { $0.0 == "CPU Core Performance States" }.map(\.1)
    let complexCh = channels.filter { $0.0 == "CPU Complex Performance States" }.map(\.1)
    let energyCh = Set(channels.filter { $0.0 == "Energy Model" }.map(\.1))

    for type in ["P", "E"] {
        let idx = t.clusters.indices.filter { t.clusters[$0].type == type }
        // Cores.
        let names = coreCh.filter { cpuType($0) == type }.sorted(by: natural)
        let live = idx.flatMap { ci in t.clusters[ci].cores.indices.filter { !t.clusters[ci].cores[$0].fused }.map { (ci, $0) } }
        if !names.isEmpty && names.count == live.count {
            for (n, (ci, ki)) in zip(names, live) { t.clusters[ci].cores[ki].ioreport = n }
        }
        // Clusters: "PCPU", "PCPU1", "DIE_0_ECPU" … but not the shared-logic "PCPM".
        let cx = complexCh.filter { cpuType($0) == type && $0.range(of: #"^(DIE_\d+_)?[EPM]CPU\d*$"#, options: .regularExpression) != nil }.sorted(by: natural)
        if cx.count == idx.count { for (n, ci) in zip(cx, idx) { t.clusters[ci].ioreport = n } }
        // Energy: per-core channels "<prefix>_CPU<k>", prefix like EACC / PACC0 / DIE_0_PACC1.
        var prefixes: [String] = []
        for n in energyCh {
            guard let r = n.range(of: #"_CPU\d+$"#, options: .regularExpression) else { continue }
            let p = String(n[..<r.lowerBound])
            let acc = p.split(separator: "_").last.map(String.init) ?? p
            guard acc.hasSuffix("ACC") || acc.range(of: #"ACC\d+$"#, options: .regularExpression) != nil else { continue }
            if (acc.first == "P") == (type == "P"), !prefixes.contains(p) { prefixes.append(p) }
        }
        prefixes.sort(by: natural)
        guard prefixes.count == idx.count else { continue }
        for (p, ci) in zip(prefixes, idx) {
            t.clusters[ci].energy = p
            var ordinal = 0
            for ki in t.clusters[ci].cores.indices {
                let slot = t.clusters[ci].cores[ki].slot
                let bySlot = "\(p)_CPU\(slot)", byOrder = "\(p)_CPU\(ordinal)"
                if t.clusters[ci].cores[ki].fused { t.clusters[ci].cores[ki].energy = energyCh.contains(bySlot) ? bySlot : nil; continue }
                t.clusters[ci].cores[ki].energy = energyCh.contains(bySlot) ? bySlot : energyCh.contains(byOrder) ? byOrder : nil
                ordinal += 1
            }
        }
    }
}

// ------------------------------------------------------------------ published chip facts
// Apple's spec pages (GPU cores, Neural Engine cores, memory type/bus/bandwidth, process,
// transistors). SLC size and core slots per cluster are not published: filled only for the M1
// family (public die analysis). Anything unknown stays 0 / "" and the UI leaves it out.
public func chipSpec(_ brand: String, gpuCores: Int) -> Spec {
    func s(_ gpu: Int, _ ane: Int, _ bus: Int, _ mem: String, _ bw: Double, _ proc: String, _ tr: String = "",
           slc: Int = 0, pkgs: Int = 0, p: Int = 0, e: Int = 0) -> Spec {
        Spec(gpuDieCores: gpu, aneCores: ane, slcBytes: slc << 20, memBusBits: bus, memPackages: pkgs, memType: mem,
             transistors: tr, process: proc, memPeakBW: bw * 1e9, pSlots: p, eSlots: e)
    }
    let name = brand.replacingOccurrences(of: "Apple ", with: "")
    switch name {
    case "M1":       return s(8, 16, 128, "LPDDR4X-4266", 68.25, "TSMC 5 nm", "16 billion", slc: 8, pkgs: 2, p: 4, e: 4)
    case "M1 Pro":   return s(16, 16, 256, "LPDDR5-6400", 200, "TSMC 5 nm", "33.7 billion", slc: 24, pkgs: 2, p: 4, e: 2)
    case "M1 Max":   return s(32, 16, 512, "LPDDR5-6400", 400, "TSMC 5 nm", "57 billion", slc: 48, pkgs: 4, p: 4, e: 2)
    case "M1 Ultra": return s(64, 32, 1024, "LPDDR5-6400", 800, "TSMC 5 nm", "114 billion", slc: 96, pkgs: 8, p: 4, e: 2)
    case "M2":       return s(10, 16, 128, "LPDDR5-6400", 100, "TSMC 5 nm (2nd gen)", "20 billion")
    case "M2 Pro":   return s(19, 16, 256, "LPDDR5-6400", 200, "TSMC 5 nm (2nd gen)", "40 billion")
    case "M2 Max":   return s(38, 16, 512, "LPDDR5-6400", 400, "TSMC 5 nm (2nd gen)", "67 billion")
    case "M2 Ultra": return s(76, 32, 1024, "LPDDR5-6400", 800, "TSMC 5 nm (2nd gen)", "134 billion")
    case "M3":       return s(10, 16, 128, "LPDDR5-6400", 100, "TSMC 3 nm", "25 billion")
    case "M3 Pro":   return s(18, 16, 192, "LPDDR5-6400", 150, "TSMC 3 nm", "37 billion")
    // Binned Max parts have a narrower memory bus as well as fewer GPU cores.
    case "M3 Max":   return gpuCores > 0 && gpuCores <= 30 ? s(40, 16, 384, "LPDDR5-6400", 300, "TSMC 3 nm", "92 billion")
                                                           : s(40, 16, 512, "LPDDR5-6400", 400, "TSMC 3 nm", "92 billion")
    case "M3 Ultra": return s(80, 32, 1024, "LPDDR5-6400", 819, "TSMC 3 nm", "184 billion")
    case "M4":       return s(10, 16, 128, "LPDDR5X-7500", 120, "TSMC 3 nm (2nd gen)", "28 billion")
    case "M4 Pro":   return s(20, 16, 256, "LPDDR5X-8533", 273, "TSMC 3 nm (2nd gen)")
    case "M4 Max":   return gpuCores > 0 && gpuCores <= 32 ? s(40, 16, 384, "LPDDR5X-8533", 410, "TSMC 3 nm (2nd gen)")
                                                           : s(40, 16, 512, "LPDDR5X-8533", 546, "TSMC 3 nm (2nd gen)")
    default:         return Spec()
    }
}

// ------------------------------------------------------------------ layout preview (dev only)
/// `CHIPSCOPE_PREVIEW_CHIP="Apple M4 Max|6,6|4|40"`: brand | P-cluster sizes | E-cluster sizes | GPU cores,
/// optionally `|product name|port types` ("MacBook Air (M2, 2022)|USB-C,USB-C,MagSafe 3").
/// Draws the app for a chip this Mac isn't, to check layouts. Live counters won't match it (all —).
public func previewTopology(_ s: String) -> Topology? {
    let f = s.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard f.count == 4 || f.count == 6, let gpu = Int(f[3]) else { return nil }
    let sizes = { (x: String) in x.split(separator: ",").compactMap { Int($0) } }
    var t = Topology()
    t.chip = f[0]; t.model = "preview"; t.gpuCores = gpu
    t.spec = chipSpec(f[0], gpuCores: gpu)
    if f.count == 6 {
        let sides = portSides(f[4], types: f[5].split(separator: ",").map(String.init))
        t.board = BoardSpec(name: f[4], display: "preview", leftPorts: sides.left, rightPorts: sides.right)
    }
    var logical = 0
    for (type, list) in [("P", sizes(f[1])), ("E", sizes(f[2]))] {
        for (n, live) in list.enumerated() {
            let id = type == "E" ? (n == 0 ? "eclu" : "eclu\(n)") : "pclu\(n)"
            let slots = max(live, type == "E" ? t.spec.eSlots : t.spec.pSlots)
            let cores = (0..<slots).map { k -> CoreSlot in
                defer { if k < live { logical += 1 } }
                return CoreSlot(id: "\(id).\(k)", slot: k, logical: k < live ? logical : nil, cpuID: nil, ioreport: nil, energy: nil, fused: k >= live)
            }
            t.clusters.append(Cluster(id: id, label: "\(type)-cluster \(n)", short: type == "E" ? "E-cluster" + (n > 0 ? " \(n)" : "") : "P-cluster \(n)",
                                      type: type, ioreport: "", energy: "", amc: "", freqs: [], l2: 0, l2DeviceTree: nil, cores: cores))
        }
    }
    return t
}

// ------------------------------------------------------------------ the Mac around the chip

/// Board facts for any Apple Silicon Mac, read from the machine: the marketing name from the
/// device tree (/product product-name, e.g. "MacBook Pro (14-inch, 2021)"), the built-in panel
/// from CoreGraphics and the ports from the live port controllers. Only the side each port sits on
/// is a rule (it isn't exposed): see `portSides`.
public func readBoard(model: String) -> BoardSpec {
    var b = BoardSpec()
    let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
    if product != 0 {
        b.name = dataString(IOReg.prop(product, "product-name")) ?? ""
        IOObjectRelease(product)
    }
    if b.name.isEmpty { b.name = model }
    b.display = builtInDisplay()
    let sides = portSides(b.name, types: PortReader.read().map(\.type))
    b.leftPorts = sides.left; b.rightPorts = sides.right
    return b
}

/// "3024×1964 · 120 Hz" for the built-in panel, "" when there is none (or the lid is closed). The
/// size is already in the product name; CGDisplayScreenSize gives 14.1″ where Apple says 14.2″.
public func builtInDisplay() -> String {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return "" }
    guard let d = ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return "" }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
    // The panel's own resolution is the mode flagged native (kDisplayModeNativeFlag); the biggest
    // mode is a scaled backing size (3600×2338 on a 3024×1964 panel).
    let native = modes.filter { $0.ioFlags & 0x0200_0000 != 0 }.max { $0.pixelWidth < $1.pixelWidth }
    let hz = modes.map(\.refreshRate).max() ?? 0
    var parts: [String] = []
    if let native { parts.append("\(native.pixelWidth)×\(native.pixelHeight)") }
    if hz > 0 { parts.append("\(Int(hz.rounded())) Hz") }
    return parts.joined(separator: " · ")
}

/// Physical sides, by family (Apple's tech specs): MacBook Air - MagSafe (M2+) and the USB-C ports
/// on the left, headphone jack on the right. 13-inch MacBook Pro - USB-C left, headphone right.
/// 14/16-inch MacBook Pro - MagSafe, two USB-C and headphone left; SD, HDMI and any third USB-C
/// right. Which USB-C *number* is which socket isn't exposed, so USB-C sockets stay unnumbered.
/// Anything else (desktops, unknown names) returns empty sides and the view lists live ports.
public func portSides(_ name: String, types: [String]) -> (left: [String], right: [String]) {
    let usbc = types.filter { $0 == "USB-C" }.count
    let mag = types.contains("MagSafe 3") ? ["MagSafe 3"] : []
    let c = { (k: Int) in Array(repeating: "USB-C", count: max(0, k)) }
    if name.hasPrefix("MacBook Air") { return (mag + c(usbc), ["Headphone jack"]) }
    if name.hasPrefix("MacBook Pro (13-inch") { return (c(usbc), ["Headphone jack"]) }
    if name.hasPrefix("MacBook Pro") {
        return (mag + c(min(2, usbc)) + ["Headphone jack"],
                (types.contains("SD Card") ? ["SDXC card"] : []) + (types.contains("HDMI") ? ["HDMI"] : []) + c(usbc - 2))
    }
    return ([], [])
}
