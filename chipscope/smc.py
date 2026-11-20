"""System Management Controller (SMC) reader: fans, temperatures, power rails.

On Apple Silicon the SMC is a small coprocessor inside the SoC; macOS exposes
it through the AppleSMC user client, which any user may open read-only.
Each read is a round trip to that coprocessor, so we also time it.
"""
from __future__ import annotations

import ctypes as C
import struct
import time

from . import cf as F

KERNEL_INDEX_SMC = 2
CMD_READ_BYTES = 5
CMD_READ_INDEX = 8
CMD_READ_KEYINFO = 9


class _Vers(C.Structure):
    _fields_ = [("major", C.c_uint8), ("minor", C.c_uint8), ("build", C.c_uint8),
                ("reserved", C.c_uint8), ("release", C.c_uint16)]


class _PLimit(C.Structure):
    _fields_ = [("version", C.c_uint16), ("length", C.c_uint16), ("cpuPLimit", C.c_uint32),
                ("gpuPLimit", C.c_uint32), ("memPLimit", C.c_uint32)]


class _KeyInfo(C.Structure):
    _fields_ = [("dataSize", C.c_uint32), ("dataType", C.c_uint32), ("dataAttributes", C.c_uint8)]


class SMCKeyData(C.Structure):
    _fields_ = [("key", C.c_uint32), ("vers", _Vers), ("pLimitData", _PLimit), ("keyInfo", _KeyInfo),
                ("result", C.c_uint8), ("status", C.c_uint8), ("data8", C.c_uint8),
                ("data32", C.c_uint32), ("bytes", C.c_uint8 * 32)]


assert C.sizeof(SMCKeyData) == 80, C.sizeof(SMCKeyData)


def fourcc(s: str) -> int:
    return struct.unpack(">I", s.encode("latin-1"))[0]


def unfourcc(v: int) -> str:
    return struct.pack(">I", v).decode("latin-1")


def decode(dtype: str, raw: bytes):
    """Decode an SMC value. Returns a float/int, or None for types we don't know."""
    t = dtype.strip()
    try:
        if t == "flt":
            return struct.unpack("<f", raw[:4])[0]
        if t == "ui8" or t == "flag":
            return raw[0]
        if t == "ui16":
            return struct.unpack(">H", raw[:2])[0]
        if t == "ui32":
            return struct.unpack(">I", raw[:4])[0]
        if t == "si8":
            return struct.unpack(">b", raw[:1])[0]
        if t == "si16":
            return struct.unpack(">h", raw[:2])[0]
        if t == "sp78":
            return struct.unpack(">h", raw[:2])[0] / 256.0
        if t == "fpe2":
            return struct.unpack(">H", raw[:2])[0] / 4.0
        if t == "ioft":
            return struct.unpack("<Q", raw[:8])[0] / 65536.0
    except struct.error:
        return None
    return None


# Temperature keys whose block is known from the community map used by the
# open-source "Stats" app for M1 Pro/Max. Not from Apple: shown as "community map".
COMMUNITY_TEMP_MAP = {
    "Tp09": "E-core 1", "Tp0T": "E-core 2",
    "Tp01": "P-core 1", "Tp05": "P-core 2", "Tp0D": "P-core 3", "Tp0H": "P-core 4",
    "Tp0L": "P-core 5", "Tp0P": "P-core 6", "Tp0X": "P-core 7", "Tp0b": "P-core 8",
    "Tg05": "GPU 1", "Tg0D": "GPU 2", "Tg0L": "GPU 3", "Tg0T": "GPU 4",
}

KNOWN_KEYS = {
    "PSTR": ("System total power", "W"),
    "PDTR": ("Power in (DC)", "W"),
    "PPBR": ("Battery power", "W"),
    "FNum": ("Fan count", ""),
    "B0AV": ("Battery voltage", "mV"),
    "B0AC": ("Battery current", "mA"),
}


class SMC:
    def __init__(self):
        svc = F.IOServiceGetMatchingService(0, F.IOServiceMatching(b"AppleSMC"))
        if not svc:
            raise RuntimeError("AppleSMC not found")
        conn = C.c_uint32()
        rc = F.IOServiceOpen(svc, F.mach_task_self_.value, 0, C.byref(conn))
        F.IOObjectRelease(svc)
        if rc != 0:
            raise RuntimeError(f"IOServiceOpen(AppleSMC) failed: {rc:#x}")
        self.conn = conn.value
        self._info: dict = {}

    def close(self):
        if self.conn:
            F.IOServiceClose(self.conn)
            self.conn = 0

    def _call(self, inp: SMCKeyData) -> SMCKeyData:
        out = SMCKeyData()
        size = C.c_size_t(C.sizeof(out))
        rc = F.IOConnectCallStructMethod(self.conn, KERNEL_INDEX_SMC, C.byref(inp), C.sizeof(inp),
                                         C.byref(out), C.byref(size))
        if rc != 0:
            raise OSError(f"SMC call failed {rc:#x}")
        return out

    def key_count(self) -> int:
        v = self.read_raw("#KEY")
        return struct.unpack(">I", v[1][:4])[0] if v else 0

    def key_at(self, i: int) -> str:
        inp = SMCKeyData(data8=CMD_READ_INDEX, data32=i)
        return unfourcc(self._call(inp).key)

    def key_info(self, key: str):
        info = self._info.get(key)
        if info is None:
            inp = SMCKeyData(key=fourcc(key), data8=CMD_READ_KEYINFO)
            out = self._call(inp)
            if out.result != 0:
                return None
            info = (out.keyInfo.dataSize, unfourcc(out.keyInfo.dataType))
            self._info[key] = info
        return info

    def read_raw(self, key: str):
        info = self.key_info(key)
        if not info:
            return None
        size, dtype = info
        inp = SMCKeyData(key=fourcc(key), data8=CMD_READ_BYTES)
        inp.keyInfo.dataSize = size
        out = self._call(inp)
        if out.result != 0:
            return None
        return dtype, bytes(out.bytes[:size])

    def read(self, key: str):
        """(value, type, read_time_us) or None."""
        t0 = time.perf_counter_ns()
        r = self.read_raw(key)
        us = (time.perf_counter_ns() - t0) / 1000
        if r is None:
            return None
        return decode(r[0], r[1]), r[0].strip(), us

    def enumerate(self) -> list:
        """Every SMC key with its type, decoded value and read latency."""
        out = []
        for i in range(self.key_count()):
            try:
                k = self.key_at(i)
                r = self.read(k)
            except OSError:
                continue
            if r is None:
                continue
            v, t, us = r
            out.append({"key": k, "type": t, "value": v, "us": round(us, 2)})
        return out


def classify(key: str, value, dtype: str):
    """Rough category of an SMC key by Apple's naming convention (first letter)."""
    if key in KNOWN_KEYS:
        return "power" if key.startswith("P") else "battery" if key.startswith("B") else "fan"
    c = key[0]
    if c == "T" and isinstance(value, float) and 1.0 < value < 130.0:
        return "temperature"
    if c == "F":
        return "fan"
    if c == "P" and dtype == "flt":
        return "power"
    if c == "V" and dtype == "flt":
        return "voltage"
    if c == "I" and dtype == "flt":
        return "current"
    return "other"
