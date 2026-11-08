#!/usr/bin/env python3
"""Loopback-only HTTP server for Woi's standalone model click-accuracy lab."""
from __future__ import annotations

import argparse
import base64
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import mimetypes
import os
from pathlib import Path
import threading
import time
from urllib.parse import urlsplit, parse_qs

import adapters

HERE = Path(__file__).resolve().parent
DEFAULT_OUTPUT = adapters.REPO / "qa/out/click_lab"
MAX_REQUEST_BYTES = 9 * 1024 * 1024
STATIC_FILES = {"/": "index.html", "/index.html": "index.html", "/app.css": "app.css", "/app.js": "app.js"}


def strict_json(raw: bytes):
    def reject_constant(value):
        raise ValueError("Non-finite JSON number: " + value)
    return json.loads(raw, parse_constant=reject_constant)


def scrub(value):
    """Evidence contains no credentials, full base64 screenshots, or extra history."""
    if isinstance(value, dict):
        return {key: scrub(item) for key, item in value.items()
                if key.lower() not in {"authorization", "apikey", "api_key", "token", "access_token", "refresh_token", "id_token", "headers", "history", "messages", "previous_response_id"}}
    if isinstance(value, list):
        return [scrub(item) for item in value]
    if isinstance(value, str):
        if value.startswith("data:image/"):
            return "<image omitted; see image_sha256>"
        return adapters.redact(value)
    return value


class Evidence:
    def __init__(self, directory: Path):
        self.directory = directory
        self.lock = threading.Lock()
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        (directory / "screenshots").mkdir(exist_ok=True, mode=0o700)

    def append(self, filename: str, record: dict):
        data = (json.dumps(scrub(record), separators=(",", ":"), allow_nan=False) + "\n").encode()
        with self.lock:
            descriptor = os.open(self.directory / filename, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(descriptor, "ab") as target:
                target.write(data)

    def trial(self, trial: dict, response: dict):
        image_name = trial["image_sha256"] + ".png"
        path = self.directory / "screenshots" / image_name
        data = base64.b64decode(trial["screenshot"].split(",", 1)[1])
        with self.lock:
            try:
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                pass
            else:
                with os.fdopen(descriptor, "wb") as image:
                    image.write(data)
        safe_input = {key: value for key, value in trial.items() if key != "screenshot"}
        self.append("trials.jsonl", {"timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                    "request": safe_input, "screenshot_file": "screenshots/" + image_name,
                                    "response": response})


class LabServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, output: Path, *, runner=None, discovery=None):
        if address[0] not in ("127.0.0.1", "localhost"):
            raise ValueError("The lab must bind to loopback (127.0.0.1 or localhost).")
        super().__init__(address, LabHandler)
        self.runner = runner or adapters.run_trial
        self.discovery = discovery or adapters.discover_models
        self.evidence = Evidence(output)
        self.slots = threading.BoundedSemaphore(3)
        self.ids_lock = threading.Lock()
        self.request_ids: set[str] = set()
        self.request_order: deque[str] = deque()

    def reserve_request(self, request_id):
        with self.ids_lock:
            if request_id in self.request_ids:
                raise adapters.LabError("duplicate_request", "Use a new request_id for every trial.", status=409)
            self.request_ids.add(request_id)
            self.request_order.append(request_id)
            while len(self.request_order) > 10_000:
                self.request_ids.discard(self.request_order.popleft())


class LabHandler(BaseHTTPRequestHandler):
    server_version = "WoiClickLab/1"

    def log_message(self, format, *args):
        # Do not log arbitrary URLs, model output, request bodies or auth headers.
        pass

    def _security(self):
        port = self.server.server_address[1]
        host = self.headers.get("Host", "")
        valid_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
        if port == 80:
            valid_hosts |= {"127.0.0.1", "localhost"}
        if host not in valid_hosts:
            raise adapters.LabError("invalid_host", "Only the local lab hostname is accepted.", status=403)
        origin = self.headers.get("Origin")
        if origin and origin != "http://" + host:
            raise adapters.LabError("cross_origin", "Cross-origin requests are not accepted.", status=403)
        fetch_site = self.headers.get("Sec-Fetch-Site", "")
        if fetch_site not in ("", "none", "same-origin"):
            raise adapters.LabError("cross_origin", "Cross-origin requests are not accepted.", status=403)

    def _send(self, status, data, content_type="application/json; charset=utf-8"):
        if isinstance(data, (dict, list)):
            body = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        elif isinstance(data, str):
            body = data.encode()
        else:
            body = data
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _error(self, exc, request_id=None, trial=None, response=None):
        code = getattr(exc, "code", "internal_error")
        status = getattr(exc, "status", 500)
        message = adapters.redact(exc)[:600] if isinstance(exc, adapters.LabError) else "The lab could not complete this request."
        payload = {"error": message, "error_code": code, "request_id": request_id}
        if self.path == "/api/trial":
            metadata = response if isinstance(response, dict) else {}
            payload.update(request_image_bytes=metadata.get("request_image_bytes", (trial or {}).get("image_bytes")),
                           request_payload_bytes=metadata.get("request_payload_bytes"),
                           timing=metadata.get("timing") or adapters.ProviderTiming().snapshot())
        self._send(status, payload)

    def do_GET(self):
        try:
            self._security()
            parsed = urlsplit(self.path)
            if parsed.path in STATIC_FILES:
                path = HERE / STATIC_FILES[parsed.path]
                if not path.is_file():
                    raise adapters.LabError("frontend_pending", "The frontend file is not installed yet.", status=503)
                mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                self._send(200, path.read_bytes(), mime + "; charset=utf-8")
            elif parsed.path == "/api/connection":
                self._send(200, adapters.connection_status())
            elif parsed.path == "/api/models":
                force = parse_qs(parsed.query).get("refresh", ["0"])[0] == "1"
                self._send(200, self.server.discovery(force=force))
            elif parsed.path == "/api/health":
                self._send(200, {"ok": True, "protocol": adapters.PROTOCOL_VERSION, "fresh_context": True,
                                 "image_detail_policy": adapters.image_detail_policy(),
                                 "server": "woi-click-accuracy-lab"})
            else:
                raise adapters.LabError("not_found", "Not found.", status=404)
        except Exception as exc:
            self._error(exc)

    def _body(self):
        if self.headers.get("Transfer-Encoding"):
            raise adapters.LabError("invalid_encoding", "Chunked requests are not accepted.", status=400)
        if self.headers.get_content_type() != "application/json":
            raise adapters.LabError("invalid_content_type", "Use Content-Type: application/json.", status=415)
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError as exc:
            raise adapters.LabError("missing_length", "Content-Length is required.", status=411) from exc
        if not 1 <= size <= MAX_REQUEST_BYTES:
            raise adapters.LabError("request_too_large", "Request exceeds the 9 MiB limit.", status=413)
        self.connection.settimeout(30)
        raw = self.rfile.read(size)
        if len(raw) != size:
            raise adapters.LabError("truncated_body", "Truncated request body.")
        try:
            return strict_json(raw)
        except (ValueError, UnicodeDecodeError) as exc:
            raise adapters.LabError("invalid_json", "Request is not valid JSON.") from exc

    def do_POST(self):
        request_id = None
        trial = None
        response = None
        try:
            self._security()
            if self.path not in ("/api/trial", "/api/result", "/api/connection"):
                raise adapters.LabError("not_found", "Not found.", status=404)
            body = self._body()
            request_id = body.get("request_id") if isinstance(body, dict) else None
            if self.path == "/api/connection":
                self._send(200, adapters.configure_connection(body))
                return
            if self.path == "/api/result":
                if not isinstance(body, dict) or not isinstance(request_id, str) or not adapters.REQUEST_RE.fullmatch(request_id):
                    raise adapters.LabError("invalid_result", "Result must contain a valid request_id.")
                if len(json.dumps(body)) > 128 * 1024:
                    raise adapters.LabError("result_too_large", "Result evidence exceeds 128 KiB.", status=413)
                # Client-side hit evidence is stored separately and is NEVER sent to a model.
                self.server.evidence.append("results.jsonl", body)
                self._send(200, {"saved": True, "request_id": request_id})
                return
            trial = adapters.validate_trial(body)
            if not self.server.slots.acquire(blocking=False):
                raise adapters.LabError("lab_busy", "Three trials are already running; retry shortly.", status=429)
            try:
                self.server.reserve_request(request_id)
                response = self.server.runner(body)
                self.server.evidence.trial(trial, response)
            finally:
                self.server.slots.release()
            # Model/API errors are structured trial results, not fabricated coordinate misses.
            self._send(200, response)
        except Exception as exc:
            self._error(exc, request_id, trial, response)

    def do_OPTIONS(self):
        self._send(403, {"error": "Cross-origin requests are not accepted.", "error_code": "cross_origin"})


def make_server(host="127.0.0.1", port=8766, output=None, **kwargs):
    return LabServer((host, port), Path(output) if output else DEFAULT_OUTPUT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", choices=["127.0.0.1", "localhost"])
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--image-detail", choices=["auto", "high", "original"],
                        help="Default auto uses original detail for catalog-supported text vision models, high for realtime.")
    args = parser.parse_args()
    if args.image_detail:
        os.environ["WOI_LAB_IMAGE_DETAIL"] = args.image_detail
    server = make_server(args.host, args.port, args.out)
    print(f"Woi Click Accuracy Lab: http://127.0.0.1:{server.server_address[1]}/", flush=True)
    print("Fresh screenshot-only trials. Credentials remain server-side. Ctrl-C stops the lab.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
