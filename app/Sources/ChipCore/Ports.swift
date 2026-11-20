import Foundation
import IOKit

public struct PDO: Hashable {
    public var volts: Double; public var amps: Double; public var watts: Double
    public init(volts: Double, amps: Double, watts: Double) { self.volts = volts; self.amps = amps; self.watts = watts }
}
public struct Charger { public var kind: String; public var ratedW: Int; public var menu: [PDO]; public var chosen: PDO? }

public struct MacPort: Identifiable {
    public var id: String            // "USB-C@2"
    public var type: String          // USB-C, MagSafe 3, HDMI, SD Card
    public var number: Int
    public var connected = false
    public var transports: [String] = []
    public var orientation: Int?
    public var connections = 0
    public var usbData = false, superSpeed = false
    public var vendor: String?, vendorID: Int?, productID: Int?
    public var cable: String?
    public var sink = false          // the Mac is drawing power through this port
    public var charger: Charger?
    public init(id: String, type: String, number: Int, connected: Bool = false, transports: [String] = [], connections: Int = 0) {
        self.id = id; self.type = type; self.number = number; self.connected = connected; self.transports = transports; self.connections = connections
    }
    public var direction: String? {
        guard connected else { return nil }
        return sink ? "into Mac" : transports.contains("CC") ? "out to device" : nil
    }
}

public let USB_VENDORS: [Int: String] = [0x05AC: "Apple", 0x22B8: "Motorola", 0x18D1: "Google", 0x04E8: "Samsung", 0x2717: "Xiaomi",
    0x2A70: "OnePlus", 0x12D1: "Huawei", 0x17EF: "Lenovo", 0x291A: "Anker", 0x050D: "Belkin", 0x0BDA: "Realtek", 0x2109: "VIA Labs",
    0x8087: "Intel", 0x0B05: "ASUS", 0x413C: "Dell", 0x03F0: "HP", 0x046D: "Logitech", 0x0781: "SanDisk", 0x0BC2: "Seagate", 0x1058: "Western Digital"]

public func vendorName(_ v: Int?) -> String? {
    guard let v, v > 0 else { return nil }
    return USB_VENDORS[v] ?? String(format: "vendor 0x%04X", v)
}

/// Decode a USB-PD fixed-supply Power Data Object (50 mV / 10 mA units).
public func decodePDO(_ raw: Int) -> PDO? {
    let x = UInt32(truncatingIfNeeded: raw)
    guard x >> 30 == 0 else { return nil }
    let v = Double((x >> 10) & 0x3FF) * 0.05, a = Double(x & 0x3FF) * 0.01
    return PDO(volts: v, amps: a, watts: (v * a * 10).rounded() / 10)
}

public enum PortReader {
    static let classes = ["AppleTCControllerType10", "AppleTCControllerType11", "AppleHDMIPortController", "AppleSDXCSlot"]

    public static func read() -> [MacPort] {
        var out: [MacPort] = []
        for cls in classes {
            IOReg.each(cls) { s in
                var p: [String: Any] = [:]
                for k in ["PortTypeDescription", "PortNumber", "ConnectionActive", "TransportsActive", "PlugOrientation", "ConnectionCount",
                          "IOAccessoryUSBActive", "IOAccessoryUSBSuperSpeedActive"] { if let v = IOReg.prop(s, k) { p[k] = v } }
                let connected = (p["ConnectionActive"] as? Bool) ?? false
                // Child nodes (identity, cable) only matter when something is plugged in.
                let kids = connected ? IOReg.children(s, depth: 2, keys: ["Vendor ID (SOP)", "Product ID (SOP)", "Product Type Description", "Vendor ID"]) : []
                let type = (p["PortTypeDescription"] as? String) ?? cls
                let num = (p["PortNumber"] as? NSNumber)?.intValue ?? 0
                var port = MacPort(id: "\(type)@\(num)", type: type, number: num)
                port.connected = (p["ConnectionActive"] as? Bool) ?? false
                port.transports = (p["TransportsActive"] as? [String]) ?? []
                port.orientation = (p["PlugOrientation"] as? NSNumber)?.intValue
                port.connections = (p["ConnectionCount"] as? NSNumber)?.intValue ?? 0
                port.usbData = ((p["IOAccessoryUSBActive"] as? Bool) ?? false) && port.transports.contains { ["USB2", "USB3", "CIO"].contains($0) }
                port.superSpeed = (p["IOAccessoryUSBSuperSpeedActive"] as? Bool) ?? false
                if port.connected {
                    for (kcls, kp) in kids {
                        if kcls == "IOPortTransportStateCC", let vid = (kp["Vendor ID (SOP)"] as? NSNumber)?.intValue {
                            port.vendorID = vid; port.vendor = vendorName(vid); port.productID = (kp["Product ID (SOP)"] as? NSNumber)?.intValue
                        }
                        if let d = kp["Product Type Description"] as? String, d.contains("Cable") {
                            port.cable = [vendorName((kp["Vendor ID"] as? NSNumber)?.intValue), d].compactMap { $0 }.joined(separator: " ")
                        }
                    }
                }
                out.append(port)
            }
        }
        let (pci, adapter) = BoardReader.batteryPD()
        attachPD(&out, pci: pci, adapter: adapter)
        return out.sorted { ($0.type, $0.number) < ($1.type, $1.number) }
    }

    /// Match PortControllerInfo entries to ports by attach count (index order is undocumented). A port is
    /// sinking power when its controller reports MaxPower > 0. (Its "Power In" feature flag reads No even
    /// while a charger on that port charges the Mac - checked on MacBookPro18,3.)
    public static func attachPD(_ ports: inout [MacPort], pci: [[String: Any]], adapter: [String: Any]) {
        var used = Set<Int>()
        for i in ports.indices where ["USB-C", "MagSafe 3"].contains(ports[i].type) {
            for (k, c) in pci.enumerated() where !used.contains(k) {
                guard (c["PortControllerAttachCount"] as? NSNumber)?.intValue == ports[i].connections else { continue }
                used.insert(k)
                let maxP = (c["PortControllerMaxPower"] as? NSNumber)?.intValue ?? 0
                ports[i].sink = ports[i].connected && maxP > 0
                if ports[i].sink {
                    let menu = ((adapter["UsbHvcMenu"] as? [[String: Any]]) ?? []).map { m -> PDO in
                        let v = ((m["MaxVoltage"] as? NSNumber)?.doubleValue ?? 0) / 1000, a = ((m["MaxCurrent"] as? NSNumber)?.doubleValue ?? 0) / 1000
                        return PDO(volts: v, amps: a, watts: (v * a * 10).rounded() / 10)
                    }
                    let idx = (adapter["UsbHvcHvcIndex"] as? NSNumber)?.intValue ?? -1
                    ports[i].charger = Charger(kind: (adapter["Description"] as? String) ?? "charger",
                                               ratedW: (adapter["Watts"] as? NSNumber)?.intValue ?? maxP / 1000,
                                               menu: menu, chosen: menu.indices.contains(idx) ? menu[idx] : nil)
                }
                break
            }
        }
    }
}
