"""Local HTTP server: static UI, a Server-Sent-Events stream of frames, and small JSON APIs."""
from __future__ import annotations

import json
import mimetypes
import queue
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import ioreport, native, topology

WEB = Path(__file__).resolve().parent.parent / "web"


class App:
    def __init__(self, topo: dict, sampler, helper_error: str | None = None):
        self.topo = topo
        self.sampler = sampler
        self.helper_error = helper_error
        self.loads = native.Loads()
        self.clients: list = []
        self.clients_lock = threading.Lock()
        self.probes = native.ProbeRunner(self.broadcast)
        self._json_cache: tuple = (0, "")
        self._channels = None

    def broadcast(self, event: dict):
        with self.clients_lock:
            for q in self.clients:
                q.put(event)

    def frame_json(self, frame) -> str:
        seq, js = self._json_cache
        if seq != frame["seq"]:
            f = dict(frame, loads=self.loads.status(), probing=self.probes.running)
            js = json.dumps(f, separators=(",", ":"))
            self._json_cache = (frame["seq"], js)
        return js

    def passive(self) -> dict:
        board = (self.sampler.latest or {}).get("board", {})
        return dict(disk_life_us=(board.get("disk") or {}).get("life_rd_lat_us"),
                    sensors=self.sampler.sensor_latency())

    def channels(self):
        if self._channels is None:
            groups: dict = {}
            for g, sg, name, unit in ioreport.list_channels():
                key = f"{g} / {sg}" if sg else g
                d = groups.setdefault(key, dict(group=key, n=0, examples=[], units=set()))
                d["n"] += 1
                d["units"].add(unit)
                if len(d["examples"]) < 8:
                    d["examples"].append(name)
            self._channels = sorted(
                (dict(v, units=sorted(u for u in v["units"] if u)) for v in groups.values()),
                key=lambda x: -x["n"])
        return self._channels


def make_handler(app: App):
    class H(BaseHTTPRequestHandler):
        server_version = "chipscope"

        def log_message(self, fmt, *args):  # quiet
            pass

        # -------------------------------------------------- helpers
        def _host_ok(self) -> bool:
            # Only answer requests addressed to this machine (blocks DNS-rebinding pages).
            host = (self.headers.get("Host") or "").split(":")[0]
            return host in ("127.0.0.1", "localhost", "[::1]")

        def _send(self, code: int, body: bytes, ctype: str = "application/json"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, code: int = 200):
            self._send(code, json.dumps(obj, separators=(",", ":"), default=str).encode())

        # -------------------------------------------------- GET
        def do_GET(self):
            if not self._host_ok():
                return self._send(403, b'{"error":"host"}')
            u = urlparse(self.path)
            q = parse_qs(u.query)
            path = u.path
            if path == "/api/stream":
                return self._stream()
            if path == "/api/topology":
                return self._json(dict(app.topo, helper_error=app.helper_error))
            if path == "/api/history":
                secs = float((q.get("seconds") or ["300"])[0])
                cutoff = time.time() - secs
                frames = [f for f in list(app.sampler.history) if f["t"] >= cutoff]
                body = "[" + ",".join(app.frame_json(f) if f is app.sampler.latest else
                                      json.dumps(f, separators=(",", ":")) for f in frames) + "]"
                return self._send(200, body.encode())
            if path == "/api/sensors":
                return self._json(dict(app.sampler.sensors, latency=app.sampler.sensor_latency()))
            if path == "/api/channels":
                return self._json(app.channels())
            if path == "/api/atlas":
                return self._json(native.atlas(app.topo, app.probes.results, app.passive()))
            if path == "/api/health":
                return self._json(dict(ok=True, seq=app.sampler.seq, errors=app.sampler.errors))
            return self._static(path)

        def _static(self, path: str):
            if path in ("/", ""):
                path = "/index.html"
            f = (WEB / path.lstrip("/")).resolve()
            if WEB not in f.parents or not f.is_file():
                return self._send(404, b"not found", "text/plain")
            ctype = mimetypes.guess_type(str(f))[0] or "application/octet-stream"
            if ctype.startswith("text/") or ctype.endswith("javascript"):
                ctype += "; charset=utf-8"
            self._send(200, f.read_bytes(), ctype)

        def _stream(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            q: queue.Queue = queue.Queue()
            with app.clients_lock:
                app.clients.append(q)
            last = 0
            try:
                while True:
                    frame = app.sampler.wait_next(last, timeout=0.5)
                    out = []
                    if frame and frame["seq"] > last:
                        last = frame["seq"]
                        out.append(f"event: frame\ndata: {app.frame_json(frame)}\n\n")
                    while not q.empty():
                        out.append(f"event: probe\ndata: {json.dumps(q.get_nowait())}\n\n")
                    if not out:
                        out.append(": keepalive\n\n")
                    self.wfile.write("".join(out).encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                with app.clients_lock:
                    if q in app.clients:
                        app.clients.remove(q)

        # -------------------------------------------------- POST
        def do_POST(self):
            # A custom header forces a CORS preflight, which we never answer:
            # other web pages cannot trigger loads or probes on this machine.
            if not self._host_ok() or self.headers.get("X-Chipscope") != "1":
                return self._send(403, b'{"error":"forbidden"}')
            u = urlparse(self.path)
            q = parse_qs(u.query)
            parts = u.path.strip("/").split("/")
            if parts[:2] == ["api", "load"] and len(parts) == 3:
                if parts[2] == "stop":
                    return self._json(app.loads.stop((q.get("kind") or [None])[0]))
                try:
                    secs = int((q.get("seconds") or ["20"])[0])
                    return self._json(app.loads.start(parts[2], secs))
                except KeyError:
                    return self._json(dict(error="unknown load"), 404)
                except RuntimeError as e:
                    return self._json(dict(error=str(e)), 500)
            if u.path == "/api/probe/run":
                ctx = dict(load=(app.sampler.latest or {}).get("board", {}).get("load"),
                           sensors=app.sampler.sensor_latency())
                return self._json(dict(started=app.probes.start(ctx), running=app.probes.running))
            return self._json(dict(error="not found"), 404)

    return H


def serve(app: App, host: str, port: int):
    last = None
    for p in range(port, port + 20):
        try:
            httpd = ThreadingHTTPServer((host, p), make_handler(app))
            httpd.daemon_threads = True
            return httpd
        except OSError as e:
            last = e
    raise last


__all__ = ["App", "serve", "topology"]
