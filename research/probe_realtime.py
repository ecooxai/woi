#!/usr/bin/env python3
"""Probe OpenAI realtime voice models using the ChatGPT/Codex login in ~/.codex/auth.json.

Two transports (see REALTIME_API.md):

  ws    Path A - standard Realtime API over WebSocket:
        wss://api.openai.com/v1/realtime?model=gpt-realtime-1.5  (Bearer = ChatGPT access token)
        Full feature set: function tools, images, VAD, cancel/truncate, token usage.

  live  Path B - gpt-live-* ("frameless bidi" / quicksilver v2), what Codex voice mode uses:
        POST https://chatgpt.com/backend-api/codex/realtime/calls  (JSON {sdp, session})
        -> WebRTC media (mic/speaker over RTP)  +  sideband wss://api.openai.com/v1/live/{call_id}
        No session tools; actions arrive as `delegation.created` and are answered with
        `delegation.context.append` (we resolve them with the Responses API + click_screen tool).

Examples:
  probe_realtime.py --wav fixtures/02_click_center.wav                  # ws, gpt-realtime-1.5
  probe_realtime.py --text "Click the center of the screen"
  probe_realtime.py --image shot.png --text "What is in this image?"
  probe_realtime.py --scenario interrupt
  probe_realtime.py --scenario errors
  probe_realtime.py --transport live --model gpt-live-1.1 --wav fixtures/02_click_center.wav

Assistant audio is written to research/out/. Tokens are never printed (codex_auth.redact).
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import fractions
import json
import re
import sys
import time
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import numpy as np  # noqa: E402
import websockets  # noqa: E402

import codex_auth as ca  # noqa: E402

OUT = HERE / "out"
RATE = 24000
REALTIME_WS = "wss://api.openai.com/v1/realtime"
LIVE_WS = "wss://api.openai.com/v1/live"
LIVE_CALLS = f"{ca.CHATGPT_BASE}/realtime/calls?intent=quicksilver&architecture=avas"

CLICK_TOOL = {
    "type": "function",
    "name": "click_screen",
    "description": "Click the mouse at absolute screen pixel coordinates. The screen is 1920x1080.",
    "parameters": {
        "type": "object",
        "properties": {
            "x": {"type": "number", "description": "X pixel, 0..1919"},
            "y": {"type": "number", "description": "Y pixel, 0..1079"},
        },
        "required": ["x", "y"],
        "additionalProperties": False,
    },
}
DEFAULT_INSTRUCTIONS = (
    "You are a concise voice assistant that controls the user's computer. "
    "The screen is 1920x1080 pixels. When the user asks to click something, call click_screen. "
    "Keep spoken replies to one short sentence."
)


# ----------------------------------------------------------------------------- audio helpers
def read_wav_24k(path: str | Path) -> bytes:
    """Return mono s16le PCM at 24 kHz (naive linear resample / downmix if needed)."""
    with wave.open(str(path)) as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if sw != 2:
        raise ValueError(f"{path}: need 16-bit PCM wav, got sampwidth={sw}")
    a = np.frombuffer(raw, dtype=np.int16).reshape(-1, ch).mean(axis=1)
    if sr != RATE:
        t_new = np.arange(int(len(a) * RATE / sr)) * (sr / RATE)
        a = np.interp(t_new, np.arange(len(a)), a)
    return a.astype(np.int16).tobytes()


def write_wav(path: str | Path, pcm: bytes, rate: int = RATE) -> Path:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return path


def rms(pcm: bytes) -> float:
    a = np.frombuffer(pcm, dtype=np.int16).astype(np.float32)
    return float(np.sqrt((a * a).mean())) if len(a) else 0.0


def voiced_end_s(pcm: bytes, thresh: float = 400.0) -> float:
    """End of the last 20 ms frame above `thresh` RMS = where speech really ends (fixtures have trailing silence)."""
    a = np.frombuffer(pcm, dtype=np.int16).astype(np.float32)
    f = RATE // 50
    n = len(a) // f
    if n == 0:
        return 0.0
    r = np.sqrt((a[: n * f].reshape(n, f) ** 2).mean(axis=1))
    idx = np.nonzero(r > thresh)[0]
    return float((idx[-1] + 1) * f / RATE) if len(idx) else len(a) / RATE


def png_data_uri(path: str | Path) -> str:
    p = Path(path)
    mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}[p.suffix.lower()]
    return f"data:{mime};base64,{base64.b64encode(p.read_bytes()).decode()}"


def elide(o):
    """Shorten base64 audio/image payloads for logging."""
    if isinstance(o, dict):
        return {k: (f"<{len(v)} chars>" if isinstance(v, str) and len(v) > 300 and k in ("audio", "delta", "image_url") else elide(v))
                for k, v in o.items()}
    if isinstance(o, list):
        return [elide(x) for x in o]
    return o


def fake_click(args: dict) -> str:
    """Stand-in for the real desktop action."""
    return json.dumps({"ok": True, "clicked": {"x": args.get("x"), "y": args.get("y")}})


class Clock:
    def __init__(self):
        self.t0 = time.perf_counter()

    def __call__(self) -> float:
        return time.perf_counter() - self.t0

    def log(self, *a, **kw):
        print(f"[{self():7.3f}]", *(ca.redact(x) if isinstance(x, str) else x for x in a), flush=True, **kw)


# ============================================================================ Path A: /v1/realtime
class RealtimeWS:
    """Standard (GA) Realtime API over WebSocket, authenticated with the ChatGPT access token."""

    def __init__(self, model: str, voice: str, instructions: str, tools: list, tag: str, verbose: bool):
        self.model, self.voice, self.instructions, self.tools = model, voice, instructions, tools
        self.tag, self.verbose = tag, verbose
        self.clk = Clock()
        self.q: asyncio.Queue = asyncio.Queue()
        self.audio: dict[str, bytearray] = {}
        self.all_audio = bytearray()
        self.metrics: dict = {}
        self.usage_total = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
        self.tool_handlers = {"click_screen": fake_click}
        self.function_calls: list = []
        self.user_transcripts: list = []
        self.assistant_transcripts: list = []
        self.errors: list = []
        self.saved: list = []
        self.t_audio_end: float | None = None
        self.auto_tools = True
        self.session: dict = {}
        self.done_ids: set = set()
        self.turn_detection = {"type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 500,
                               "create_response": True, "interrupt_response": True}

    async def connect(self, extra_session: dict | None = None):
        auth = ca.load_auth()
        t = time.perf_counter()
        self.ws = await websockets.connect(f"{REALTIME_WS}?model={self.model}", additional_headers=ca.chatgpt_headers(auth),
                                           max_size=None, open_timeout=20)
        self.metrics["ws_connect_s"] = time.perf_counter() - t
        self.reader = asyncio.create_task(self._reader())
        created = await self.wait("session.created", 10)
        self.metrics["session_created_s"] = time.perf_counter() - t
        self.session = created["session"]
        self.clk.log(f"connected model={self.session['model']} session={self.session['id']} "
                     f"ws_handshake={self.metrics['ws_connect_s']*1000:.0f}ms "
                     f"session.created={self.metrics['session_created_s']*1000:.0f}ms "
                     f"expires_in={self.session['expires_at']-time.time():.0f}s")
        session = {
            "type": "realtime",
            "instructions": self.instructions,
            "output_modalities": ["audio"],
            "audio": {
                "input": {
                    "format": {"type": "audio/pcm", "rate": RATE},
                    "noise_reduction": {"type": "near_field"},
                    "transcription": {"model": "gpt-4o-mini-transcribe"},
                    "turn_detection": self.turn_detection,
                },
                "output": {"format": {"type": "audio/pcm", "rate": RATE}, "voice": self.voice},
            },
            "tools": self.tools,
            "tool_choice": "auto",
        }
        if extra_session:
            session.update(extra_session)
        await self.send({"type": "session.update", "session": session})
        upd = await self.wait("session.updated", 10)
        self.session = upd["session"]

    async def send(self, ev: dict):
        if self.verbose or ev["type"] not in ("input_audio_buffer.append",):
            self.clk.log("->", json.dumps(elide(ev))[:400])
        await self.ws.send(json.dumps(ev))

    async def _reader(self):
        try:
            async for raw in self.ws:
                ev = json.loads(raw)
                await self._handle(ev)
                await self.q.put(ev)
        except websockets.ConnectionClosed as e:
            self.clk.log(f"websocket closed code={getattr(e.rcvd, 'code', None)} reason={getattr(e.rcvd, 'reason', None)}")
            await self.q.put({"type": "__closed__"})

    async def _handle(self, ev: dict):
        t = ev["type"]
        log = self.clk.log
        if t == "response.output_audio.delta":
            b = base64.b64decode(ev["delta"])
            if "first_audio" not in self.metrics:
                self.metrics["first_audio"] = time.perf_counter()
                if self.t_audio_end:
                    self.metrics["speech_end_to_first_audio_s"] = self.metrics["first_audio"] - self.t_audio_end
                    log(f"first audio delta {self.metrics['speech_end_to_first_audio_s']*1000:.0f}ms after end of user speech")
            self.audio.setdefault(ev["response_id"], bytearray()).extend(b)
            self.all_audio.extend(b)
            return
        if t in ("response.output_audio_transcript.delta", "conversation.item.input_audio_transcription.delta",
                 "response.function_call_arguments.delta", "rate_limits.updated") and not self.verbose:
            return
        if t == "input_audio_buffer.speech_started":
            log(f"VAD speech_started audio_start_ms={ev.get('audio_start_ms')}")
        elif t == "input_audio_buffer.speech_stopped":
            if self.t_audio_end and "speech_end_to_vad_stopped_s" not in self.metrics:
                self.metrics["speech_end_to_vad_stopped_s"] = time.perf_counter() - self.t_audio_end
            log(f"VAD speech_stopped audio_end_ms={ev.get('audio_end_ms')}")
        elif t == "conversation.item.input_audio_transcription.completed":
            self.user_transcripts.append(ev["transcript"])
            log(f"USER TRANSCRIPT: {ev['transcript']!r}  usage={ev.get('usage')}")
        elif t == "response.output_audio_transcript.done":
            self.assistant_transcripts.append(ev["transcript"])
            log(f"ASSISTANT TRANSCRIPT: {ev['transcript']!r}")
        elif t == "response.output_text.done":
            self.assistant_transcripts.append(ev["text"])
            log(f"ASSISTANT TEXT: {ev['text']!r}")
        elif t == "response.function_call_arguments.done":
            if self.t_audio_end and "speech_end_to_function_call_s" not in self.metrics:
                self.metrics["speech_end_to_function_call_s"] = time.perf_counter() - self.t_audio_end
            log(f"FUNCTION CALL args done name={ev.get('name')} call_id={ev.get('call_id')} args={ev.get('arguments')}")
        elif t == "response.done":
            r = ev["response"]
            self.done_ids.add(r["id"])
            u = r.get("usage") or {}
            for k in self.usage_total:
                self.usage_total[k] += u.get(k, 0)
            log(f"response.done id={r['id']} status={r['status']} details={r.get('status_details')} usage={json.dumps(u)}")
            pcm = self.audio.get(r["id"])
            if pcm:
                p = write_wav(OUT / f"{self.tag}_{len(self.saved)+1:02d}.wav", bytes(pcm))
                self.saved.append(p)
                log(f"saved assistant audio {p.relative_to(HERE)} ({len(pcm)/2/RATE:.2f}s)")
            calls = [o for o in r.get("output", []) if o.get("type") == "function_call"]
            for c in calls:
                self.function_calls.append({"name": c["name"], "arguments": json.loads(c["arguments"] or "{}"), "call_id": c["call_id"]})
                log(f"FUNCTION CALL {c['name']}({c['arguments']}) call_id={c['call_id']}")
                if self.auto_tools:
                    fn = self.tool_handlers.get(c["name"])
                    out = fn(json.loads(c["arguments"] or "{}")) if fn else json.dumps({"error": f"unknown tool {c['name']}"})
                    await self.send({"type": "conversation.item.create",
                                     "item": {"type": "function_call_output", "call_id": c["call_id"], "output": out}})
            if calls and self.auto_tools:
                await self.send({"type": "response.create"})
        elif t == "error":
            self.errors.append(ev["error"])
            log(f"ERROR {json.dumps(ev['error'])}")
        elif t in ("session.created", "session.updated"):
            s = ev["session"]
            log(f"{t}: voice={s['audio']['output']['voice']} tools={[x['name'] for x in s.get('tools', [])]} "
                f"vad={s['audio']['input']['turn_detection']} transcription={s['audio']['input']['transcription']}")
        elif self.verbose or t in ("conversation.item.truncated", "input_audio_buffer.committed", "input_audio_buffer.cleared",
                                    "response.created", "conversation.item.done"):
            log("<-", json.dumps(elide(ev))[:600])

    async def wait(self, etype: str | tuple, timeout: float = 30, pred=None) -> dict:
        etypes = (etype,) if isinstance(etype, str) else etype
        deadline = time.perf_counter() + timeout
        while True:
            rem = deadline - time.perf_counter()
            if rem <= 0:
                raise TimeoutError(f"timeout waiting for {etypes}")
            ev = await asyncio.wait_for(self.q.get(), rem)
            if ev["type"] == "__closed__":
                raise ConnectionError("websocket closed")
            if ev["type"] in etypes and (pred is None or pred(ev)):
                return ev

    async def wait_final_response(self, timeout: float = 60) -> dict:
        """Wait for a response.done that is not just a tool call (tool calls trigger a follow-up)."""
        while True:
            ev = await self.wait("response.done", timeout)
            out = ev["response"].get("output", [])
            if not any(o.get("type") == "function_call" for o in out) or not self.auto_tools:
                return ev

    async def send_wav(self, pcm: bytes, realtime: bool = True, tail_silence_s: float = 1.2):
        """Stream like a microphone: 100 ms chunks, each sent when its audio would be complete."""
        chunk = RATE * 2 // 10
        t_start = time.perf_counter()
        # latency reference: wall-clock moment the user's speech ends (mic-paced streaming)
        self.t_audio_end = t_start + voiced_end_s(pcm) if realtime else None
        for i in range(0, len(pcm), chunk):
            if realtime:
                delay = t_start + (i + chunk) / 2 / RATE - time.perf_counter()
                if delay > 0:
                    await asyncio.sleep(delay)
            await self.ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[i:i + chunk]).decode()}))
        if not realtime:
            self.t_audio_end = time.perf_counter()
        self.clk.log(f"sent {len(pcm)/2/RATE:.2f}s of input audio (input_audio_buffer.append x{-(-len(pcm)//chunk)})")
        silence = b"\0" * chunk
        for _ in range(int(tail_silence_s * 10)):  # trailing silence lets server VAD close the turn
            if realtime:
                await asyncio.sleep(0.1)
            await self.ws.send(json.dumps({"type": "input_audio_buffer.append", "audio": base64.b64encode(silence).decode()}))

    async def close(self):
        self.reader.cancel()
        await self.ws.close()


# ============================================================================ Path B: gpt-live
class LiveRTC:
    """gpt-live-* over WebRTC (ChatGPT backend call creation) + api.openai.com sideband WebSocket."""

    def __init__(self, model: str, voice: str, instructions: str, tag: str, verbose: bool, delegate: str):
        self.model, self.voice, self.instructions, self.tag, self.verbose = model, voice, instructions, tag, verbose
        self.delegate = delegate  # "responses" (resolve with Responses API + click_screen) | "echo"
        self.clk = Clock()
        self.q: asyncio.Queue = asyncio.Queue()
        self.metrics: dict = {}
        self.session_audio = bytearray()
        self.first_delta_ms: int | None = None
        self.user_transcripts, self.assistant_transcripts, self.function_calls, self.errors, self.saved = [], [], [], [], []
        self.t_audio_end: float | None = None
        self.usage: dict = {}

    async def connect(self):
        import httpx
        from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

        auth = ca.load_auth()
        self.auth = auth
        hdrs = ca.live_headers(auth)
        t0 = time.perf_counter()
        # No STUN: the server side is a public ICE endpoint; host candidates are enough and gathering is instant.
        self.pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.mic = _MicTrack()
        self.pc.addTrack(self.mic)
        self.dc = self.pc.createDataChannel("oai-events")  # carries the same JSON events as the sideband, minus audio
        await self.pc.setLocalDescription(await self.pc.createOffer())
        while self.pc.iceGatheringState != "complete":
            await asyncio.sleep(0.01)
        self.metrics["ice_gather_s"] = time.perf_counter() - t0
        session = {"model": self.model, "instructions": self.instructions,
                   "audio": {"output": {"voice": self.voice}}, "delegation": {"type": "client"}}
        t1 = time.perf_counter()
        async with httpx.AsyncClient(timeout=30) as hc:
            r = await hc.post(LIVE_CALLS, headers=dict(hdrs, **{"Content-Type": "application/json"}),
                              json={"sdp": self.pc.localDescription.sdp, "session": session})
        self.metrics["call_create_s"] = time.perf_counter() - t1
        if r.status_code != 201:
            raise RuntimeError(f"call create failed {r.status_code}: {ca.redact(r.text[:500])}")
        self.call_id = r.headers["location"].rsplit("/", 1)[1]
        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=r.text, type="answer"))
        t2 = time.perf_counter()
        try:
            self.ws = await websockets.connect(f"{LIVE_WS}/{self.call_id}", additional_headers=hdrs, max_size=None, open_timeout=15)
        except websockets.InvalidStatus as e:
            raise RuntimeError(f"sideband rejected HTTP {e.response.status_code} - session config was probably invalid "
                               f"(bad voice / unknown field kill the call silently)") from e
        self.metrics["sideband_connect_s"] = time.perf_counter() - t2
        self.reader = asyncio.create_task(self._reader())
        started = await self.wait("session.started", 10)
        self.metrics["session_started_total_s"] = time.perf_counter() - t0
        self.clk.log(f"live session {started['session']['id'][:12]}... model={self.model} voice={self.voice} "
                     f"ice={self.metrics['ice_gather_s']*1000:.0f}ms call_create={self.metrics['call_create_s']*1000:.0f}ms "
                     f"sideband={self.metrics['sideband_connect_s']*1000:.0f}ms total_to_session.started="
                     f"{self.metrics['session_started_total_s']*1000:.0f}ms expires_in={started['session']['expires_at']-time.time():.0f}s")

    async def send(self, ev: dict):
        self.clk.log("->", json.dumps(elide(ev))[:400])
        await self.ws.send(json.dumps(ev))

    async def _reader(self):
        try:
            async for raw in self.ws:
                ev = json.loads(raw)
                await self._handle(ev)
                await self.q.put(ev)
        except websockets.ConnectionClosed as e:
            self.clk.log(f"sideband closed code={getattr(e.rcvd, 'code', None)} reason={getattr(e.rcvd, 'reason', None)}")
            await self.q.put({"type": "__closed__"})

    async def _handle(self, ev: dict):
        t, log = ev["type"], self.clk.log
        if t == "session.output_audio.delta":  # continuous 200 ms frames incl. silence, 24 kHz s16 mono
            b = base64.b64decode(ev["delta"])
            if self.first_delta_ms is None:
                self.first_delta_ms = ev["start_ms"]
            self.session_audio.extend(b)
            if self.t_audio_end and "first_voiced_audio" not in self.metrics and rms(b) > 300:
                self.metrics["first_voiced_audio"] = time.perf_counter()
                self.metrics["speech_end_to_first_audio_s"] = self.metrics["first_voiced_audio"] - self.t_audio_end
                log(f"first voiced output audio {self.metrics['speech_end_to_first_audio_s']*1000:.0f}ms after end of user speech")
            return
        if t == "session.input_audio.append":  # echo of our mic frames (RTP) - ignore
            return
        if t in ("input_transcript.added", "output_transcript.added", "turn.delta") and not self.verbose:
            return
        if t == "turn.created":
            if ev["turn"]["role"] == "assistant" and self.t_audio_end and "speech_end_to_assistant_turn_s" not in self.metrics:
                self.metrics["speech_end_to_assistant_turn_s"] = time.perf_counter() - self.t_audio_end
            log(f"turn.created role={ev['turn']['role']} [{ev['turn']['start_ms']}ms] {ev['turn']['transcript']!r}")
        elif t == "turn.done":
            turn = ev["turn"]
            (self.user_transcripts if turn["role"] == "user" else self.assistant_transcripts).append(turn["transcript"].strip())
            log(f"{turn['role'].upper()} TRANSCRIPT: {turn['transcript'].strip()!r} [{turn['start_ms']}-{turn['end_ms']}ms]")
            if turn["role"] == "assistant" and self.first_delta_ms is not None:
                a = max(0, (turn["start_ms"] - self.first_delta_ms) * RATE * 2 // 1000)
                b = (turn["end_ms"] - self.first_delta_ms) * RATE * 2 // 1000
                p = write_wav(OUT / f"{self.tag}_{len(self.saved)+1:02d}.wav", bytes(self.session_audio[a:b]))
                self.saved.append(p)
                log(f"saved assistant turn audio {p.relative_to(HERE)} ({(b-a)/2/RATE:.2f}s)")
        elif t == "delegation.created":
            item = ev["item"]
            text = "".join(c.get("text", "") for c in item.get("content", []) if c.get("type") == "input_text")
            log(f"DELEGATION {item['id']} handoff={item.get('handoff_id')}: {text!r}")
            asyncio.create_task(self._resolve_delegation(item["id"], text))
        elif t == "session.usage.updated":
            self.usage = ev
            log(f"session.usage.updated {json.dumps(ev.get('usage'))} limit={json.dumps(ev.get('usage_limit'))}")
        elif t == "error":
            self.errors.append(ev["error"])
            log(f"ERROR {json.dumps(ev['error'])}")
        else:
            log("<-", json.dumps(elide(ev))[:600])

    async def _resolve_delegation(self, item_id: str, text: str):
        t = time.perf_counter()
        if self.delegate == "responses":
            import probe_responses as pr
            res = await asyncio.to_thread(pr.call_responses, self.auth, model="gpt-6-luna",
                                          instructions="Turn the user's request into a single tool call when a tool fits. "
                                                       "The screen is 1920x1080. If no tool fits, answer in one short sentence.",
                                          user_text=text, tools=[CLICK_TOOL], quiet=True)
            if res["function_calls"]:
                outs = []
                for fc in res["function_calls"]:
                    args = json.loads(fc["arguments"] or "{}")
                    self.function_calls.append({"name": fc["name"], "arguments": args, "call_id": fc["call_id"]})
                    self.clk.log(f"FUNCTION CALL (via Responses gpt-6-luna) {fc['name']}({fc['arguments']})")
                    outs.append(f"{fc['name']} -> {fake_click(args)}")
                result = "Done. " + "; ".join(outs)
            else:
                result = res["text"] or "No action taken."
        else:
            result = f"Done: {text}"
        self.metrics.setdefault("delegation_resolve_s", time.perf_counter() - t)
        await self.send({"type": "delegation.context.append", "delegation_item_id": item_id,
                         "content": [{"type": "input_text", "text": result}]})

    async def wait(self, etype, timeout=30, pred=None):
        etypes = (etype,) if isinstance(etype, str) else etype
        deadline = time.perf_counter() + timeout
        while True:
            rem = deadline - time.perf_counter()
            if rem <= 0:
                raise TimeoutError(f"timeout waiting for {etypes}")
            ev = await asyncio.wait_for(self.q.get(), rem)
            if ev["type"] == "__closed__":
                raise ConnectionError("sideband closed")
            if ev["type"] in etypes and (pred is None or pred(ev)):
                return ev

    async def play(self, pcm24k: bytes):
        done = self.mic.play(pcm24k)
        self.t_audio_end = time.perf_counter() + voiced_end_s(pcm24k)  # wall-clock end of speech (+-20 ms)
        self.clk.log(f"playing {len(pcm24k)/2/RATE:.2f}s into the WebRTC mic track")
        await done
        self.clk.log("input audio finished")

    async def close(self):
        try:
            await self.ws.send(json.dumps({"type": "session.close"}))
            await asyncio.sleep(0.3)
        except Exception:
            pass
        if self.session_audio:
            p = write_wav(OUT / f"{self.tag}_session.wav", bytes(self.session_audio))
            self.clk.log(f"saved full session output stream {p.relative_to(HERE)} ({len(self.session_audio)/2/RATE:.1f}s)")
        self.reader.cancel()
        await self.ws.close()
        await self.pc.close()


def _MicTrack():
    """aiortc audio track: 48 kHz mono 20 ms frames of silence, or queued speech."""
    from aiortc import MediaStreamTrack
    from av import AudioFrame

    class MicTrack(MediaStreamTrack):
        kind = "audio"

        def __init__(self):
            super().__init__()
            self.pts, self.t0 = 0, None
            self.buf = np.zeros(0, dtype=np.int16)
            self.done: asyncio.Future | None = None

        def play(self, pcm24k: bytes) -> asyncio.Future:
            a = np.frombuffer(pcm24k, dtype=np.int16).astype(np.float32)
            up = np.interp(np.arange(len(a) * 2) / 2, np.arange(len(a)), a).astype(np.int16)  # 24k -> 48k
            self.buf = np.concatenate([self.buf, up])
            self.done = asyncio.get_running_loop().create_future()
            return self.done

        async def recv(self):
            n = 960
            if self.t0 is None:
                self.t0 = time.time()
            d = self.t0 + self.pts / 48000 - time.time()
            if d > 0:
                await asyncio.sleep(d)
            if len(self.buf) >= n:
                chunk, self.buf = self.buf[:n], self.buf[n:]
            else:
                chunk = np.zeros(n, dtype=np.int16)
                if len(self.buf):
                    chunk[:len(self.buf)] = self.buf
                    self.buf = np.zeros(0, dtype=np.int16)
                if self.done and not self.done.done():
                    self.done.set_result(True)
            f = AudioFrame.from_ndarray(chunk.reshape(1, -1), format="s16", layout="mono")
            f.sample_rate, f.pts, f.time_base = 48000, self.pts, fractions.Fraction(1, 48000)
            self.pts += n
            return f

    return MicTrack()


# ============================================================================ scenarios
async def scenario_basic_ws(a) -> dict:
    rt = RealtimeWS(a.model, a.voice or "marin", a.instructions, [CLICK_TOOL], a.tag, a.verbose)
    if a.vad == "semantic":
        rt.turn_detection = {"type": "semantic_vad", "eagerness": a.eagerness, "create_response": True, "interrupt_response": True}
    else:
        rt.turn_detection["silence_duration_ms"] = a.silence_ms
    await rt.connect()
    if a.barge_in:
        await barge_in_ws(rt, a)
        await rt.close()
        return summarize(rt)
    if a.image:
        content = [{"type": "input_image", "image_url": png_data_uri(a.image)},
                   {"type": "input_text", "text": a.text or "Describe this image in one sentence."}]
        await rt.send({"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": content}})
        await rt.send({"type": "response.create"})
        await rt.wait_final_response(60)
    elif a.text:
        await rt.send({"type": "conversation.item.create",
                       "item": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": a.text}]}})
        await rt.send({"type": "response.create"})
        await rt.wait_final_response(60)
    for w in a.wav or []:
        for k in ("first_audio", "speech_end_to_first_audio_s", "speech_end_to_vad_stopped_s", "speech_end_to_function_call_s"):
            rt.metrics.pop(k, None)
        await rt.send_wav(read_wav_24k(w), realtime=not a.fast)
        await rt.wait_final_response(60)
    await asyncio.sleep(0.5)
    await rt.close()
    return summarize(rt)


async def barge_in_ws(rt: RealtimeWS, a):
    """User talks over the assistant. Server VAD (interrupt_response=true) cancels a response that is still
    generating, but generation runs ~5-10x faster than playback, so usually the response is already done and
    only the client knows what was heard: stop local playback and truncate the item to the played length."""
    await rt.send({"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": a.text or "Tell me a long story about a lighthouse keeper."}]}})
    await rt.send({"type": "response.create"})
    first = await rt.wait("response.output_audio.delta", 30)
    t_play0, story_id, item_id = time.perf_counter(), first["response_id"], first["item_id"]
    await asyncio.sleep(2.0)  # "playing" the reply
    sender = asyncio.create_task(rt.send_wav(read_wav_24k(a.wav[0]), realtime=True))
    await rt.wait("input_audio_buffer.speech_started", 15)
    played_ms = int((time.perf_counter() - t_play0) * 1000)
    still_running = story_id not in rt.done_ids
    rt.clk.log(f"BARGE-IN after {played_ms}ms of playback; assistant response still generating={still_running} "
               f"(generated {len(rt.audio.get(story_id, b''))/2/RATE:.1f}s of audio)")
    if still_running:
        d = await rt.wait("response.done", 15, pred=lambda e: e["response"]["id"] == story_id)
        rt.clk.log(f"server auto-cancelled: status={d['response']['status']} details={d['response'].get('status_details')}")
    await rt.send({"type": "conversation.item.truncate", "item_id": item_id, "content_index": 0, "audio_end_ms": played_ms})
    await rt.wait(("conversation.item.truncated", "error"), 10)
    await sender
    await rt.wait("response.done", 60, pred=lambda e: e["response"]["id"] != story_id and e["response"]["status"] != "cancelled")


async def scenario_interrupt(a) -> dict:
    """Barge-in by the client: cancel the in-flight response and truncate what was not played."""
    rt = RealtimeWS(a.model, a.voice or "marin", a.instructions, [CLICK_TOOL], a.tag, a.verbose)
    await rt.connect()
    await rt.send({"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "Tell me a long story about a lighthouse keeper. At least two minutes."}]}})
    await rt.send({"type": "response.create"})
    first = await rt.wait("response.output_audio.delta", 30)
    item_id = first["item_id"]
    await asyncio.sleep(1.5)  # pretend we've played ~1.5 s
    played_ms = 1000
    await rt.send({"type": "response.cancel"})
    done = await rt.wait("response.done", 15)  # status=cancelled, reason=client_cancelled
    # Truncate only AFTER the cancelled response.done: sent earlier, the server still appends the
    # in-flight audio and the model later "remembers" words the user never heard (observed).
    await rt.send({"type": "conversation.item.truncate", "item_id": item_id, "content_index": 0, "audio_end_ms": played_ms})
    trunc = await rt.wait(("conversation.item.truncated", "error"), 10)
    await rt.send({"type": "conversation.item.retrieve", "item_id": item_id})
    got = await rt.wait("conversation.item.retrieved", 10)
    c = got["item"]["content"][0]
    rt.clk.log(f"item after truncate: transcript={c.get('transcript')!r} audio={len(base64.b64decode(c.get('audio') or ''))/2/RATE:.2f}s")
    rt.clk.log(f"after cancel: response status={done['response']['status']} details={done['response'].get('status_details')}; "
               f"truncate -> {trunc['type']} {json.dumps(elide(trunc))[:300]}")
    # Verify the model believes it only said the truncated part
    await rt.send({"type": "conversation.item.create", "item": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "Stop. What were the last words you said to me before I interrupted?"}]}})
    await rt.send({"type": "response.create"})
    await rt.wait_final_response(30)
    await rt.close()
    s = summarize(rt)
    s["interrupt"] = {"cancel_status": done["response"]["status"], "status_details": done["response"].get("status_details"),
                      "truncate_event": trunc["type"], "audio_end_ms": played_ms}
    return s


async def scenario_errors(a) -> dict:
    """Collect error shapes."""
    rt = RealtimeWS(a.model, a.voice or "marin", a.instructions, [CLICK_TOOL], a.tag, a.verbose)
    await rt.connect()
    probes = [
        {"type": "bogus.event"},
        {"type": "session.update", "session": {"type": "realtime", "audio": {"output": {"voice": "not-a-voice"}}}},
        {"type": "session.update", "session": {"type": "realtime", "bogus": 1}},
        {"type": "conversation.item.create", "item": {"type": "function_call_output", "call_id": "nope", "output": "x"}},
        {"type": "response.cancel"},
        {"type": "conversation.item.truncate", "item_id": "item_missing", "content_index": 0, "audio_end_ms": 10},
        {"type": "input_audio_buffer.commit"},
    ]
    for p in probes:
        await rt.send(p)
        try:
            await rt.wait("error", 4)
        except TimeoutError:
            rt.clk.log("  (no error event)")
    await rt.close()
    s = summarize(rt)
    s["error_samples"] = rt.errors
    return s


async def scenario_live(a) -> dict:
    lv = LiveRTC(a.model, a.voice or "cove", a.instructions, a.tag, a.verbose, a.delegate)
    await lv.connect()
    await asyncio.sleep(0.8)
    if a.text:
        # Text has no "user turn" event on this transport; it is injected as context the model reacts to.
        await lv.send({"type": "session.context.append", "content": [{"type": "input_text", "text": a.text}]})
        await lv.wait("turn.done", 30, pred=lambda e: e["turn"]["role"] == "assistant")
    if a.barge_in:
        # Full duplex: just talk over it. The model hears the mic continuously and yields the floor.
        await lv.send({"type": "session.context.append", "content": [
            {"type": "input_text", "text": a.text or "The user wants a long story about a lighthouse keeper. Tell it now."}]})
        await lv.wait("turn.created", 30, pred=lambda e: e["turn"]["role"] == "assistant")
        await asyncio.sleep(2.5)
        await lv.play(read_wav_24k(a.wav[0]))
        await lv.wait("turn.done", 30, pred=lambda e: e["turn"]["role"] == "user")
        await asyncio.sleep(a.linger + 3)
        await lv.close()
        return summarize(lv)
    for w in a.wav or []:
        for k in ("first_voiced_audio", "speech_end_to_first_audio_s", "speech_end_to_assistant_turn_s"):
            lv.metrics.pop(k, None)
        await lv.play(read_wav_24k(w))
        await lv.wait("turn.done", 30, pred=lambda e: e["turn"]["role"] == "user")
        await lv.wait("turn.done", 40, pred=lambda e: e["turn"]["role"] == "assistant")
    await asyncio.sleep(a.linger)
    await lv.close()
    return summarize(lv)


def summarize(x) -> dict:
    m = {k: round(v, 3) for k, v in x.metrics.items() if k.endswith("_s")}
    s = {"model": getattr(x, "model", None), "metrics": m, "user_transcripts": x.user_transcripts,
         "assistant_transcripts": x.assistant_transcripts, "function_calls": x.function_calls,
         "errors": x.errors, "audio_files": [str(p.relative_to(HERE)) for p in x.saved]}
    if isinstance(x, RealtimeWS):
        s["usage_total"] = x.usage_total
    else:
        s["live_usage"] = x.usage.get("usage")
    return s


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--transport", choices=["ws", "live"], default="ws")
    ap.add_argument("--model", default=None, help="ws: gpt-realtime-1.5 (default) | live: gpt-live-1.1 (default)")
    ap.add_argument("--voice", default=None, help="ws: marin/cedar/alloy/...; live: cove/juniper/maple/...")
    ap.add_argument("--wav", action="append", help="input wav(s), any rate, 16-bit; streamed in real time")
    ap.add_argument("--text", help="text input (ws: user message, live: session.context.append)")
    ap.add_argument("--image", help="image file to send with conversation.item.create (ws only)")
    ap.add_argument("--scenario", choices=["basic", "interrupt", "errors"], default="basic")
    ap.add_argument("--instructions", default=DEFAULT_INSTRUCTIONS)
    ap.add_argument("--delegate", choices=["responses", "echo"], default="responses",
                    help="live: how to resolve delegation.created (Responses API gpt-6-luna + click_screen, or echo)")
    ap.add_argument("--tag", default=None, help="output file prefix in research/out/")
    ap.add_argument("--fast", action="store_true", help="ws: send wav as fast as possible instead of real time")
    ap.add_argument("--linger", type=float, default=2.0)
    ap.add_argument("--vad", choices=["server", "semantic"], default="server", help="ws turn detection type")
    ap.add_argument("--silence-ms", type=int, default=500, help="ws server_vad silence_duration_ms")
    ap.add_argument("--eagerness", choices=["low", "medium", "high", "auto"], default="high", help="ws semantic_vad")
    ap.add_argument("--barge-in", action="store_true",
                    help="assistant tells a story (--text overrides prompt); first --wav is spoken over it after ~2 s")
    ap.add_argument("--json", action="store_true", help="print summary JSON at the end")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()
    a.model = a.model or ("gpt-realtime-1.5" if a.transport == "ws" else "gpt-live-1.1")
    a.tag = a.tag or f"{a.transport}_{a.model}_{a.scenario}_{time.strftime('%H%M%S')}"
    OUT.mkdir(exist_ok=True)
    if a.transport == "live":
        fn = scenario_live
    else:
        fn = {"basic": scenario_basic_ws, "interrupt": scenario_interrupt, "errors": scenario_errors}[a.scenario]
    s = asyncio.run(fn(a))
    print("\n=== SUMMARY ===")
    print(ca.redact(json.dumps(s, indent=2)))


if __name__ == "__main__":
    main()
