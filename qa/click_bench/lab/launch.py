#!/usr/bin/env python3
"""Start the loopback click lab and open its own Chromium app window."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def alive(pid):
    if not isinstance(pid, int) or pid < 2:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def healthy(url):
    try:
        with urllib.request.urlopen(url + "api/health", timeout=1) as response:
            data = json.load(response)
        return data.get("server") == "woi-click-accuracy-lab" and data.get("fresh_context") is True
    except (OSError, ValueError):
        return False


def choose_python(explicit):
    candidates = [explicit, os.environ.get("WOI_LAB_PYTHON"),
                  REPO / "research/.venv/bin/python",
                  REPO.parent / "woi/research/.venv/bin/python", sys.executable]
    tried = set()
    for value in candidates:
        if not value:
            continue
        candidate = str(value)
        if candidate in tried:
            continue
        tried.add(candidate)
        resolved = shutil.which(candidate) or candidate
        if not Path(resolved).is_file():
            continue
        try:
            check = subprocess.run([resolved, "-c", "import websockets"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if check.returncode == 0:
            return resolved
        if explicit:
            break
    raise RuntimeError("No Python environment with websockets was found. Install lab/requirements.txt in a virtual environment and pass --python PATH.")


def free_port(requested):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        probe.bind(("127.0.0.1", requested))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0, help="Loopback port; default selects a free port.")
    parser.add_argument("--out", type=Path, default=REPO / "qa/out/click_lab")
    parser.add_argument("--python", help="Python interpreter with lab dependencies.")
    parser.add_argument("--browser", help="Chromium or Chrome executable.")
    parser.add_argument("--display", default=os.environ.get("DISPLAY", ":0"))
    parser.add_argument("--no-browser", action="store_true", help="Start or reuse the server only.")
    parser.add_argument("--headless", action="store_true", help="Create an isolated headless window for UI checks.")
    args = parser.parse_args()
    output = args.out.resolve()
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    record_path = output / "runtime.json"
    try:
        record = json.loads(record_path.read_text())
    except (OSError, ValueError):
        record = {}
    previous_record = dict(record)
    url = record.get("url", "")
    reuse = (record.get("workspace") == str(REPO) and alive(record.get("server_pid"))
             and (not args.port or record.get("port") == args.port) and healthy(url))
    if not reuse:
        interpreter = choose_python(args.python)
        port = free_port(args.port)
        server_log = output / "server.log"
        with server_log.open("ab") as log:
            server = subprocess.Popen([interpreter, "-u", str(HERE / "server.py"),
                                       "--host", "127.0.0.1", "--port", str(port), "--out", str(output)],
                                      cwd=REPO, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        url = f"http://127.0.0.1:{port}/"
        deadline = time.monotonic() + 12
        while not healthy(url):
            if server.poll() is not None:
                raise RuntimeError(f"The lab server exited. See {server_log.relative_to(REPO) if server_log.is_relative_to(REPO) else server_log}.")
            if time.monotonic() >= deadline:
                server.terminate()
                raise RuntimeError("The lab server did not become ready within 12 seconds.")
            time.sleep(.1)
        record = {"workspace": str(REPO), "url": url, "port": port, "server_pid": server.pid,
                  "server_log": str(server_log), "python": interpreter,
                  "adapter_sha256": hashlib.sha256((HERE / "adapters.py").read_bytes()).hexdigest()}
        if (previous_record.get("workspace") == str(REPO) and previous_record.get("url") == url
                and alive(previous_record.get("browser_pid"))):
            for key in ("browser_pid", "browser_profile", "browser_log", "headless", "display"):
                if key in previous_record:
                    record[key] = previous_record[key]
    if not args.no_browser:
        browser = args.browser or next((shutil.which(name) for name in ("chromium", "google-chrome", "chromium-browser") if shutil.which(name)), None)
        if not browser:
            record_path.write_text(json.dumps(record, indent=2) + "\n")
            raise RuntimeError(f"No Chromium browser found. The lab server is ready at {url}; open it in a separate browser window.")
        profile = output / ("browser-headless" if args.headless else "browser-profile")
        browser_log = output / ("browser-headless.log" if args.headless else "browser.log")
        if not (alive(record.get("browser_pid")) and record.get("headless") == args.headless):
            command = [str(browser), f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
                       "--disable-dev-shm-usage", "--remote-debugging-port=0", "--window-size=1360,1000",
                       "--window-position=60,40", f"--app={url}"]
            if args.headless:
                command += ["--headless=new", "--disable-gpu"]
            env = dict(os.environ)
            env["DISPLAY"] = args.display
            with browser_log.open("ab") as log:
                process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log,
                                           stderr=subprocess.STDOUT, start_new_session=True)
            record.update(browser_pid=process.pid, browser_profile=str(profile),
                          browser_log=str(browser_log), headless=args.headless, display=args.display)
    try:
        with urllib.request.urlopen(url + "api/health", timeout=2) as response:
            server_health = json.load(response)
        record["protocol"] = server_health.get("protocol")
        record["image_detail_policy"] = server_health.get("image_detail_policy", "high")
    except (OSError, ValueError):
        pass
    record_path.write_text(json.dumps(record, indent=2) + "\n")
    os.chmod(record_path, 0o600)
    print(json.dumps({"url": url, "server_pid": record["server_pid"],
                      "browser_pid": record.get("browser_pid"), "headless": record.get("headless", False),
                      "runtime": str(record_path.relative_to(REPO)) if record_path.is_relative_to(REPO) else str(record_path)}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as exc:
        print(f"Click lab: {exc}", file=sys.stderr)
        raise SystemExit(1)
