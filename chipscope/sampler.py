"""Turns raw counters into frames the UI draws: 4/s for the chip, 1/s for the board."""
from __future__ import annotations

import collections
import statistics
import threading
import time
import traceback

from . import system as S
from .hid import HIDTemps, place
from .ioreport import IOReport, residency_summary
from .smc import COMMUNITY_TEMP_MAP, SMC, classify
from .topology import AGENTS, FABRIC, sysctl_raw


def loadavg():
    raw = sysctl_raw("vm.loadavg")
    if not raw or len(raw) < 24:
        return None
    a = [int.from_bytes(raw[i * 4:(i + 1) * 4], "little") for i in range(3)]
    scale = int.from_bytes(raw[16:24], "little") or 2048
    return [round(x / scale, 2) for x in a]


def build_chip_frame(topo: dict, raw: dict, gpu: dict) -> dict:
    """Chip-level frame from one IOReport delta (+ AGX stats). Pure function: unit-tested."""
    e = raw["energy"]
    amc = raw["amc"]
    cores, clusters = {}, {}
    for cl in topo["clusters"]:
        busy_l = []
        for c in cl["cores"]:
            if c["fused"]:
                continue
            states = raw["core_states"].get(c["ioreport"], [])
            busy, mhz, share = residency_summary(states, cl["freqs"])
            busy_l.append(busy)
            cores[c["id"]] = dict(busy=round(busy, 4), mhz=round(mhz) if mhz else None,
                                  w=round(e.get(c["energy"], 0.0), 4),
                                  states=[[n, round(s, 4)] for n, s in share if s > 0.0005])
        cbusy, cmhz, _ = residency_summary(raw["cluster_states"].get(cl["ioreport"], []), cl["freqs"])
        clusters[cl["id"]] = dict(
            busy=round(sum(busy_l) / len(busy_l), 4) if busy_l else 0.0,
            active=round(cbusy, 4), mhz=round(cmhz) if cmhz else None,
            w_cores=round(e.get(f"{cl['energy']}_CPU", 0.0), 4),
            w_shared=round(e.get(f"{cl['energy']}_CPM", 0.0), 4),
        )

    gbusy, gmhz, gshare = residency_summary(raw["gpu_states"], topo["gpu"]["freqs"])
    gpu_f = dict(busy=round(gbusy, 4), mhz=round(gmhz) if gmhz else None,
                 w=round(e.get("GPU Energy", e.get("GPU0", 0.0)), 4), w_sram=round(e.get("GPU SRAM0", 0.0), 4),
                 util=(gpu.get("device") / 100) if gpu.get("device") is not None else None,
                 renderer=gpu.get("renderer"), tiler=gpu.get("tiler"), mem_used=gpu.get("mem_used"),
                 states=[[n, round(s, 4)] for n, s in gshare if s > 0.0005])

    bw = {}
    for a in AGENTS:
        rd, wr = amc.get(f"{a} RD"), amc.get(f"{a} WR")
        if rd is None and wr is None:
            continue
        bw[a] = [round(rd or 0), round(wr or 0), round(amc.get(f"{a} DCS RD", 0)), round(amc.get(f"{a} DCS WR", 0))]
    fabric = {}
    for f, meta in FABRIC.items():
        rd, wr = amc.get(f"{f} RD"), amc.get(f"{f} WR")
        if rd is None:
            continue
        members = sum(sum(bw.get(m, [0, 0])[:2]) for m in meta["members"])
        fabric[f] = [round(rd), round(wr or 0), round(members)]
    agents_total = sum(v[0] + v[1] for v in bw.values())
    dram_rd, dram_wr = amc.get("DCS RD", 0.0), amc.get("DCS WR", 0.0)
    slc_hit = None
    if agents_total > 50e6:  # too noisy to say anything below ~50 MB/s
        slc_hit = round(max(0.0, min(1.0, 1 - (dram_rd + dram_wr) / agents_total)), 4)

    return dict(
        cores=cores, clusters=clusters, gpu=gpu_f,
        cpu_w=round(e.get("CPU Energy", 0.0), 4),
        ane=dict(w=round(e.get("ANE0", 0.0), 4)),
        media=dict(ave_w=round(e.get("AVE0", 0.0), 4), isp_w=round(e.get("ISP0", 0.0), 4),
                   msr_w=round(e.get("MSR0", 0.0), 4)),
        mem=dict(dram_w=round(e.get("DRAM0", 0.0), 4), amcc_w=round(e.get("AMCC0", 0.0), 4),
                 dcs_w=round(e.get("DCS0", 0.0), 4), dram_rd=round(dram_rd), dram_wr=round(dram_wr),
                 agents_total=round(agents_total), slc_hit=slc_hit),
        bw=bw, fabric=fabric,
        pcie=dict(w=round(sum(v for k, v in e.items() if "PCIe" in k or "apciec" in k), 4),
                  bps=round(sum(raw["pcie"].values()))),
    )


class Sampler:
    def __init__(self, topo: dict, hz: float = 4.0, history_s: int = 600):
        self.topo = topo
        self.hz = hz
        self.ior = IOReport()
        self.smc = self._try(SMC)
        self.hid = self._try(HIDTemps)
        self.history = collections.deque(maxlen=int(hz * history_s))
        self.cond = threading.Condition()
        self.latest = None
        self.seq = 0
        self.slow: dict = {}
        self.sensors: dict = {"smc": [], "hid": [], "t": 0}
        self.selfcpu = S.SelfCPU()
        self.errors: dict = {}
        self._stop = threading.Event()
        self._prev_disk = None
        self._prev_net = None
        self._prev_slow_t = None
        self._smc_keys = None

    @staticmethod
    def _try(cls):
        try:
            return cls()
        except Exception:
            return None

    def start(self):
        for target in (self._fast_loop, self._slow_loop, self._sweep_loop):
            threading.Thread(target=target, daemon=True).start()

    def stop(self):
        self._stop.set()

    # ------------------------------------------------------------ loops
    def _fast_loop(self):
        period = 1.0 / self.hz
        nxt = time.monotonic() + period
        while not self._stop.is_set():
            time.sleep(max(0.0, nxt - time.monotonic()))
            nxt += period
            try:
                raw = self.ior.sample()
                frame = build_chip_frame(self.topo, raw, S.gpu_stats())
                frame["t"] = round(time.time(), 3)
                frame["dt"] = round(raw["dt"], 4)
                frame["board"] = self.slow
                self._publish(frame)
            except Exception:
                self.errors["fast"] = traceback.format_exc(limit=3)

    def _publish(self, frame):
        with self.cond:
            self.seq += 1
            frame["seq"] = self.seq
            self.latest = frame
            self.history.append(frame)
            self.cond.notify_all()

    def _slow_loop(self):
        while not self._stop.is_set():
            t0 = time.monotonic()
            try:
                self.slow = self._board()
            except Exception:
                self.errors["slow"] = traceback.format_exc(limit=3)
            self._stop.wait(max(0.1, 1.0 - (time.monotonic() - t0)))

    def _board(self) -> dict:
        now = time.monotonic()
        dt = (now - self._prev_slow_t) if self._prev_slow_t else 1.0
        self._prev_slow_t = now
        disk = S.disk_stats()
        disk_r = S.disk_rates(self._prev_disk, disk, dt) if self._prev_disk else {}
        self._prev_disk = disk
        net = S.net_counters()
        net_r = {}
        if self._prev_net:
            for k, (rx, tx) in net.items():
                if k in self._prev_net and not k.startswith("lo"):
                    prx, ptx = self._prev_net[k]
                    if rx - prx or tx - ptx:
                        net_r[k] = [round((rx - prx) / dt), round((tx - ptx) / dt)]
        self._prev_net = net
        out = dict(
            battery=S.battery(), disk=disk_r, net=net_r, mem=S.memory(), procs=S.processes(12),
            load=loadavg(), self_cpu=round(self.selfcpu.percent(), 1),
        )
        if self.smc:
            out.update(self._smc_fast())
        hid = self.sensors.get("hid") or []
        if hid:
            by = collections.defaultdict(list)
            for h in hid:
                by[h["place"]].append(h["c"])
            out["hid"] = {k: dict(max=max(v), avg=round(sum(v) / len(v), 1)) for k, v in by.items()}
        return out

    def _smc_fast(self) -> dict:
        fans, temps, power = [], {}, {}
        n = self.smc.read("FNum")
        for i in range(int(n[0]) if n and n[0] else 0):
            ac, mn, mx = (self.smc.read(f"F{i}{s}") for s in ("Ac", "Mn", "Mx"))
            fans.append(dict(rpm=round(ac[0]) if ac else None, min=round(mn[0]) if mn else None,
                             max=round(mx[0]) if mx else None))
        for k, label in COMMUNITY_TEMP_MAP.items():
            r = self.smc.read(k)
            if r and isinstance(r[0], float) and 0 < r[0] < 130:
                temps[k] = dict(c=round(r[0], 1), label=label)
        for k in ("PSTR", "PPBR", "PDTR"):
            r = self.smc.read(k)
            if r and r[0] is not None:
                power[k] = round(r[0], 2)
        return dict(fans=fans, smc_temps=temps, smc_power=power)

    def _sweep_loop(self):
        """Slow full sweeps: every SMC sensor key (~0.4 ms each) and every HID temperature."""
        while not self._stop.is_set():
            try:
                self.sensors = self._sweep()
            except Exception:
                self.errors["sweep"] = traceback.format_exc(limit=3)
            self._stop.wait(15)

    def _sweep(self) -> dict:
        smc_rows = []
        if self.smc:
            if self._smc_keys is None:
                self._smc_keys = [r["key"] for r in self.smc.enumerate()
                                  if classify(r["key"], r["value"], r["type"]) != "other"]
            for k in self._smc_keys:
                try:
                    r = self.smc.read(k)
                except OSError:
                    continue
                if r is None:
                    continue
                v, t, us = r
                cat = classify(k, v, t)
                if cat == "other":
                    continue
                smc_rows.append(dict(key=k, type=t, value=round(v, 3) if isinstance(v, float) else v, us=round(us, 1),
                                     cat=cat, label=COMMUNITY_TEMP_MAP.get(k)))
        hid_rows = []
        if self.hid:
            seen = collections.Counter()
            for name, c, us in self.hid.read():
                seen[name] += 1
                label = name if seen[name] == 1 else f"{name} #{seen[name]}"
                hid_rows.append(dict(name=label, c=c, us=us, place=place(name)))
        return dict(smc=smc_rows, hid=hid_rows, t=time.time())

    # ------------------------------------------------------------ readers
    def wait_next(self, after_seq: int, timeout: float = 5.0):
        with self.cond:
            self.cond.wait_for(lambda: self.seq > after_seq, timeout=timeout)
            return self.latest

    def sensor_latency(self) -> dict:
        """Median read time per sensor family, from the last sweep."""
        out = {}
        smc = [r["us"] for r in self.sensors.get("smc", [])]
        if smc:
            out["smc"] = dict(p50=statistics.median(smc), n=len(smc))
        by = collections.defaultdict(list)
        for h in self.sensors.get("hid", []):
            key = "hid_battery" if h["place"] == "battery" else "hid_ssd" if h["place"] == "ssd" else "hid_pmu"
            by[key].append(h["us"])
        for k, v in by.items():
            out[k] = dict(p50=statistics.median(v), n=len(v))
        return out
