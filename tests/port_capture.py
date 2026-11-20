"""Capture what changes when something is plugged into a port.

    /usr/bin/python3 -m tests.port_capture [--wait 180]

Takes 5 samples of every port node, PortControllerInfo, SMC sensor key, USB device and battery
telemetry; waits until a port's ConnectionActive flips (plug or unplug); waits 8 s for USB-PD to
settle; samples again; prints only what changed. Serial numbers are never printed.
"""
import argparse
import json
import plistlib
import statistics
import subprocess
import sys
import time

from chipscope.smc import SMC, classify

SKIP = ("IOPowerManagement", "IOGeneralInterest", "IORegistryEntryID", "busy", "Serial", "serial", "UUID",
        "IOReportLegend", "IOInterrupt", "EvtBuffer", "sessionID", "IOUserClientCreator", "ClientPID")


def ioreg(*args):
    out = subprocess.run(["ioreg", "-a", *args], capture_output=True).stdout
    return plistlib.loads(out) if out else []


def flatten(obj, path="", out=None):
    out = {} if out is None else out
    if isinstance(obj, dict):
        name = obj.get("IORegistryEntryName")
        base = f"{path}/{name}" if name else path
        for k, v in obj.items():
            if k == "IORegistryEntryChildren" or any(s in k for s in SKIP):
                continue
            flatten(v, f"{base}.{k}", out)
        for i, c in enumerate(obj.get("IORegistryEntryChildren", [])):
            flatten(c, base, out)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            flatten(v, f"{path}[{i}]", out)
    else:
        out[path] = obj.hex() if isinstance(obj, bytes) else obj
    return out


def ports_state():
    st = {}
    for cls in ("AppleTCControllerType10", "AppleTCControllerType11", "AppleHDMIPortController", "AppleSDXCSlot"):
        for node in ioreg("-r", "-c", cls, "-l", "-w0", "-d", "4"):
            st.update(flatten(node, cls))
    return st


def active_ports():
    act = {}
    for cls in ("AppleTCControllerType10", "AppleTCControllerType11"):
        for node in ioreg("-r", "-c", cls, "-w0", "-d", "1"):
            # all three USB-C ports share the name "Port-USB-C": key by name + port number
            act[f'{node.get("IORegistryEntryName")}@{node.get("PortNumber")}'] = node.get("ConnectionActive")
    return act


def snapshot(smc, keys):
    s = {}
    s.update(ports_state())
    batt = (ioreg("-r", "-n", "AppleSmartBattery", "-w0") or [{}])[0]
    for k in ("PortControllerInfo", "PowerTelemetryData", "AdapterDetails", "ExternalConnected", "IsCharging"):
        s.update(flatten(batt.get(k), f"battery.{k}"))
    for node in ioreg("-p", "IOUSB", "-l", "-w0"):
        s.update(flatten(node, "usb"))
    for k in keys:
        try:
            r = smc.read(k)
        except OSError:
            continue
        if r and isinstance(r[0], (int, float)):
            s[f"smc.{k}"] = r[0]
    return s


def sample(smc, keys, n=5, gap=0.5):
    snaps = []
    for _ in range(n):
        snaps.append(snapshot(smc, keys))
        time.sleep(gap)
    return snaps


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait", type=int, default=180)
    a = ap.parse_args()
    smc = SMC()
    keys = [r["key"] for r in smc.enumerate() if classify(r["key"], r["value"], r["type"]) != "other"]
    print(f"watching {len(keys)} SMC keys + port/USB/battery nodes", flush=True)
    before = sample(smc, keys)
    start = active_ports()
    print("ports now:", json.dumps(start), flush=True)
    for k, v in start.items():
        if v:
            print(f"already connected: {k} ->", {kk: vv for kk, vv in before[-1].items() if k.split("@")[0] in kk and
                                                 any(t in kk for t in ("Transports", "Orientation", "Active", "Current"))})
    t_end = time.time() + a.wait
    changed = None
    while time.time() < t_end:
        now = active_ports()
        if now != start:
            changed = {k: (start.get(k), v) for k, v in now.items() if start.get(k) != v}
            break
        time.sleep(0.5)
    if not changed:
        print("no port changed state within", a.wait, "s")
        return 1
    print("PORT CHANGE:", json.dumps(changed), flush=True)
    time.sleep(8)  # USB-PD negotiation + charging ramp
    after = sample(smc, keys)

    def stats(snaps, k):
        v = [s.get(k) for s in snaps]
        return v

    allk = sorted(set().union(*before, *after))
    print("\n--- non-numeric / structural changes ---")
    for k in allk:
        b, f = stats(before, k), stats(after, k)
        if any(isinstance(x, (int, float)) and not isinstance(x, bool) for x in b + f) and not k.startswith(("usb", "battery.PortControllerInfo")):
            continue
        if b[-1] != f[-1]:
            print(f"{k}: {b[-1]!r} -> {f[-1]!r}")
    print("\n--- numeric shifts (beyond before-noise) ---")
    for k in allk:
        b = [x for x in stats(before, k) if isinstance(x, (int, float)) and not isinstance(x, bool)]
        f = [x for x in stats(after, k) if isinstance(x, (int, float)) and not isinstance(x, bool)]
        if len(b) < 3 or len(f) < 3 or k.startswith(("usb", "battery.PortControllerInfo")):
            continue
        mb, mf = statistics.mean(b), statistics.mean(f)
        sd = statistics.pstdev(b)
        if abs(mf - mb) > max(4 * sd, 0.05, 0.1 * abs(mb)) and "Accumulated" not in k and "Count" not in k:
            print(f"{k}: {mb:.3f} -> {mf:.3f}  (noise sd {sd:.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
