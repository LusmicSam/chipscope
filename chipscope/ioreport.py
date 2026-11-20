"""IOReport sampler: the private counters Activity Monitor / powermetrics read.

Works without sudo. Each `sample()` returns the delta since the previous call,
already converted to rates: bytes/s for memory-controller traffic, watts for
the energy model, and state residencies for CPU cores / clusters / GPU.
"""
from __future__ import annotations

import ctypes as C
import time

from . import cf as F

V = C.c_void_p
io = C.CDLL("/usr/lib/libIOReport.dylib")


def _fn(name, res, args):
    f = getattr(io, name)
    f.restype = res
    f.argtypes = args
    return f


CopyChannelsInGroup = _fn("IOReportCopyChannelsInGroup", V, [V, V, C.c_uint64, C.c_uint64, C.c_uint64])
CopyAllChannels = _fn("IOReportCopyAllChannels", V, [C.c_uint64, C.c_uint64])
MergeChannels = _fn("IOReportMergeChannels", None, [V, V, V])
CreateSubscription = _fn("IOReportCreateSubscription", V, [V, V, C.POINTER(V), C.c_uint64, V])
CreateSamples = _fn("IOReportCreateSamples", V, [V, V, V])
CreateSamplesDelta = _fn("IOReportCreateSamplesDelta", V, [V, V, V])
ChannelGetGroup = _fn("IOReportChannelGetGroup", V, [V])
ChannelGetSubGroup = _fn("IOReportChannelGetSubGroup", V, [V])
ChannelGetChannelName = _fn("IOReportChannelGetChannelName", V, [V])
ChannelGetUnitLabel = _fn("IOReportChannelGetUnitLabel", V, [V])
ChannelGetFormat = _fn("IOReportChannelGetFormat", C.c_uint8, [V])
SimpleGetIntegerValue = _fn("IOReportSimpleGetIntegerValue", C.c_int64, [V, C.c_int32])
StateGetCount = _fn("IOReportStateGetCount", C.c_int32, [V])
StateGetNameForIndex = _fn("IOReportStateGetNameForIndex", V, [V, C.c_int32])
StateGetResidency = _fn("IOReportStateGetResidency", C.c_int64, [V, C.c_int32])

FMT_SIMPLE, FMT_STATE = 1, 2

GROUPS = [
    ("AMC Stats", "Perf Counters"),            # memory traffic per on-chip agent
    ("Energy Model", None),                     # energy per block / per core
    ("CPU Stats", "CPU Core Performance States"),
    ("CPU Stats", "CPU Complex Performance States"),
    ("GPU Stats", "GPU Performance States"),
    ("Bandwidth", None),                        # PCIe ports
]

ENERGY_SCALE = {"mJ": 1e-3, "uJ": 1e-6, "nJ": 1e-9}
BYTES_SCALE = {"B": 1, "KiB": 1024, "MiB": 1024 * 1024}


def list_channels() -> list:
    """Every (group, subgroup, channel, unit) the kernel exposes - for the Sensors view."""
    d = CopyAllChannels(0, 0)
    arr = F.CFDictionaryGetValue(d, F.cfstr("IOReportChannels"))
    out = []
    for i in range(F.CFArrayGetCount(arr)):
        ch = F.CFArrayGetValueAtIndex(arr, i)
        out.append((F.str_of(ChannelGetGroup(ch)), F.str_of(ChannelGetSubGroup(ch)),
                    F.str_of(ChannelGetChannelName(ch)), F.str_of(ChannelGetUnitLabel(ch))))
    F.CFRelease(d)
    return out


class IOReport:
    def __init__(self, groups=GROUPS):
        base = None
        for g, sg in groups:
            d = CopyChannelsInGroup(F.cfstr(g), F.cfstr(sg) if sg else None, 0, 0, 0)
            if not d:
                continue
            if base is None:
                base = d
            else:
                MergeChannels(base, d, None)
                F.CFRelease(d)
        if base is None:
            raise RuntimeError("IOReport returned no channels")
        self._chans = F.CFDictionaryCreateMutableCopy(None, 0, base)
        F.CFRelease(base)
        self._subbed = V()
        self._sub = CreateSubscription(None, self._chans, C.byref(self._subbed), 0, None)
        if not self._sub:
            raise RuntimeError("IOReport subscription failed")
        self._prev = CreateSamples(self._sub, self._subbed, None)
        self._prev_t = time.monotonic()
        self._key = F.cfstr("IOReportChannels")

    def sample(self) -> dict:
        cur = CreateSamples(self._sub, self._subbed, None)
        now = time.monotonic()
        dt = max(now - self._prev_t, 1e-3)
        delta = CreateSamplesDelta(self._prev, cur, None)
        F.CFRelease(self._prev)
        self._prev, self._prev_t = cur, now
        try:
            return parse_delta(delta, dt, self._key)
        finally:
            F.CFRelease(delta)


def parse_delta(delta, dt: float, key) -> dict:
    out = {"dt": dt, "amc": {}, "energy": {}, "core_states": {}, "cluster_states": {},
           "gpu_states": [], "pcie": {}}
    arr = F.CFDictionaryGetValue(delta, key)
    if not arr:
        return out
    for i in range(F.CFArrayGetCount(arr)):
        ch = F.CFArrayGetValueAtIndex(arr, i)
        fmt = ChannelGetFormat(ch)
        group = F.str_of(ChannelGetGroup(ch))
        name = F.str_of(ChannelGetChannelName(ch))
        if fmt == FMT_SIMPLE:
            unit = F.str_of(ChannelGetUnitLabel(ch))
            v = SimpleGetIntegerValue(ch, 0)
            if group == "AMC Stats":
                if unit == "B":
                    out["amc"][name] = v / dt
            elif group == "Energy Model":
                if "DTL" in name:          # per-DVFS-level split; not needed
                    continue
                s = ENERGY_SCALE.get(unit)
                if s is not None:
                    out["energy"][name] = v * s / dt
            elif group == "Bandwidth":
                out["pcie"][name] = v * BYTES_SCALE.get(unit, 1) / dt
        elif fmt == FMT_STATE:
            sub = F.str_of(ChannelGetSubGroup(ch))
            states = [(F.str_of(StateGetNameForIndex(ch, k)), StateGetResidency(ch, k))
                      for k in range(StateGetCount(ch))]
            if sub == "CPU Core Performance States":
                out["core_states"][name] = states
            elif sub == "CPU Complex Performance States":
                out["cluster_states"][name] = states
            elif sub == "GPU Performance States" and name == "GPUPH":
                out["gpu_states"] = states
    return out


IDLE_STATES = {"IDLE", "OFF", "DOWN"}


def residency_summary(states, freqs_mhz):
    """(busy fraction, average MHz while active, per-state share) from a residency list.

    Active states are mapped in order onto the pmgr frequency table. If the
    state count does not match the table, the MHz is None (we don't guess).
    """
    total = sum(r for _, r in states)
    if total <= 0:
        return 0.0, None, []
    active = [(n, r) for n, r in states if n not in IDLE_STATES]
    act_total = sum(r for _, r in active)
    busy = act_total / total
    mhz = None
    freqs = [f for f in freqs_mhz if f > 0] if freqs_mhz else []
    if active and act_total > 0 and freqs:
        if len(active) == len(freqs):
            mhz = sum(r * f for (_, r), f in zip(active, freqs)) / act_total
        elif len(active) > len(freqs):
            # More states than table rows (the M1 Pro GPU: P1..P15 vs 6 clocks).
            # Measured on this Mac: a 100% GPU load sits entirely in P6, so P1..P6
            # carry the 6 clocks and P7..P15 stay empty. Map whichever end holds
            # the residency, and report no clock if both ends do (never guess).
            n = len(freqs)
            head, rest = active[:n], active[n:]
            low, tail = active[:-n], active[-n:]
            if sum(r for _, r in rest) <= 0.01 * act_total:
                mhz = sum(r * f for (_, r), f in zip(head, freqs)) / max(sum(r for _, r in head), 1)
            elif sum(r for _, r in low) <= 0.01 * act_total:
                mhz = sum(r * f for (_, r), f in zip(tail, freqs)) / max(sum(r for _, r in tail), 1)
    share = [(n, r / total) for n, r in states]
    return busy, mhz, share
