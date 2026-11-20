"""Named temperature sensors from the HID event system (no sudo).

These carry human-ish names such as "PMU tdie3" or "NAND CH0 temp", which
tell us roughly where on the board they sit. IOHIDEventSystemClient is a
private IOKit API: everything here fails soft (empty list) if it changes.
"""
from __future__ import annotations

import ctypes as C
import time

from . import cf as F

V = C.c_void_p
k = F.iokit

kHIDPage_AppleVendor = 0xFF00
kHIDUsage_AppleVendor_TemperatureSensor = 0x0005
kIOHIDEventTypeTemperature = 15


def _fn(name, res, args):
    f = getattr(k, name)
    f.restype = res
    f.argtypes = args
    return f


try:
    ClientCreate = _fn("IOHIDEventSystemClientCreate", V, [V])
    ClientSetMatching = _fn("IOHIDEventSystemClientSetMatching", C.c_int, [V, V])
    ClientCopyServices = _fn("IOHIDEventSystemClientCopyServices", V, [V])
    ServiceCopyProperty = _fn("IOHIDServiceClientCopyProperty", V, [V, V])
    ServiceCopyEvent = _fn("IOHIDServiceClientCopyEvent", V, [V, C.c_int64, C.c_int32, C.c_int64])
    EventGetFloatValue = _fn("IOHIDEventGetFloatValue", C.c_double, [V, C.c_int32])
    _OK = True
except AttributeError:
    _OK = False


class HIDTemps:
    def __init__(self):
        self.client = None
        self.services = []   # (name, service ref)
        if not _OK:
            return
        self.client = ClientCreate(None)
        if not self.client:
            return
        match = F.cfdict({"PrimaryUsagePage": kHIDPage_AppleVendor,
                          "PrimaryUsage": kHIDUsage_AppleVendor_TemperatureSensor})
        ClientSetMatching(self.client, match)
        arr = ClientCopyServices(self.client)
        if not arr:
            return
        for i in range(F.CFArrayGetCount(arr)):
            svc = F.CFArrayGetValueAtIndex(arr, i)
            name_ref = ServiceCopyProperty(svc, F.cfstr("Product"))
            name = F.str_of(name_ref) if name_ref else f"sensor {i}"
            if name_ref:
                F.CFRelease(name_ref)
            self.services.append((name, svc))
        self._arr = arr  # keep the array (and its services) alive

    def read(self) -> list:
        """[(name, celsius, read_us)] for every sensor that answers."""
        out = []
        field = kIOHIDEventTypeTemperature << 16
        for name, svc in self.services:
            t0 = time.perf_counter_ns()
            ev = ServiceCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0)
            us = (time.perf_counter_ns() - t0) / 1000
            if not ev:
                continue
            v = EventGetFloatValue(ev, field)
            F.CFRelease(ev)
            if -40 < v < 150:
                out.append((name, round(v, 2), round(us, 2)))
        return out


def place(name: str) -> str:
    """Best-effort component for a HID sensor name (from its Apple name only)."""
    n = name.lower()
    if "nand" in n:
        return "ssd"
    if "battery" in n or "gas gauge" in n:
        return "battery"
    if "tdie" in n or "tdev" in n or "tcal" in n or "pmu" in n:
        return "soc"
    if "wifi" in n or "wlan" in n:
        return "wifi"
    return "board"
