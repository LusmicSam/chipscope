"""What is inside this Mac: discovered from the device tree, sysctl and IOKit.

Every fact carries a `src` so the UI can say where it came from:
  "device tree" / "sysctl" / "IOKit" / "IOReport"  - read from this machine
  "Apple spec"                                     - Apple's published spec for this model
  "community"                                      - reverse-engineering notes, unverified here
"""
from __future__ import annotations

import ctypes as C
import json
import plistlib
import re
import struct
import subprocess

from . import cf as F

libc = F.libc
libc.sysctlbyname.argtypes = [C.c_char_p, C.c_void_p, C.POINTER(C.c_size_t), C.c_void_p, C.c_size_t]
libc.sysctlbyname.restype = C.c_int


def sysctl_raw(name: str):
    size = C.c_size_t(0)
    if libc.sysctlbyname(name.encode(), None, C.byref(size), None, 0) != 0:
        return None
    buf = C.create_string_buffer(size.value)
    if libc.sysctlbyname(name.encode(), buf, C.byref(size), None, 0) != 0:
        return None
    return buf.raw[: size.value]


def sysctl_int(name: str):
    raw = sysctl_raw(name)
    if raw is None:
        return None
    return int.from_bytes(raw, "little", signed=True)


def sysctl_str(name: str):
    raw = sysctl_raw(name)
    return raw.rstrip(b"\0").decode() if raw is not None else None


def _ioreg(*args) -> list:
    out = subprocess.run(["ioreg", "-a", *args], capture_output=True, timeout=20).stdout
    return plistlib.loads(out) if out else []


def _u32(b) -> int:
    if isinstance(b, (bytes, bytearray)):
        return int.from_bytes(b[:4].ljust(4, b"\0"), "little")
    return int(b)


def _str(b) -> str:
    if isinstance(b, (bytes, bytearray)):
        return b.rstrip(b"\0").decode("latin-1")
    return str(b)


def freq_table(blob) -> list:
    """pmgr voltage-states blob -> [MHz, ...] (pairs of u32 Hz, u32 mV)."""
    if not blob:
        return []
    v = struct.unpack("<%dI" % (len(blob) // 4), blob)
    return [v[i] // 1_000_000 for i in range(0, len(v), 2)]


# On-chip agents seen by the memory controller ("AMC Stats / Perf Counters").
# Names are Apple's; descriptions marked guess=True are our reading of the name.
AGENTS = {
    "PCPU0": dict(label="P-cluster 0", block="pclu0", kind="cpu"),
    "PCPU1": dict(label="P-cluster 1", block="pclu1", kind="cpu"),
    "ECPU": dict(label="E-cluster", block="eclu", kind="cpu"),
    "GFX": dict(label="GPU port A", block="gpu", kind="gpu"),
    "GFX1": dict(label="GPU port B", block="gpu", kind="gpu"),
    "ANE0": dict(label="Neural Engine", block="ane", kind="ane"),
    "ANS": dict(label="SSD controller (Apple NVMe)", block="ans", kind="io"),
    "PCIE LN": dict(label="PCIe (Wi-Fi/BT, SD card)", block="pcie", kind="io"),
    "ATC0": dict(label="USB-C / Thunderbolt 0", block="atc", kind="io"),
    "ATC1": dict(label="USB-C / Thunderbolt 1", block="atc", kind="io"),
    "ATC2": dict(label="USB-C / Thunderbolt 2", block="atc", kind="io"),
    "ATC3": dict(label="USB-C / Thunderbolt 3", block="atc", kind="io", guess=True),
    "DISP": dict(label="Built-in display engine", block="disp", kind="display"),
    "EXT DISP0": dict(label="External display engine 0", block="extdisp", kind="display"),
    "EXT DISP1": dict(label="External display engine 1", block="extdisp", kind="display"),
    "ISP": dict(label="Camera image processor", block="isp", kind="media"),
    "VDEC": dict(label="Video decoder", block="media", kind="media"),
    "VENC0": dict(label="Video encoder", block="media", kind="media"),
    "STRM CODEC": dict(label="Stream codec", block="media", kind="media", guess=True),
    "JPG0": dict(label="JPEG codec 0", block="media", kind="media"),
    "JPG1": dict(label="JPEG codec 1", block="media", kind="media"),
    "MSR0": dict(label="Scaler / rotator (MSR)", block="media", kind="media", guess=True),
}

# Fabric ports. Which agents feed which port is checked live (sum check in the UI).
FABRIC = {
    "AFC": dict(label="CPU fabric (coherent)", members=["PCPU0", "PCPU1", "ECPU"]),
    "AFR_A": dict(label="GPU fabric A", members=["GFX"]),
    "AFR_B": dict(label="GPU fabric B", members=["GFX1"]),
    "AF_I": dict(label="I/O + media fabric",
                 members=[a for a in AGENTS if AGENTS[a]["kind"] in ("io", "display", "media", "ane")]),
}


def cpus() -> list:
    """CPU cores from the device tree, plus fused-off slots inferred from gaps."""
    tree = _ioreg("-l", "-p", "IODeviceTree", "-n", "cpus", "-r", "-d", "2")
    kids = []
    for node in tree:
        kids.extend(node.get("IORegistryEntryChildren", []))
    cores = []
    for c in kids:
        name = c.get("IORegistryEntryName", "")
        if not name.startswith("cpu"):
            continue
        reg = c.get("reg")
        slot = None
        if isinstance(reg, (bytes, bytearray)) and len(reg) >= 4:
            slot = _u32(reg) & 0xFF
        cores.append(dict(
            name=name, cpu_id=_u32(c.get("cpu-id", 0)), logical=int(c.get("logical-cpu-id", -1)),
            type=_str(c.get("cluster-type", b"?")), cluster_id=_u32(c.get("cluster-id", 0)),
            slot=slot, l2_devicetree=_u32(c.get("l2-cache-size", 0)) if c.get("l2-cache-size") else None,
        ))
    cores.sort(key=lambda x: x["cpu_id"])
    return cores


def build() -> dict:
    """The static topology the UI draws."""
    cores = cpus()
    pmgr = (_ioreg("-r", "-d", "1", "-w0", "-n", "pmgr") or [{}])[0]
    e_freqs = freq_table(pmgr.get("voltage-states1-sram"))
    p_freqs = freq_table(pmgr.get("voltage-states5-sram"))
    g_freqs = freq_table(pmgr.get("voltage-states9"))

    # Clusters: device-tree cluster-id -> IOReport names.
    clusters = []
    p_index = 0
    for cid in sorted({c["cluster_id"] for c in cores}):
        members = [c for c in cores if c["cluster_id"] == cid]
        ctype = members[0]["type"]
        if ctype == "E":
            cl = dict(id="eclu", label="E-cluster (efficiency)", type="E", ioreport="ECPU",
                      energy="EACC", amc="ECPU", core_prefix="ECPU0", freqs=e_freqs)
        else:
            cl = dict(id=f"pclu{p_index}", label=f"P-cluster {p_index} (performance)", type="P",
                      ioreport="PCPU" if p_index == 0 else f"PCPU{p_index}",
                      energy=f"PACC{p_index}", amc=f"PCPU{p_index}", core_prefix=f"PCPU{p_index}",
                      freqs=p_freqs)
            p_index += 1
        # L2 size from sysctl (the device tree says 8 MiB for the P-cluster, sysctl 12 MiB;
        # 12 MiB matches public M1 Pro analysis, so sysctl wins and the tree value is kept aside).
        cl["l2"] = sysctl_int("hw.perflevel1.l2cachesize" if ctype == "E" else "hw.perflevel0.l2cachesize")
        cl["l2_devicetree"] = members[0]["l2_devicetree"]
        cl["cluster_id"] = cid
        # Physical slots: present ones from the tree. A cluster's die slot count is
        # the larger of (highest slot + 1) and Apple's 4-core P-cluster design.
        present = sorted(m["slot"] for m in members if m["slot"] is not None)
        n_slots = max((present[-1] + 1) if present else len(members), 4 if ctype == "P" else 2)
        slot_cores = []
        for s in range(n_slots):
            m = next((x for x in members if x["slot"] == s), None)
            if m:
                slot_cores.append(dict(id=f"{cl['id']}.{s}", slot=s, logical=m["logical"], cpu_id=m["cpu_id"],
                                       ioreport=f"{cl['core_prefix']}{s}0", energy=f"{cl['energy']}_CPU{s}",
                                       fused=False))
            else:
                slot_cores.append(dict(id=f"{cl['id']}.{s}", slot=s, fused=True))
        cl["cores"] = slot_cores
        clusters.append(cl)

    gpu = (F.class_props("IOAccelerator") or [{}])[0]
    gpu_cores = int(gpu.get("gpu-core-count", 0) or 0)

    ssd = {}
    for p in F.class_props("IONVMeController"):
        if p.get("Model Number"):
            ssd = dict(model=p.get("Model Number", "").strip(), firmware=p.get("Firmware Revision", "").strip())

    chip = sysctl_str("machdep.cpu.brand_string") or "Apple Silicon"
    mem = sysctl_int("hw.memsize") or 0
    topo = dict(
        model=sysctl_str("hw.model"),
        chip=chip,
        memory_bytes=mem,
        clusters=clusters,
        caches=dict(
            p_l1d=sysctl_int("hw.perflevel0.l1dcachesize"), p_l1i=sysctl_int("hw.perflevel0.l1icachesize"),
            p_l2=sysctl_int("hw.perflevel0.l2cachesize"),
            e_l1d=sysctl_int("hw.perflevel1.l1dcachesize"), e_l1i=sysctl_int("hw.perflevel1.l1icachesize"),
            e_l2=sysctl_int("hw.perflevel1.l2cachesize"),
            line=sysctl_int("hw.cachelinesize"), page=sysctl_int("hw.pagesize"),
        ),
        gpu=dict(cores=gpu_cores, freqs=g_freqs, model=gpu.get("model")),
        ssd=ssd,
        agents=AGENTS,
        fabric=FABRIC,
        freqs=dict(E=e_freqs, P=p_freqs, GPU=g_freqs),
    )
    topo.update(spec_for(topo))
    return topo


def spec_for(topo: dict) -> dict:
    """Facts macOS does not expose, from Apple's published specs (marked as such)."""
    chip = topo["chip"]
    spec = {"spec": {}}
    if "M1 Pro" in chip:
        spec["spec"] = dict(
            src="Apple spec / public die analysis",
            gpu_die_cores=16, ane_cores=16, slc_bytes=24 * 1024 * 1024,
            mem_type="LPDDR5-6400", mem_bus_bits=256, mem_peak_bw=200e9,
            mem_packages=2, transistors="33.7 billion", process="TSMC 5 nm (N5)",
        )
    if topo.get("model") == "MacBookPro18,3":
        spec["board"] = dict(
            src="Apple spec (MacBook Pro 14-inch, 2021)",
            name='MacBook Pro 14" (2021)',
            ports=["Thunderbolt 4 (left)", "Thunderbolt 4 (left)", "MagSafe 3 (left)", "Headphone jack (left)",
                   "Thunderbolt 4 (right)", "HDMI (right)", "SDXC card (right)"],
            display="Liquid Retina XDR 14.2\" 3024×1964, 120 Hz",
            fans=2,
        )
    return spec


def wifi_info() -> dict:
    """Wi-Fi chip from system_profiler (slow, ~1 s; run once)."""
    try:
        out = subprocess.run(["system_profiler", "-json", "SPAirPortDataType"], capture_output=True,
                             timeout=20).stdout
        d = json.loads(out)
        ifs = d["SPAirPortDataType"][0]["spairport_airport_interfaces"]
        for i in ifs:
            card = i.get("spairport_wireless_card_type")
            if card:
                ids = re.search(r"\((0x[0-9A-Fa-f]+),\s*(0x[0-9A-Fa-f]+)\)", card)
                vendor = card
                if ids and ids.group(1).upper() == "0X14E4":
                    # Broadcom names its Wi-Fi chips after the PCI device id (0x4387 -> BCM4387).
                    vendor = f"Broadcom BCM{ids.group(2)[2:].upper()} (PCI {ids.group(1)}:{ids.group(2)})"
                return dict(card=vendor, firmware=i.get("spairport_wireless_firmware_version", ""),
                            phy=(i.get("spairport_current_network_information") or {}).get("spairport_network_phymode"),
                            channel=(i.get("spairport_current_network_information") or {}).get(
                                "spairport_network_channel"))
    except Exception:
        pass
    return {}
