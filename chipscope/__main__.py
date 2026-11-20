"""chipscope: a live architectural map of this Mac.  Run: python3 -m chipscope"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import threading

from . import native, topology
from .sampler import Sampler
from .server import App, serve


def main(argv=None):
    ap = argparse.ArgumentParser(prog="chipscope")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7878)
    ap.add_argument("--hz", type=float, default=4.0)
    ap.add_argument("--no-open", action="store_true", help="don't open the browser")
    a = ap.parse_args(argv)

    print("chipscope: reading the hardware map…", flush=True)
    topo = topology.build()
    wifi_box: dict = {}

    def _wifi():  # system_profiler takes ~1 s; don't block startup
        wifi_box.update(topology.wifi_info())
        topo["wifi"] = wifi_box

    threading.Thread(target=_wifi, daemon=True).start()

    helper_error = None
    try:
        native.ensure_built()
    except Exception as e:  # probes/loads disabled, live view still works
        helper_error = str(e)
        print("chipscope: native helper unavailable:", e, file=sys.stderr)

    sampler = Sampler(topo, hz=a.hz)
    sampler.start()
    app = App(topo, sampler, helper_error)
    httpd = serve(app, a.host, a.port)
    url = f"http://127.0.0.1:{httpd.server_address[1]}/"
    print(f"chipscope: {topo['chip']} · {topo['model']} → {url}  (Ctrl-C to stop)", flush=True)

    def _shutdown(*_):
        app.loads.stop()
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)
    if not a.no_open and not os.environ.get("CHIPSCOPE_NO_OPEN"):
        subprocess.Popen(["open", url])
    try:
        httpd.serve_forever(poll_interval=0.3)
    finally:
        app.loads.stop()
        sampler.stop()
        print("chipscope: stopped", flush=True)


if __name__ == "__main__":
    main()
