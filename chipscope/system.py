"""Board-level readers: battery/power, SSD, network, unified memory, processes, GPU stats."""
from __future__ import annotations

import ctypes as C
import os
import re
import resource
import subprocess
import time

from . import cf as F
from .topology import sysctl_int, sysctl_raw

_GetParent = F._fn(F.iokit, "IORegistryEntryGetParentEntry", C.c_int, [C.c_uint32, C.c_char_p, C.POINTER(C.c_uint32)])
_GetClass = F._fn(F.iokit, "IOObjectGetClass", C.c_int, [C.c_uint32, C.c_char_p])


def _class_of(entry: int) -> str:
    buf = C.create_string_buffer(128)
    _GetClass(entry, buf)
    return buf.value.decode()


def gpu_stats() -> dict:
    """AGX PerformanceStatistics (what Activity Monitor's GPU history uses)."""
    for p in F.class_props("IOAccelerator", "PerformanceStatistics"):
        if p:
            return dict(
                device=p.get("Device Utilization %"), renderer=p.get("Renderer Utilization %"),
                tiler=p.get("Tiler Utilization %"), mem_used=p.get("In use system memory"),
                mem_alloc=p.get("Alloc system memory"),
            )
    return {}


_BATT_KEYS = ("Voltage", "Amperage", "CurrentCapacity", "MaxCapacity", "IsCharging", "ExternalConnected",
              "Temperature", "CycleCount", "PowerTelemetryData", "AppleRawMaxCapacity", "DesignCapacity",
              "AdapterDetails", "TimeRemaining", "FullyCharged")


def battery() -> dict:
    svcs = F.services("AppleSmartBattery")
    if not svcs:
        return {}
    s = svcs[0]
    try:
        raw = {k: F.registry_prop(s, k) for k in _BATT_KEYS}
    finally:
        for x in svcs:
            F.IOObjectRelease(x)
    tel = raw.get("PowerTelemetryData") or {}
    adapter = raw.get("AdapterDetails") or {}
    amps = raw.get("Amperage")
    if isinstance(amps, int) and amps > 2**63:
        amps -= 2**64
    volts = raw.get("Voltage")
    return dict(
        percent=raw.get("CurrentCapacity"), charging=raw.get("IsCharging"), plugged=raw.get("ExternalConnected"),
        volts=volts / 1000 if volts else None, amps=amps / 1000 if isinstance(amps, int) else None,
        temp_c=raw.get("Temperature") / 100 if raw.get("Temperature") else None,
        cycles=raw.get("CycleCount"),
        health=(raw.get("AppleRawMaxCapacity") / raw.get("DesignCapacity"))
        if raw.get("AppleRawMaxCapacity") and raw.get("DesignCapacity") else None,
        sys_in_w=tel.get("SystemPowerIn", 0) / 1000 if tel else None,
        sys_load_w=tel.get("SystemLoad", 0) / 1000 if tel else None,
        batt_w=tel.get("BatteryPower", 0) / 1000 if tel else None,
        adapter_w=adapter.get("Watts"), minutes_left=raw.get("TimeRemaining"),
    )


def disk_stats() -> dict:
    """Cumulative stats of the internal NVMe SSD's block driver."""
    total = dict(rd_bytes=0, wr_bytes=0, rd_ops=0, wr_ops=0, rd_ns=0, wr_ns=0)
    found = False
    for s in F.services("IOBlockStorageDriver"):
        try:
            parent = C.c_uint32()
            internal = False
            if _GetParent(s, b"IOService", C.byref(parent)) == 0 and parent.value:
                internal = "NVMe" in _class_of(parent.value)
                F.IOObjectRelease(parent.value)
            if not internal:
                continue
            st = F.registry_prop(s, "Statistics") or {}
            found = True
            total["rd_bytes"] += st.get("Bytes (Read)", 0)
            total["wr_bytes"] += st.get("Bytes (Write)", 0)
            total["rd_ops"] += st.get("Operations (Read)", 0)
            total["wr_ops"] += st.get("Operations (Write)", 0)
            total["rd_ns"] += st.get("Total Time (Read)", 0)
            total["wr_ns"] += st.get("Total Time (Write)", 0)
        finally:
            F.IOObjectRelease(s)
    return total if found else {}


def disk_rates(prev: dict, cur: dict, dt: float) -> dict:
    if not prev or not cur:
        return {}
    d = {k: cur[k] - prev[k] for k in cur}
    return dict(
        rd_bps=d["rd_bytes"] / dt, wr_bps=d["wr_bytes"] / dt,
        rd_iops=d["rd_ops"] / dt, wr_iops=d["wr_ops"] / dt,
        rd_lat_us=(d["rd_ns"] / d["rd_ops"] / 1000) if d["rd_ops"] else None,
        wr_lat_us=(d["wr_ns"] / d["wr_ops"] / 1000) if d["wr_ops"] else None,
        life_rd_lat_us=(cur["rd_ns"] / cur["rd_ops"] / 1000) if cur["rd_ops"] else None,
    )


_NET_RE = re.compile(r"^(\S+)\s+\d+\s+<Link#\d+>")


def net_counters() -> dict:
    """{iface: (rx_bytes, tx_bytes)} from netstat link rows."""
    out = subprocess.run(["netstat", "-ibn"], capture_output=True, text=True, timeout=5).stdout
    return parse_netstat(out)


def parse_netstat(text: str) -> dict:
    res = {}
    lines = text.splitlines()
    if not lines:
        return res
    head = lines[0].split()
    try:
        ib, ob = head.index("Ibytes"), head.index("Obytes")
    except ValueError:
        return res
    for line in lines[1:]:
        if not _NET_RE.match(line):
            continue
        parts = line.split()
        # A link row with no Address column has one field fewer.
        shift = 0 if len(parts) == len(head) else -1
        try:
            res[parts[0]] = (int(parts[ib + shift]), int(parts[ob + shift]))
        except (ValueError, IndexError):
            continue
    return res


_VM_RE = re.compile(r'^"?([^:"]+)"?:\s+(\d+)\.?$')


def parse_vm_stat(text: str) -> dict:
    page = 16384
    m = re.search(r"page size of (\d+) bytes", text)
    if m:
        page = int(m.group(1))
    vals = {}
    for line in text.splitlines()[1:]:
        mm = _VM_RE.match(line.strip())
        if mm:
            vals[mm.group(1).strip()] = int(mm.group(2))
    g = lambda k: vals.get(k, 0) * page  # noqa: E731
    return dict(
        page=page,
        free=g("Pages free"), active=g("Pages active"), inactive=g("Pages inactive"),
        speculative=g("Pages speculative"), wired=g("Pages wired down"),
        compressed=g("Pages occupied by compressor"), file_backed=g("File-backed pages"),
        anonymous=g("Anonymous pages"), purgeable=g("Pages purgeable"),
        pageins=vals.get("Pageins", 0), pageouts=vals.get("Pageouts", 0),
        swapins=vals.get("Swapins", 0), swapouts=vals.get("Swapouts", 0),
    )


def memory() -> dict:
    out = subprocess.run(["vm_stat"], capture_output=True, text=True, timeout=5).stdout
    vm = parse_vm_stat(out)
    raw = sysctl_raw("vm.swapusage")
    if raw and len(raw) >= 24:
        total, avail, used = (int.from_bytes(raw[i:i + 8], "little") for i in (0, 8, 16))
        vm.update(swap_total=total, swap_used=used)
    vm["pressure_level"] = sysctl_int("kern.memorystatus_vm_pressure_level")
    vm["free_percent"] = sysctl_int("kern.memorystatus_level")
    vm["total"] = sysctl_int("hw.memsize")
    # "App memory" as Activity Monitor shows it ~ anonymous - purgeable.
    vm["app"] = max(vm["anonymous"] - vm["purgeable"], 0)
    return vm


def parse_ps(text: str, top: int = 12) -> list:
    rows = []
    for line in text.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        try:
            pid, pcpu, rss = int(parts[0]), float(parts[1]), int(parts[2]) * 1024
        except ValueError:
            continue
        name = os.path.basename(parts[3].strip()) or parts[3].strip()
        rows.append([pid, name, pcpu, rss])
    rows.sort(key=lambda r: -r[2])
    return rows[:top]


def processes(top: int = 12) -> list:
    out = subprocess.run(["ps", "-Ao", "pid=,pcpu=,rss=,comm="], capture_output=True, text=True, timeout=5).stdout
    return parse_ps(out, top)


class SelfCPU:
    """chipscope's own CPU use, so the UI can say how much it adds to what it shows."""

    def __init__(self):
        self._last = self._now()

    @staticmethod
    def _now():
        r = resource.getrusage(resource.RUSAGE_SELF)
        c = resource.getrusage(resource.RUSAGE_CHILDREN)
        return time.monotonic(), r.ru_utime + r.ru_stime, c.ru_utime + c.ru_stime

    def percent(self) -> float:
        now = self._now()
        dt = max(now[0] - self._last[0], 1e-3)
        pct = 100 * (now[1] - self._last[1]) / dt
        self._last = now
        return pct
