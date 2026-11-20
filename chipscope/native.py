"""The native helper: build it, run probes, run load generators, build the latency atlas."""
from __future__ import annotations

import json
import os
import re
import statistics
import subprocess
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "native" / "probe.m"
BIN = ROOT / "build" / "chipscope-probe"
CACHE = ROOT / ".cache"
SSD_FILE = CACHE / "ssd-probe.bin"
PROBES_FILE = CACHE / "probes.json"

FRAMEWORKS = ["Foundation", "Metal", "Vision", "CoreGraphics"]


def ensure_built() -> Path:
    if BIN.exists() and BIN.stat().st_mtime >= SRC.stat().st_mtime:
        return BIN
    BIN.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["clang", "-O2", "-Wall", "-fobjc-arc", *sum((["-framework", f] for f in FRAMEWORKS), []),
           str(SRC), "-o", str(BIN)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("building the native helper failed (is Xcode CLT installed?):\n" + r.stderr[-2000:])
    return BIN


def run_lines(args: list, timeout: float = 120):
    """Yield JSON objects printed by the helper."""
    p = subprocess.Popen([str(BIN), *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    t_end = time.monotonic() + timeout
    try:
        for line in p.stdout:
            line = line.strip()
            if line.startswith("{"):
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
            if time.monotonic() > t_end:
                break
    finally:
        if p.poll() is None:
            p.terminate()
        p.wait(timeout=5)


# ------------------------------------------------------------------ loads
LOADS = {
    "cpu-p": dict(label="P-cores", args=["burn", "cpu", "--qos", "p", "--threads", "6"]),
    "cpu-e": dict(label="E-cores", args=["burn", "cpu", "--qos", "e", "--threads", "2"]),
    "mem": dict(label="Memory bandwidth", args=["burn", "mem", "--threads", "4"]),
    "gpu": dict(label="GPU", args=["burn", "gpu"]),
    "ane": dict(label="Neural Engine", args=["burn", "ane"]),
    "ssd": dict(label="SSD reads", args=["burn", "ssd", "--file", str(SSD_FILE)]),
}


class Loads:
    def __init__(self):
        self.procs: dict = {}
        self.lock = threading.Lock()

    def start(self, kind: str, seconds: int = 20) -> dict:
        if kind not in LOADS:
            raise KeyError(kind)
        seconds = max(3, min(int(seconds), 60))
        ensure_built()
        CACHE.mkdir(exist_ok=True)
        with self.lock:
            old = self.procs.get(kind)
            if old and old["proc"].poll() is None:
                return self.status()
            p = subprocess.Popen([str(BIN), *LOADS[kind]["args"], "--seconds", str(seconds)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.procs[kind] = dict(proc=p, until=time.time() + seconds, started=time.time())
        return self.status()

    def stop(self, kind: str | None = None) -> dict:
        with self.lock:
            for k, v in list(self.procs.items()):
                if kind in (None, k) and v["proc"].poll() is None:
                    v["proc"].terminate()
        return self.status()

    def status(self) -> dict:
        out = {}
        for k, v in self.procs.items():
            if v["proc"].poll() is None:
                out[k] = dict(until=v["until"], started=v["started"])
        return out


# ------------------------------------------------------------------ probes
def ping_gateway() -> dict:
    try:
        r = subprocess.run(["route", "-n", "get", "default"], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r"gateway:\s*(\S+)", r)
        if not m:
            return {}
        gw = m.group(1)
        out = subprocess.run(["ping", "-c", "8", "-i", "0.2", "-t", "5", gw], capture_output=True, text=True,
                             timeout=10).stdout
        mm = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)/", out)
        if mm:
            return dict(kind="gateway_ping", p10=float(mm.group(1)) * 1000, p50=float(mm.group(2)) * 1000,
                        p90=float(mm.group(3)) * 1000, unit="us")
    except (subprocess.SubprocessError, OSError):
        pass
    return {}


STEPS = ["misc", "memlat-p", "memlat-e", "c2c", "ssd", "gpu", "ane", "net"]


class ProbeRunner:
    """Runs the probe suite in the background; results stream to listeners and land in probes.json."""

    def __init__(self, on_event):
        self.on_event = on_event
        self.running = None
        self.results = self._load()

    @staticmethod
    def _load() -> dict:
        try:
            return json.loads(PROBES_FILE.read_text())
        except (OSError, ValueError):
            return {}

    def start(self, context: dict) -> bool:
        if self.running:
            return False
        self.running = "starting"
        threading.Thread(target=self._run, args=(context,), daemon=True).start()
        return True

    def _step(self, name):
        self.running = name
        self.on_event(dict(type="probe", step=name, status="running"))

    def _run(self, context: dict):
        res = dict(t=time.time(), load=context.get("load"))
        try:
            ensure_built()
            CACHE.mkdir(exist_ok=True)
            self._step("misc")
            res["misc"] = {d["kind"]: d for d in run_lines(["misc"], 30) if "kind" in d}
            for q in ("p", "e"):
                self._step(f"memlat-{q}")
                pts = []
                for d in run_lines(["memlat", "--qos", q, "--max-mb", "256" if q == "p" else "128"], 120):
                    if "size" in d:
                        pts.append([d["size"], d["ns"], d["cpu"]])
                        self.on_event(dict(type="probe", step=f"memlat-{q}", point=pts[-1]))
                res[f"memlat_{q}"] = pts
            self._step("c2c")
            pairs, drops = [], {}
            for d in run_lines(["c2c", "--seconds", "4"], 30):
                if "a" in d:
                    pairs.append([d["a"], d["b"], d["ns"]])
                elif "drop" in d:
                    drops[d["drop"]] = drops.get(d["drop"], 0) + 1
            res["c2c"] = dict(pairs=pairs, drops=drops)
            self._step("ssd")
            res["ssd"] = next((d for d in run_lines(["ssdlat", "--file", str(SSD_FILE), "--mb", "128", "--n", "400"],
                                                    60) if "kind" in d), {})
            self._step("gpu")
            res["gpu"] = {d["kind"]: d for d in run_lines(["gpulat", "--n", "200"], 60) if "kind" in d}
            self._step("ane")
            res["ane"] = next((d for d in run_lines(["anelat", "--n", "20"], 60) if "kind" in d), {})
            self._step("net")
            res["net"] = ping_gateway()
            res["sensors"] = context.get("sensors", {})
            res["ok"] = True
        except Exception as e:  # report, keep the previous results
            res["error"] = str(e)
        if res.get("ok"):
            self.results = res
            PROBES_FILE.write_text(json.dumps(res))
        self.running = None
        self.on_event(dict(type="probe", step="done", ok=bool(res.get("ok")), error=res.get("error")))


# ------------------------------------------------------------------ atlas
def band(points, lo, hi):
    """Median latency of memlat points with lo <= size <= hi (sizes in bytes)."""
    v = [ns for size, ns, _ in points if lo <= size <= hi]
    return statistics.median(v) if v else None


def cluster_of_logical(topo: dict) -> dict:
    m = {}
    for cl in topo["clusters"]:
        for c in cl["cores"]:
            if not c["fused"]:
                m[c["logical"]] = (cl["id"], cl["type"])
    return m


def c2c_classes(topo: dict, pairs: list) -> dict:
    """Group ping-pong pairs: same cluster / across P clusters / P<->E / E<->E. Values: one-way ns."""
    m = cluster_of_logical(topo)
    g = {"same_p": [], "cross_p": [], "p_e": [], "same_e": []}
    for a, b, ns in pairs:
        if a not in m or b not in m:
            continue
        (ca, ta), (cb, tb) = m[a], m[b]
        if ca == cb:
            g["same_e" if ta == "E" else "same_p"].append(ns)
        elif ta == tb == "P":
            g["cross_p"].append(ns)
        else:
            g["p_e"].append(ns)
    return {k: dict(p50=statistics.median(v), p10=_pct(v, 10), p90=_pct(v, 90), n=len(v)) if v else None
            for k, v in g.items()}


def _pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(len(s) * p / 100))]


def c2c_matrix(pairs: list) -> dict:
    cells = {}
    for a, b, ns in pairs:
        cells.setdefault(f"{min(a, b)}-{max(a, b)}", []).append(ns)
    return {k: dict(p50=statistics.median(v), n=len(v)) for k, v in cells.items()}


def atlas(topo: dict, probes: dict, passive: dict) -> dict:
    """Every component placed by how long a signal takes to reach it (ns), with the method used."""
    c = topo["caches"]
    spec = topo.get("spec", {})
    slc = spec.get("slc_bytes", 24 << 20)
    e = []

    def add(id_, label, ns, group, block, how, src="measured", spread=None):
        if ns is None:
            return
        e.append(dict(id=id_, label=label, ns=round(ns, 3), group=group, block=block, how=how, src=src,
                      spread=spread))

    p, ee = probes.get("memlat_p") or [], probes.get("memlat_e") or []
    if p:
        add("p_l1", "P-core L1 cache", band(p, 0, c["p_l1d"] // 2), "cache", "pclu0",
            f"pointer chase, sets ≤ {c['p_l1d'] // 2048} KiB")
        add("p_l2", "P-cluster L2 cache", band(p, c["p_l1d"] * 4, c["p_l2"] // 4), "cache", "pclu0",
            f"pointer chase, sets {c['p_l1d'] * 4 // 1024} KiB–{c['p_l2'] // 4 >> 20} MiB")
        add("slc", "System level cache (SLC)", band(p, c["p_l2"], int(slc * 0.75)), "memory", "slc",
            f"pointer chase, sets {c['p_l2'] >> 20}–{int(slc * 0.75) >> 20} MiB (between L2 and SLC size)")
        add("dram", "DRAM (LPDDR5)", band(p, slc * 4, 1 << 40), "memory", "dram",
            f"pointer chase, sets ≥ {slc * 4 >> 20} MiB (includes TLB misses)")
    if ee:
        add("e_l1", "E-core L1 cache", band(ee, 0, c["e_l1d"] // 2), "cache", "eclu",
            f"pointer chase on E-core, sets ≤ {c['e_l1d'] // 2048} KiB")
        add("e_l2", "E-cluster L2 cache", band(ee, c["e_l1d"] * 4, c["e_l2"] // 4), "cache", "eclu",
            f"pointer chase on E-core, sets {c['e_l1d'] * 4 // 1024} KiB–{c['e_l2'] // 4 >> 20} MiB")
    cc = c2c_classes(topo, (probes.get("c2c") or {}).get("pairs", []))
    names = dict(same_p="Core ↔ core, same P-cluster", cross_p="Core ↔ core, across P-clusters",
                 p_e="P-core ↔ E-core", same_e="E-core ↔ E-core")
    blocks = dict(same_p="pclu0", cross_p="fabric", p_e="fabric", same_e="eclu")
    for k, v in cc.items():
        if v:
            add(f"c2c_{k}", names[k], v["p50"], "cores", blocks[k],
                f"cache-line ping-pong, one way, {v['n']} runs", spread=[v["p10"], v["p90"]])
    misc = probes.get("misc") or {}
    if misc.get("timer_read"):
        add("timer", "System timer read", misc["timer_read"]["p50"], "os", "pclu0", "mach_absolute_time() loop")
    if misc.get("syscall"):
        add("syscall", "Kernel (one syscall)", misc["syscall"]["p50"], "os", "pclu0", "getppid() loop")
    if misc.get("thread_wake"):
        t = misc["thread_wake"]
        add("wake", "Wake another thread", t["p50"] * 1000, "os", "pclu0", "semaphore ping-pong, one way",
            spread=[t["p10"] * 1000, t["p90"] * 1000])
    ssd = probes.get("ssd") or {}
    if ssd.get("p50"):
        add("nand", "SSD NAND read (16 KiB)", ssd["p50"] * 1000, "storage", "ans",
            "uncached random pread, 128 MiB file", spread=[ssd["p10"] * 1000, ssd["p90"] * 1000])
    if passive.get("disk_life_us"):
        add("nand_life", "SSD read, lifetime average", passive["disk_life_us"] * 1000, "storage", "ans",
            "driver counters: total read time / reads (passive)")
    g = probes.get("gpu") or {}
    if g.get("gpu_roundtrip"):
        add("gpu_rt", "GPU round trip (empty dispatch)", g["gpu_roundtrip"]["p50"] * 1000, "accel", "gpu",
            "Metal commit → completed", spread=[g["gpu_roundtrip"]["p10"] * 1000, g["gpu_roundtrip"]["p90"] * 1000])
    if g.get("gpu_exec"):
        add("gpu_exec", "GPU kernel execution", g["gpu_exec"]["p50"] * 1000, "accel", "gpu", "GPU timestamps")
    a = probes.get("ane") or {}
    if a.get("p50"):
        add("ane", "Neural Engine via Vision", a["p50"] * 1e6, "accel", "ane",
            "VNClassifyImageRequest round trip (includes CPU pre/post)",
            spread=[a["p10"] * 1e6, a["p90"] * 1e6])
    sens = dict(probes.get("sensors") or {}, **(passive.get("sensors") or {}))
    sname = dict(smc="SMC sensor key", hid_battery="Battery gas gauge", hid_pmu="PMU die sensor",
                 hid_ssd="NAND temperature sensor")
    sblock = dict(smc="smc", hid_battery="battery", hid_pmu="pmu", hid_ssd="ans")
    for k, v in sens.items():
        if v and k in sname:
            add(f"sensor_{k}", sname[k], v["p50"] * 1000, "sensors", sblock[k], f"read round trip, {v['n']} sensors")
    n = probes.get("net") or {}
    if n.get("p50"):
        add("wifi", "Wi-Fi → router and back", n["p50"] * 1000, "network", "wifi", "ping to default gateway",
            spread=[n["p10"] * 1000, n["p90"] * 1000])
    e.sort(key=lambda x: x["ns"])
    return dict(entries=e, c2c=c2c_matrix((probes.get("c2c") or {}).get("pairs", [])),
                c2c_drops=(probes.get("c2c") or {}).get("drops", {}),
                memlat_p=p, memlat_e=ee, t=probes.get("t"), load=probes.get("load"))
