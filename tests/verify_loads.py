"""Live check against a running chipscope: does each load light up its own block?

    python3 tests/verify_loads.py [http://127.0.0.1:7878] [kind ...]

For each load: average the block's metric for 3 s before, start the load,
average seconds 3-9 of it, stop, report before -> during. Real hardware only.
"""
import json
import sys
import threading
import time
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].startswith("http") else "http://127.0.0.1:7878"
KINDS = [a for a in sys.argv[1:] if not a.startswith("http")] or ["cpu-e", "mem", "gpu", "ane", "ssd", "cpu-p"]

frames = []


def reader():
    req = urllib.request.Request(BASE + "/api/stream")
    with urllib.request.urlopen(req) as r:
        for raw in r:
            line = raw.decode().strip()
            if line.startswith("data: ") and '"cores"' in line:
                frames.append((time.time(), json.loads(line[6:])))


def post(path):
    req = urllib.request.Request(BASE + path, data=b"", method="POST", headers={"X-Chipscope": "1"})
    return json.load(urllib.request.urlopen(req))


METRICS = {
    "cpu-p": ("P-cluster power W", lambda f: f["clusters"]["pclu0"]["w_cores"] + f["clusters"]["pclu1"]["w_cores"]),
    "cpu-e": ("E-cluster power W", lambda f: f["clusters"]["eclu"]["w_cores"]),
    "mem": ("DRAM traffic GB/s", lambda f: (f["mem"]["dram_rd"] + f["mem"]["dram_wr"]) / 1e9),
    "gpu": ("GPU utilization %", lambda f: (f["gpu"]["util"] or 0) * 100),
    "ane": ("Neural Engine power W", lambda f: f["ane"]["w"]),
    "ssd": ("SSD controller traffic MB/s", lambda f: sum(f["bw"].get("ANS", [0, 0])[:2]) / 1e6),
}


def avg(fn, t0, t1):
    v = [fn(f) for t, f in frames if t0 <= t <= t1]
    return sum(v) / len(v) if v else float("nan")


def main():
    threading.Thread(target=reader, daemon=True).start()
    time.sleep(1.5)
    ok = True
    for k in KINDS:
        name, fn = METRICS[k]
        t0 = time.time()
        time.sleep(3)
        before = avg(fn, t0, time.time())
        post(f"/api/load/{k}?seconds=10")
        ts = time.time()
        time.sleep(9)
        during = avg(fn, ts + 3, time.time())
        extra = ""
        if k == "gpu":
            mhz = [f["gpu"]["mhz"] for t, f in frames if t >= ts + 3]
            st = frames[-1][1]["gpu"]["states"]
            extra = f" | gpu mhz samples {mhz[-4:]} states {st}"
        post("/api/load/stop")
        time.sleep(2)
        rose = during > before * 1.25 and during - before > 1e-3
        ok &= rose
        print(f"{'PASS' if rose else 'FAIL'}  {k:6} {name:28} before {before:10.3f}  during {during:10.3f}{extra}",
              flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
