"""Physical ports: what is plugged in, which way power flows, and the USB-PD contract.

Sources (no sudo): the AppleHPM port controllers (one IOService per port, e.g. "Port-USB-C@2"),
their CC (USB Power Delivery) transport child, which carries the identity the far end and the
cable report, and AppleSmartBattery's PortControllerInfo (per-port PD state; its PDO/RDO
fields describe power coming IN to the Mac from a charger).
"""
from __future__ import annotations

from . import cf as F

PORT_CLASSES = ("AppleTCControllerType10", "AppleTCControllerType11", "AppleHDMIPortController", "AppleSDXCSlot")

# USB-IF vendor IDs (a short list; anything else is shown as hex).
VENDORS = {0x05AC: "Apple", 0x22B8: "Motorola", 0x18D1: "Google", 0x04E8: "Samsung", 0x2717: "Xiaomi",
           0x2A70: "OnePlus", 0x12D1: "Huawei", 0x17EF: "Lenovo", 0x291A: "Anker", 0x050D: "Belkin",
           0x0BDA: "Realtek", 0x2109: "VIA Labs", 0x8087: "Intel", 0x1D5C: "Fresco Logic", 0x0B05: "ASUS",
           0x413C: "Dell", 0x03F0: "HP", 0x046D: "Logitech", 0x0781: "SanDisk", 0x0BC2: "Seagate", 0x1058: "Western Digital"}


def pdo(x: int) -> dict:
    """Decode a USB-PD Power Data Object."""
    x &= 0xFFFFFFFF
    kind = x >> 30
    if kind == 0:  # fixed supply: volts in 50 mV units (bits 19:10), amps in 10 mA units (bits 9:0)
        v, a = ((x >> 10) & 0x3FF) * 0.05, (x & 0x3FF) * 0.01
        return dict(kind="fixed", volts=round(v, 2), amps=round(a, 2), watts=round(v * a, 1))
    if kind == 3:  # programmable (PPS): 100 mV / 50 mA units
        return dict(kind="pps", vmin=round(((x >> 8) & 0xFF) * 0.1, 1), vmax=round(((x >> 17) & 0xFF) * 0.1, 1),
                    amps=round((x & 0x7F) * 0.05, 2))
    return dict(kind="other", raw=hex(x))


def rdo_position(x: int) -> int:
    """Which PDO (1-based) a Request Data Object selected."""
    return ((x & 0xFFFFFFFF) >> 28) & 0x7


def vendor_name(vid) -> str | None:
    if not isinstance(vid, int) or vid <= 0:
        return None
    return VENDORS.get(vid, f"vendor {vid:#06x}")


def read_ports(battery_pci: list | None = None, adapter: dict | None = None) -> list:
    out = []
    for cls in PORT_CLASSES:
        for s in F.services(cls):
            try:
                p = F.registry_props(s)
                kids = F.children(s, depth=2)
            finally:
                F.IOObjectRelease(s)
            port = dict(
                id=f"{p.get('PortTypeDescription', cls)}@{p.get('PortNumber', '?')}",
                type=p.get("PortTypeDescription") or cls, number=p.get("PortNumber"),
                connected=bool(p.get("ConnectionActive")), transports=list(p.get("TransportsActive") or []),
                supported=list(p.get("TransportsSupported") or []), orientation=p.get("PlugOrientation"),
                connections=p.get("ConnectionCount"), usb_data=bool(p.get("IOAccessoryUSBActive")) and
                any(t in (p.get("TransportsActive") or []) for t in ("USB2", "USB3", "CIO")),
                superspeed=bool(p.get("IOAccessoryUSBSuperSpeedActive")),
                power_in=False, device=None, cable=None,
            )
            for kcls, kp, _ in kids:
                if kcls == "IOPortFeaturePowerIn":
                    port["power_in"] = bool(kp.get("Active"))
                if kcls == "IOPortTransportStateCC" and port["connected"]:
                    vid, pid = kp.get("Vendor ID (SOP)"), kp.get("Product ID (SOP)")
                    if vid:
                        port["device"] = dict(vendor=vendor_name(vid), vid=vid, pid=pid)
                if kp.get("Product Type Description") and "Cable" in str(kp.get("Product Type Description")) and port["connected"]:
                    port["cable"] = dict(kind=kp.get("Product Type Description"), vendor=vendor_name(kp.get("Vendor ID")))
            out.append(port)
    attach_pd(out, battery_pci or [], adapter or {})
    for port in out:
        if port["connected"]:
            # Direction comes from the PD controller, not the "Power In" feature flag: on this Mac
            # that flag reads No even while a charger on the same port is charging it (checked).
            port["power"] = "into Mac" if port.get("pd_sink") else ("out to device" if "CC" in port["transports"] else None)
    out.sort(key=lambda x: (x["type"], x["number"] or 0))
    return out


def attach_pd(ports: list, pci: list, adapter: dict):
    """Attach PortControllerInfo entries to ports by matching attach counts (index order is undocumented)."""
    pd_ports = [p for p in ports if p["type"] in ("USB-C", "MagSafe 3")]
    used = set()
    for p in pd_ports:
        for i, c in enumerate(pci):
            if i in used or not isinstance(c, dict):
                continue
            if c.get("PortControllerAttachCount") == p.get("connections"):
                used.add(i)
                p["pd_index"] = i
                # PortControllerMaxPower (mW) is non-zero only while this port is sinking power.
                p["pd_sink"] = bool(p["connected"] and (c.get("PortControllerMaxPower") or 0) > 0)
                if p["pd_sink"]:
                    p["charger"] = charger_info(adapter, c)
                break


def charger_info(adapter: dict, c: dict) -> dict:
    """The charger's offer menu and the contract the Mac chose (AppleSmartBattery AdapterDetails)."""
    menu = [dict(volts=m.get("MaxVoltage", 0) / 1000, amps=m.get("MaxCurrent", 0) / 1000,
                 watts=round(m.get("MaxVoltage", 0) * m.get("MaxCurrent", 0) / 1e6, 1)) for m in adapter.get("UsbHvcMenu") or []]
    idx = adapter.get("UsbHvcHvcIndex")
    chosen = menu[idx] if isinstance(idx, int) and 0 <= idx < len(menu) else None
    return dict(kind=adapter.get("Description"), rated_w=adapter.get("Watts") or round((c.get("PortControllerMaxPower") or 0) / 1000),
                menu=menu, chosen=chosen)
