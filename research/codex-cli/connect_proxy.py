#!/usr/bin/env python3
"""Minimal HTTP CONNECT proxy (the DNS workaround for the static musl codex on Android).

The musl codex binary resolves DNS through /etc/resolv.conf, which doesn't exist on
Android, so every request fails with "error sending request". With
HTTPS_PROXY=http://127.0.0.1:<port>, codex sends `CONNECT host:443` and the proxy
resolves the name. TLS stays end-to-end between codex and the server; the proxy only
sees the host name.

The app does the same thing in Dart (ServerSocket on 127.0.0.1 + Socket.connect).
For the spike it runs on the dev host and is exposed to the phone with
`adb reverse tcp:18080 tcp:18080`.

Usage: python3 -I connect_proxy.py [port]   (default 18080, binds 127.0.0.1)
Logs only "CONNECT host:port", never payloads.
"""
import asyncio
import sys


async def pipe(r: asyncio.StreamReader, w: asyncio.StreamWriter) -> None:
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except (ConnectionError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def handle(cr: asyncio.StreamReader, cw: asyncio.StreamWriter) -> None:
    try:
        head = await cr.readuntil(b"\r\n\r\n")
    except Exception:
        cw.close()
        return
    line = head.split(b"\r\n", 1)[0].decode("latin1")
    parts = line.split()
    if len(parts) < 2 or parts[0].upper() != "CONNECT":
        cw.write(b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n")
        await cw.drain()
        cw.close()
        return
    host, _, port = parts[1].rpartition(":")
    print(f"CONNECT {host}:{port}", flush=True)
    try:
        sr, sw = await asyncio.open_connection(host.strip("[]"), int(port))
    except Exception as e:
        print(f"  upstream failed: {type(e).__name__}", flush=True)
        cw.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        await cw.drain()
        cw.close()
        return
    cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    await cw.drain()
    await asyncio.gather(pipe(cr, sw), pipe(sr, cw))


async def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    srv = await asyncio.start_server(handle, "127.0.0.1", port)
    print(f"listening on 127.0.0.1:{port}", flush=True)
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
