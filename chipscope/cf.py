"""Thin ctypes bindings for CoreFoundation + IOKit, and a CF -> Python converter.

Only what chipscope needs. Everything here runs as the normal user (no sudo).
"""
from __future__ import annotations

import ctypes as C
import ctypes.util as U

V = C.c_void_p
UTF8 = 0x08000100

cf = C.CDLL(U.find_library("CoreFoundation"))
iokit = C.CDLL(U.find_library("IOKit"))
libc = C.CDLL(U.find_library("c"))


def _fn(lib, name, res, args):
    f = getattr(lib, name)
    f.restype = res
    f.argtypes = args
    return f


CFRelease = _fn(cf, "CFRelease", None, [V])
CFGetTypeID = _fn(cf, "CFGetTypeID", C.c_ulong, [V])
_TID = {
    "str": _fn(cf, "CFStringGetTypeID", C.c_ulong, [])(),
    "num": _fn(cf, "CFNumberGetTypeID", C.c_ulong, [])(),
    "dict": _fn(cf, "CFDictionaryGetTypeID", C.c_ulong, [])(),
    "arr": _fn(cf, "CFArrayGetTypeID", C.c_ulong, [])(),
    "data": _fn(cf, "CFDataGetTypeID", C.c_ulong, [])(),
    "bool": _fn(cf, "CFBooleanGetTypeID", C.c_ulong, [])(),
}
CFStringCreateWithCString = _fn(cf, "CFStringCreateWithCString", V, [V, C.c_char_p, C.c_uint32])
CFStringGetCString = _fn(cf, "CFStringGetCString", C.c_bool, [V, C.c_char_p, C.c_long, C.c_uint32])
CFStringGetLength = _fn(cf, "CFStringGetLength", C.c_long, [V])
CFNumberGetValue = _fn(cf, "CFNumberGetValue", C.c_bool, [V, C.c_int, V])
CFNumberIsFloatType = _fn(cf, "CFNumberIsFloatType", C.c_bool, [V])
CFNumberCreate = _fn(cf, "CFNumberCreate", V, [V, C.c_int, V])
CFDictionaryGetCount = _fn(cf, "CFDictionaryGetCount", C.c_long, [V])
CFDictionaryGetKeysAndValues = _fn(cf, "CFDictionaryGetKeysAndValues", None, [V, V, V])
CFDictionaryGetValue = _fn(cf, "CFDictionaryGetValue", V, [V, V])
CFDictionaryCreate = _fn(cf, "CFDictionaryCreate", V, [V, V, V, C.c_long, V, V])
CFDictionaryCreateMutableCopy = _fn(cf, "CFDictionaryCreateMutableCopy", V, [V, C.c_long, V])
CFArrayGetCount = _fn(cf, "CFArrayGetCount", C.c_long, [V])
CFArrayGetValueAtIndex = _fn(cf, "CFArrayGetValueAtIndex", V, [V, C.c_long])
CFDataGetLength = _fn(cf, "CFDataGetLength", C.c_long, [V])
CFDataGetBytePtr = _fn(cf, "CFDataGetBytePtr", V, [V])
CFBooleanGetValue = _fn(cf, "CFBooleanGetValue", C.c_bool, [V])

kCFTypeDictionaryKeyCallBacks = C.addressof(C.c_char.in_dll(cf, "kCFTypeDictionaryKeyCallBacks"))
kCFTypeDictionaryValueCallBacks = C.addressof(C.c_char.in_dll(cf, "kCFTypeDictionaryValueCallBacks"))

kCFNumberSInt32Type = 3
kCFNumberSInt64Type = 4
kCFNumberDoubleType = 13

# IOKit
IOServiceMatching = _fn(iokit, "IOServiceMatching", V, [C.c_char_p])
IOServiceNameMatching = _fn(iokit, "IOServiceNameMatching", V, [C.c_char_p])
IOServiceGetMatchingService = _fn(iokit, "IOServiceGetMatchingService", C.c_uint32, [C.c_uint32, V])
IOServiceGetMatchingServices = _fn(iokit, "IOServiceGetMatchingServices", C.c_int, [C.c_uint32, V, C.POINTER(C.c_uint32)])
IOIteratorNext = _fn(iokit, "IOIteratorNext", C.c_uint32, [C.c_uint32])
IOObjectRelease = _fn(iokit, "IOObjectRelease", C.c_int, [C.c_uint32])
IORegistryEntryCreateCFProperty = _fn(iokit, "IORegistryEntryCreateCFProperty", V, [C.c_uint32, V, V, C.c_uint32])
IORegistryEntryCreateCFProperties = _fn(iokit, "IORegistryEntryCreateCFProperties", C.c_int, [C.c_uint32, C.POINTER(V), V, C.c_uint32])
IOServiceOpen = _fn(iokit, "IOServiceOpen", C.c_int, [C.c_uint32, C.c_uint32, C.c_uint32, C.POINTER(C.c_uint32)])
IOServiceClose = _fn(iokit, "IOServiceClose", C.c_int, [C.c_uint32])
IOConnectCallStructMethod = _fn(iokit, "IOConnectCallStructMethod", C.c_int,
                                [C.c_uint32, C.c_uint32, V, C.c_size_t, V, C.POINTER(C.c_size_t)])
mach_task_self_ = C.c_uint32.in_dll(libc, "mach_task_self_")


_cfstr_cache: dict = {}


def cfstr(s: str):
    """A CFString for `s`. Cached forever (used for a small, fixed set of keys)."""
    r = _cfstr_cache.get(s)
    if r is None:
        r = CFStringCreateWithCString(None, s.encode(), UTF8)
        _cfstr_cache[s] = r
    return r


def str_of(ref) -> str:
    if not ref:
        return ""
    n = CFStringGetLength(ref) * 4 + 1
    buf = C.create_string_buffer(n)
    CFStringGetCString(ref, buf, n, UTF8)
    return buf.value.decode("utf-8", "replace")


def cfnum(v: int):
    x = C.c_int32(v)
    return CFNumberCreate(None, kCFNumberSInt32Type, C.byref(x))


def cfdict(pairs: dict):
    """Create an (owned) CFDictionary from {str: int}."""
    keys = (V * len(pairs))(*[cfstr(k) for k in pairs])
    vals = (V * len(pairs))(*[cfnum(v) for v in pairs.values()])
    return CFDictionaryCreate(None, keys, vals, len(pairs), kCFTypeDictionaryKeyCallBacks,
                              kCFTypeDictionaryValueCallBacks)


def to_py(ref, depth: int = 0):
    """Convert a CF object graph to Python (dict/list/str/int/float/bytes/bool)."""
    if not ref or depth > 12:
        return None
    t = CFGetTypeID(ref)
    if t == _TID["str"]:
        return str_of(ref)
    if t == _TID["num"]:
        if CFNumberIsFloatType(ref):
            d = C.c_double()
            CFNumberGetValue(ref, kCFNumberDoubleType, C.byref(d))
            return d.value
        i = C.c_int64()
        CFNumberGetValue(ref, kCFNumberSInt64Type, C.byref(i))
        return i.value
    if t == _TID["bool"]:
        return bool(CFBooleanGetValue(ref))
    if t == _TID["data"]:
        n = CFDataGetLength(ref)
        return C.string_at(CFDataGetBytePtr(ref), n)
    if t == _TID["arr"]:
        return [to_py(CFArrayGetValueAtIndex(ref, i), depth + 1) for i in range(CFArrayGetCount(ref))]
    if t == _TID["dict"]:
        n = CFDictionaryGetCount(ref)
        ks, vs = (V * n)(), (V * n)()
        CFDictionaryGetKeysAndValues(ref, ks, vs)
        out = {}
        for k, v in zip(ks, vs):
            key = to_py(k, depth + 1)
            out[key if isinstance(key, str) else repr(key)] = to_py(v, depth + 1)
        return out
    return None


def registry_props(service: int) -> dict:
    """All properties of an IORegistry entry as a Python dict."""
    p = V()
    if IORegistryEntryCreateCFProperties(service, C.byref(p), None, 0) != 0 or not p:
        return {}
    try:
        return to_py(p) or {}
    finally:
        CFRelease(p)


def registry_prop(service: int, key: str):
    r = IORegistryEntryCreateCFProperty(service, cfstr(key), None, 0)
    if not r:
        return None
    try:
        return to_py(r)
    finally:
        CFRelease(r)


def services(class_name: str) -> list:
    """io_service_t handles for every service of an IOKit class (caller releases)."""
    it = C.c_uint32()
    if IOServiceGetMatchingServices(0, IOServiceMatching(class_name.encode()), C.byref(it)) != 0:
        return []
    out = []
    while True:
        s = IOIteratorNext(it.value)
        if not s:
            break
        out.append(s)
    IOObjectRelease(it.value)
    return out


def class_props(class_name: str, key: str | None = None) -> list:
    """Properties (or one property) of every service of a class."""
    out = []
    for s in services(class_name):
        try:
            out.append(registry_prop(s, key) if key else registry_props(s))
        finally:
            IOObjectRelease(s)
    return out
