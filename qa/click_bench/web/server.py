#!/usr/bin/env python3
"""Serves page.html; the page posts its target boxes (/layout) and every
click (/click). Writes OUT/web_layout.json and appends OUT/web_clicks.log."""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
OUT = Path(sys.argv[2] if len(sys.argv) > 2 else HERE)
PORT = int(sys.argv[1] if len(sys.argv) > 1 else 8765)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        p = self.path.split("?")[0]
        f = HERE / ("page.html" if p == "/" else p.lstrip("/"))
        if not f.is_file():
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(f.read_bytes())

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/layout":
            (OUT / "web_layout.json").write_text(json.dumps(body, indent=1))
        elif self.path == "/click":
            body["t"] = time.time()
            with open(OUT / "web_clicks.log", "a") as f:
                f.write(json.dumps(body) + "\n")
        self.send_response(204); self.end_headers()


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
