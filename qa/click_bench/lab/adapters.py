"""Screenshot-only, stateless model adapters for the local click-accuracy lab.

Credentials are read on each call and never refreshed or sent to the browser.
No OS input, target boxes, labels list, prior turns, or locator fallback exists here.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import threading
import time
from dataclasses import dataclass, field
from contextlib import contextmanager
from urllib import error, parse, request
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
MAX_IMAGE_BYTES = 6 * 1024 * 1024
MAX_PIXELS = 16_777_216
TRIAL_TIMEOUT = 120
FLEX_TIMEOUT = 600
PROTOCOL_VERSION = "screenshot-only-v3-tiers"
CODEX_BASE = "https://chatgpt.com/backend-api/codex"
PUBLIC_BASE = "https://api.openai.com/v1"
SECRET_VALUES: set[str] = set()
SPEED_TIERS = {
    "normal": {"label": "Normal", "service_tier": "default"},
    "fast": {"label": "Fast", "service_tier": "priority"},
    "ultrafast": {"label": "Ultrafast", "service_tier": "ultrafast"},
    "flex": {"label": "Flex", "service_tier": "flex"},
}
# Runtime overrides are process-memory only. They never modify Woi/Codex settings.
_connection_lock = threading.RLock()
_connection_mode: str | None = None
_connection_key: str | None = None
_connection_revision = 0
_active_trials = 0

INSTRUCTIONS = (
    "You are a visual coordinate locator in a controlled button test. "
    "Use only the attached screenshot and the user's instruction. "
    "Call screen_action exactly once. For a request to click, use action click; "
    "for a request to move the pointer without clicking, use action move. "
    "Choose a point inside the requested visible button, preferably its center. "
    "Return absolute pixel coordinates in the attached screenshot, with origin "
    "at the top-left, x increasing right and y increasing down. "
    "Do not return normalized coordinates, CSS/desktop coordinates, a label, "
    "an explanation, or any other tool call. Do not guess a target from prior turns; "
    "there are no prior turns."
)
ACTION_TOOL = {
    "type": "function", "name": "screen_action",
    "description": "Click or move the pointer to one position in the supplied screenshot.",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string", "enum": ["click", "move"]},
            "x": {"type": "integer", "description": "Absolute screenshot x pixel."},
            "y": {"type": "integer", "description": "Absolute screenshot y pixel."},
        },
        "required": ["action", "x", "y"], "additionalProperties": False,
    },
}


class LabError(Exception):
    def __init__(self, code: str, message: str, *, status: int = 400):
        super().__init__(message)
        self.code, self.status = code, status



class ProviderTiming:
    """One monotonic timeline per provider call; it never stores request content."""
    def __init__(self, clock=None):
        self.clock = clock or time.monotonic
        self.started = None
        self.request_payload_bytes = None
        self.values = {
            "origin": "provider_request_start", "upload_complete_ms": None,
            "upload_duration_ms": None, "first_token_ms": None,
            "first_output_ms": None, "first_output_source": None,
            "finish_ms": None, "status": "not_started", "upload_measurement": None,
            "note": "No provider request was started; timing stages are unavailable.",
        }

    def start(self, payload_bytes: int, measurement: str, note: str):
        self.request_payload_bytes = payload_bytes
        self.started = self.clock()
        self.values.update(status="running", upload_measurement=measurement, note=note)

    def elapsed(self):
        return None if self.started is None else round((self.clock() - self.started) * 1000, 3)

    def uploaded(self, body_started: float):
        if self.started is None:
            return
        finished = self.clock()
        self.values.update(upload_complete_ms=round((finished - self.started) * 1000, 3),
                           upload_duration_ms=round((finished - body_started) * 1000, 3))

    @staticmethod
    def _nonempty(value):
        return isinstance(value, str) and bool(value.strip())

    @classmethod
    def _has_output(cls, item):
        if not isinstance(item, dict):
            return False
        kind = item.get("type")
        if kind == "function_call":
            return cls._nonempty(item.get("arguments"))
        if kind in ("text", "output_text"):
            return cls._nonempty(item.get("text"))
        if kind == "message":
            return any(cls._has_output(part) for part in (item.get("content") or []) if isinstance(part, dict))
        return False

    def observe(self, event: dict):
        if self.started is None:
            return
        kind = event.get("type")
        # Session/response setup, reasoning, audio and empty deltas aren't model output tokens.
        if kind in ("response.output_text.delta", "response.text.delta", "response.function_call_arguments.delta"):
            if self._nonempty(event.get("delta")):
                elapsed = self.elapsed()
                if self.values["first_token_ms"] is None:
                    self.values["first_token_ms"] = elapsed
                if self.values["first_output_ms"] is None:
                    self.values.update(first_output_ms=elapsed, first_output_source="stream_delta")
            return
        has_final = (
            kind == "response.function_call_arguments.done" and self._nonempty(event.get("arguments"))
            or kind in ("response.output_text.done", "response.text.done") and self._nonempty(event.get("text"))
            or kind == "response.output_item.done" and self._has_output(event.get("item"))
            or kind in ("response.completed", "response.incomplete", "response.failed", "response.done")
            and any(self._has_output(item) for item in ((event.get("response") or {}).get("output") or []))
        )
        if has_final and self.values["first_output_ms"] is None:
            self.values.update(first_output_ms=self.elapsed(), first_output_source="final_only")

    def finish(self, status: str):
        if self.started is not None:
            if self.values["finish_ms"] is None:
                self.values["finish_ms"] = self.elapsed()
            self.values["status"] = status

    def snapshot(self):
        return dict(self.values)


class TimedUploadBody:
    """A single-use body preserving urllib's proxy/TLS defaults and exact JSON bytes.

    http.client sends each yielded chunk before advancing the iterator. Resuming
    after this sole chunk therefore observes client-side sendall completion, not
    server receipt. Explicit Content-Length avoids changing to chunked encoding.
    """
    def __init__(self, payload: bytes, timing: ProviderTiming):
        self.payload, self.timing, self.used = payload, timing, False

    def __iter__(self):
        if self.used:
            raise LabError("request_body_replay", "The lab does not replay a provider request body.", status=502)
        self.used = True
        if not self.payload:
            return
        body_started = self.timing.clock()
        yield self.payload
        self.timing.uploaded(body_started)


def redact(value: object) -> str:
    text = str(value)
    for secret in tuple(SECRET_VALUES):
        if len(secret) >= 8:
            text = text.replace(secret, "<redacted>")
    text = re.sub(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+", "<jwt>", text)
    text = re.sub(r"sk-[A-Za-z0-9_-]{16,}", "sk-<redacted>", text)
    return text


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def settings_path() -> Path:
    override = os.environ.get("WOI_LAB_SETTINGS")
    if override:
        return Path(override).expanduser()
    return Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "woi/settings.json"


def auth_path() -> Path:
    return Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "auth.json"


@dataclass
class Credentials:
    mode: str
    token: str = field(repr=False)
    account_id: str = field(default="", repr=False)
    source: str = ""
    api_base: str = PUBLIC_BASE

    def headers(self) -> dict[str, str]:
        headers = {"Authorization": "Bearer " + self.token}
        if self.mode == "codex":
            headers.update({"originator": "codex_cli_rs", "version": "0.166.0",
                            "User-Agent": "codex_cli_rs/0.166.0 (Linux; x86_64) woi-click-lab"})
            if self.account_id:
                headers["chatgpt-account-id"] = self.account_id
        return headers

    @property
    def responses_url(self) -> str:
        return (CODEX_BASE if self.mode == "codex" else self.api_base) + "/responses"

    @property
    def realtime_url(self) -> str:
        base = PUBLIC_BASE if self.mode == "codex" else self.api_base
        return "wss://" + base.split("://", 1)[1] + "/realtime"

    def public(self) -> dict:
        return {"mode": self.mode, "configured": True, "source": self.source}


def load_credentials() -> Credentials:
    with _connection_lock:
        mode_override, key_override = _connection_mode, _connection_key
    settings = read_json(settings_path())
    auth = read_json(auth_path())
    tokens = auth.get("tokens") or {}
    for value in [auth.get("OPENAI_API_KEY"), settings.get("apiKey"), *tokens.values()]:
        if isinstance(value, str) and len(value) >= 8:
            SECRET_VALUES.add(value)
    env_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if env_key:
        SECRET_VALUES.add(env_key)
    mode = mode_override or os.environ.get("WOI_LAB_AUTH", "auto").lower()
    if mode not in ("auto", "codex", "api"):
        raise LabError("auth_configuration", "WOI_LAB_AUTH must be auto, codex, or api.", status=503)
    if mode == "auto":
        configured_mode = settings.get("backendMode")
        if configured_mode:
            mode = "api" if configured_mode == "apiKey" else "codex"
        else:
            mode = "api" if env_key or auth.get("OPENAI_API_KEY") else "codex"
    if mode == "api":
        key = str(key_override or settings.get("apiKey") or env_key or auth.get("OPENAI_API_KEY") or "").strip()
        if not key:
            raise LabError("auth_missing", "API-key authentication is selected, but no API key is configured.", status=503)
        base = os.environ.get("WOI_LAB_API_BASE", PUBLIC_BASE).rstrip("/")
        parsed = parse.urlsplit(base)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise LabError("auth_configuration", "WOI_LAB_API_BASE must be an HTTPS base URL without credentials or query.", status=503)
        SECRET_VALUES.add(key)
        return Credentials("api", key, source="Temporary lab API key" if key_override else "Woi API settings / OPENAI_API_KEY", api_base=base)
    token = tokens.get("access_token")
    if not isinstance(token, str) or not token:
        raise LabError("auth_missing", "No Codex login is available. Sign in through Woi or configure an API key.", status=503)
    return Credentials("codex", token, str(tokens.get("account_id") or ""), "Woi Codex login (read-only)")



def connection_status() -> dict:
    """Return configuration availability only, never tokens or their hashes."""
    with _connection_lock:
        mode, revision, session_key = _connection_mode, _connection_revision, bool(_connection_key)
        try:
            public = load_credentials().public()
        except LabError as exc:
            if mode is None:
                selected = os.environ.get("WOI_LAB_AUTH", "auto").lower()
                if selected == "auto":
                    settings = read_json(settings_path())
                    selected = "api" if settings.get("backendMode") == "apiKey" or (not settings.get("backendMode") and (os.environ.get("OPENAI_API_KEY") or read_json(auth_path()).get("OPENAI_API_KEY"))) else "codex"
                mode = selected if selected in ("api", "codex") else "codex"
            public = {"mode": mode, "configured": False, "source": "", "reason": redact(exc)}
        return {**public, "auth_mode": public["mode"], "revision": revision,
                "session_key": session_key, "speed_tiers": [
                    {"id": key, **value} for key, value in SPEED_TIERS.items()]}


def configure_connection(payload: object) -> dict:
    global _connection_mode, _connection_key, _connection_revision
    if not isinstance(payload, dict) or set(payload) - {"auth_mode", "api_key"}:
        raise LabError("invalid_connection", "Connection accepts auth_mode and an optional api_key only.")
    mode = payload.get("auth_mode")
    if mode not in ("codex", "api"):
        raise LabError("invalid_connection", "auth_mode must be codex or api.")
    key = payload.get("api_key")
    if "api_key" in payload:
        if mode != "api" or not isinstance(key, str):
            raise LabError("invalid_api_key", "Supply an API key only for the API-key connection.")
        key = key.strip()
        if key and (not 8 <= len(key) <= 4096 or any(ord(c) < 33 or ord(c) > 126 for c in key)):
            raise LabError("invalid_api_key", "API key must contain 8–4096 printable characters without spaces.")
    with _connection_lock:
        if _active_trials:
            raise LabError("connection_busy", "A test is running. Change the connection after it finishes.", status=409)
        _connection_mode = mode
        if "api_key" in payload:
            _connection_key = key or None
            if key:
                SECRET_VALUES.add(key)
        _connection_revision += 1
        return connection_status()


@contextmanager
def connection_lease(expected_revision=None):
    """Keep credential selection fixed while a request is in flight."""
    global _active_trials
    with _connection_lock:
        if expected_revision is not None and expected_revision != _connection_revision:
            raise LabError("connection_changed", "The connection changed. Refresh the model list before another test.", status=409)
        _active_trials += 1
    try:
        yield
    finally:
        with _connection_lock:
            _active_trials -= 1


def credentials_cache_key(creds: Credentials | None) -> tuple:
    if creds is None:
        return ("unavailable", _connection_revision)
    return (creds.mode, creds.api_base, hashlib.sha256((creds.token + creds.account_id).encode()).hexdigest())


def tier_request(trial: dict, transport: str) -> dict:
    speed = trial.get("speed_tier", "normal")
    service_tier = SPEED_TIERS[speed]["service_tier"]
    if transport == "realtime":
        if speed != "normal":
            raise LabError("tier_unsupported_transport", "Realtime does not expose service_tier. Choose Normal or a Responses text model to test this tier; no substitute or fallback request was sent.", status=422)
        service_tier = None
    return {"speed_tier": speed, "requested_service_tier": service_tier,
            "actual_service_tier": None, "tier_status": "unreported",
            "tier_note": "Provider has not reported a tier." if service_tier else "Realtime uses its standard session; the protocol does not expose a service tier."}


def tier_observation(output: dict, result: dict) -> None:
    actual = result.get("actual_service_tier")
    output["actual_service_tier"] = actual if isinstance(actual, str) else None
    if output["actual_service_tier"] is not None:
        equivalent = actual == output["requested_service_tier"] or (output["requested_service_tier"] == "priority" and actual == "fast")
        output["tier_status"] = "reported" if equivalent else "different"
        output["tier_note"] = ("Provider reported the requested tier." if output["tier_status"] == "reported"
                               else "Provider reported a different tier; the requested tier was not confirmed.")


def http_json(url: str, creds: Credentials, timeout: int = 20) -> dict:
    req = request.Request(url, headers={**creds.headers(), "Accept": "application/json"})
    try:
        with request.urlopen(req, timeout=timeout) as response:
            raw = response.read(4 * 1024 * 1024)
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise LabError("catalog_schema", "Model catalog response was not an object.", status=502)
        return data
    except error.HTTPError as exc:
        raise api_error(exc.code, exc.read(4096).decode("utf-8", "replace")) from exc


def api_error(status: int, raw: object) -> LabError:
    text = redact(raw)
    try:
        value = json.loads(text)
        detail = value.get("error", value.get("detail", value))
        text = detail.get("message", json.dumps(detail)) if isinstance(detail, dict) else str(detail)
    except (ValueError, AttributeError):
        pass
    lower = text.lower()
    code = "api_error"
    if status in (401, 403) and re.search(r"service[ _.-]?tier|ultrafast|priority tier|flex tier", lower) and not any(word in lower for word in ("api key", "token", "credential", "bearer")):
        code = "tier_rejected"
    elif status == 401:
        code = "authentication_error"
    elif status == 403:
        code = "access_denied"
    elif status == 429:
        code = "rate_limit"
    elif status in (400, 404, 422):
        if re.search(r"service[ _.-]?tier|ultrafast|priority tier|flex tier", lower):
            code = "tier_rejected"
        elif "image" in lower and any(word in lower for word in ["unsupported", "support", "invalid"]):
            code = "image_unsupported"
        elif any(word in lower for word in ["unknown parameter", "unsupported parameter", "unsupported value", "tool_choice", "tool choice", "reasoning.effort", "parallel_tool_calls"]):
            # An incompatible adapter parameter is a harness error, not proof
            # that the account/model lacks screenshot capability.
            code = "api_request_rejected"
        elif "model" in lower and any(word in lower for word in ["model_not_found", "model not found", "does not exist", "not have access", "not supported"]):
            code = "model_unavailable"
        else:
            code = "api_request_rejected"
    elif status >= 500:
        code = "provider_error"
    return LabError(code, f"HTTP {status}: {text[:500]}", status=502)


_catalog_lock = threading.RLock()
_catalog: dict | None = None
_catalog_time = 0.0
_catalog_key = None
_last_status: dict[tuple, dict] = {}


def app_registered_models() -> list[dict]:
    """Read the actual Woi model registry, not a separately invented model list."""
    try:
        source = (REPO / "app/lib/core/settings/settings.dart").read_text()
    except OSError:
        source = ""
    rows = []
    for name, transport in [("kRealtimeModels", "realtime"), ("kVoiceModels", "live")]:
        match = re.search(r"const\s+" + name + r"\s*=\s*\[(.*?)\];", source, re.S)
        for model in re.findall(r"'([^']+)'", match.group(1) if match else ""):
            rows.append({"id": model, "source": "Woi model registry", "transport": transport})
    settings = read_json(settings_path())
    for key, transport in [("realtimeModel", "realtime"), ("voiceModel", "live"), ("delegateModel", "responses"), ("compressionModel", "responses")]:
        model = settings.get(key)
        if isinstance(model, str) and MODEL_RE.fullmatch(model):
            rows.append({"id": model, "source": "Woi selected model", "transport": transport})
    return rows


def image_detail_policy() -> str:
    policy = os.environ.get("WOI_LAB_IMAGE_DETAIL", "auto").lower()
    if policy not in ("auto", "high", "original"):
        raise LabError("image_detail_configuration", "WOI_LAB_IMAGE_DETAIL must be auto, high, or original.", status=503)
    return policy


def select_image_detail(model: dict) -> str:
    """Keep image bytes unchanged and explicitly select the provider detail mode.

    Original detail preserves the coordinate space for supported Responses
    models. Realtime does not support original and uses high in auto mode.
    An explicit unsupported original request fails; it never silently falls back.
    """
    policy = image_detail_policy()
    is_responses = model.get("transport") == "responses"
    capability = model.get("supports_image_detail_original")
    supports_original = is_responses and capability is True
    if policy == "original" and (not is_responses or capability is False):
        raise LabError("unsupported_image_detail", "Original image detail is unsupported by this transport or catalog entry. Use auto or high; no fallback was applied.", status=422)
    return "original" if policy == "original" or (policy == "auto" and supports_original) else "high"


def model_entry(raw: dict, source: str) -> dict | None:
    model = raw.get("slug") or raw.get("id")
    if not isinstance(model, str) or not MODEL_RE.fullmatch(model):
        return None
    modalities = raw.get("input_modalities")
    transport = raw.get("transport")
    if not transport:
        if "realtime" in model:
            transport = "realtime"
        elif model.startswith("gpt-live"):
            transport = "live"
        elif any(part in model for part in ("audio", "transcribe", "tts", "whisper")):
            transport = "audio_only"
        elif isinstance(modalities, list) or model.startswith(("gpt-", "chatgpt-", "o1", "o3", "o4", "computer-use", "codex-")):
            transport = "responses"
        else:
            transport = "other"
    if any(part in model for part in ("embedding", "moderation", "gpt-image", "dall-e", "sora")):
        transport = "other"
    available, reason = True, ""
    if transport == "live":
        available = False
        reason = "GPT-Live uses delegated tools. The current gpt-live-1.1 endpoint rejects native image input and session tool registration. Woi can execute explicit client actions; screenshot-based targeting needs an image-capable delegate. This direct-model lab does not substitute Luna or another model."
    elif transport in ("audio_only", "other"):
        available = False
        reason = "This model is not a direct text-plus-screenshot coordinate model."
    elif isinstance(modalities, list) and "image" not in modalities:
        available = False
        reason = "Catalog does not list image input support."
    elif model.startswith(("gpt-3.5", "gpt-4-0314", "gpt-4-0613", "gpt-4-32k")) or model == "gpt-4":
        available = False
        reason = "This legacy model does not accept screenshot input."
    levels = raw.get("supported_reasoning_levels") or []
    supported = [v.get("effort") for v in levels if isinstance(v, dict)]
    # Matched low-effort comparison, not model-dependent defaults; never cap reasoning tokens.
    effort = "low" if "low" in supported else None
    return {"id": model, "name": raw.get("display_name") or model,
            "kind": "audio" if transport in ("realtime", "live", "audio_only") else "text" if transport == "responses" else "other",
            "transport": transport, "available": available, "reason": reason,
            "source": source, "availability": "listed" if "catalog" in source else "candidate",
            "input_modalities": modalities, "visibility": raw.get("visibility", "list"),
            "supports_image_detail_original": raw.get("supports_image_detail_original") if isinstance(raw.get("supports_image_detail_original"), bool) else None,
            "reasoning_effort": effort, "test_status": "untested"}


def discover_models(force: bool = False) -> dict:
    with connection_lease():
        return _discover_models(force=force)


def _discover_models(force: bool = False) -> dict:
    global _catalog, _catalog_time, _catalog_key
    connection = connection_status()
    try:
        creds = load_credentials()
        public_auth = creds.public()
    except LabError as exc:
        creds = None
        public_auth = {"mode": connection["auth_mode"], "configured": False, "reason": redact(exc)}
    cache_key = credentials_cache_key(creds)
    with _catalog_lock:
        if _catalog is not None and _catalog_key == cache_key and not force and time.monotonic() - _catalog_time < 300:
            result = copy.deepcopy(_catalog)
        else:
            rows, warnings = [], []
            if creds:
                url = CODEX_BASE + "/models?client_version=0.166.0" if creds.mode == "codex" else creds.api_base + "/models"
                try:
                    data = http_json(url, creds)
                    entries = data.get("models", data.get("data", []))
                    rows.extend((r, "live Codex catalog" if creds.mode == "codex" else "live API catalog") for r in entries if isinstance(r, dict))
                except Exception as exc:
                    warnings.append("Model discovery: " + redact(exc)[:500])
                if creds.mode == "codex":
                    try:
                        data = http_json(PUBLIC_BASE + "/models", creds)
                        rows.extend((r, "live API catalog") for r in data.get("data", []) if isinstance(r, dict))
                    except Exception as exc:
                        warnings.append("Public API model catalog: " + redact(exc)[:500] + " Audio candidates come from Woi's registry.")
            if not rows and (creds is None or creds.mode == "codex"):
                cached = read_json(auth_path().parent / "models_cache.json")
                rows.extend((r, "cached Codex catalog") for r in cached.get("models", []) if isinstance(r, dict))
                if rows:
                    warnings.append("Using the existing Codex model cache because live discovery was unavailable.")
            rows.extend((r, r["source"]) for r in app_registered_models())
            by_id = {}
            for raw, source in rows:
                row = model_entry(raw, source)
                if row and row["id"] not in by_id:
                    if not creds:
                        row.update(available=False, reason=public_auth.get("reason", "No credentials"))
                    by_id[row["id"]] = row
            result = {"models": list(by_id.values()), "auth": public_auth,
                      "source": sorted(set(r["source"] for r in by_id.values())),
                      "warnings": warnings, "discovered_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                      "notes": "Listed or registered models are candidates; access and screenshot support are verified per trial."}
            _catalog, _catalog_time, _catalog_key = copy.deepcopy(result), time.monotonic(), cache_key
        result["protocol"] = PROTOCOL_VERSION
        result["connection"] = connection
        result["speed_tiers"] = connection["speed_tiers"]
        result["image_detail_policy"] = image_detail_policy()
        for row in result["models"]:
            row["tier_results"] = {speed: copy.deepcopy(_last_status[(cache_key, row["id"], speed)])
                                   for speed in SPEED_TIERS if (cache_key, row["id"], speed) in _last_status}
            # A rejected experimental tier does not mark the model itself unavailable.
            row.update(_last_status.get((cache_key, row["id"], "normal"), {}))
            try:
                row["image_detail"] = select_image_detail(row) if row["transport"] in ("responses", "realtime") else None
            except LabError as exc:
                row["image_detail"] = None
                row["image_detail_error"] = str(exc)
        return result


def _finite_number(value: object) -> bool:
    # Python integers are finite even when converting them to float overflows.
    # Bounds checks reject oversized integers without crashing validation.
    return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and math.isfinite(value))


def png_dimensions(data: bytes) -> tuple[int, int]:
    if not data.startswith(b"\x89PNG\r\n\x1a\n") or len(data) < 45:
        raise LabError("invalid_screenshot", "Screenshot must be a valid PNG.")
    offset, width, height, seen_idat, ended = 8, 0, 0, False, False
    while offset + 12 <= len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        tag = data[offset + 4:offset + 8]
        end = offset + 12 + size
        if size > MAX_IMAGE_BYTES or end > len(data):
            raise LabError("invalid_screenshot", "Truncated PNG chunk.")
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        if zlib.crc32(tag + payload) & 0xffffffff != crc:
            raise LabError("invalid_screenshot", "PNG checksum mismatch.")
        if offset == 8:
            if tag != b"IHDR" or size != 13:
                raise LabError("invalid_screenshot", "PNG does not begin with IHDR.")
            width, height = struct.unpack_from(">II", payload)
            if not 16 <= width <= 8192 or not 16 <= height <= 8192 or width * height > MAX_PIXELS:
                raise LabError("invalid_screenshot", "PNG dimensions exceed the 16-megapixel test limit.")
        elif tag == b"IHDR":
            raise LabError("invalid_screenshot", "PNG has multiple IHDR chunks.")
        if tag == b"IDAT":
            seen_idat = True
        if tag == b"IEND":
            if size != 0 or end != len(data):
                raise LabError("invalid_screenshot", "Invalid PNG ending.")
            ended = True
            break
        offset = end
    if not ended or not seen_idat:
        raise LabError("invalid_screenshot", "PNG is missing image data or its ending.")
    return width, height


def validate_trial(payload: object) -> dict:
    if not isinstance(payload, dict):
        raise LabError("invalid_request", "Request must be a JSON object.")
    allowed = {"model", "instruction", "screenshot", "width", "height", "screen", "request_id", "speed_tier", "connection_revision"}
    if set(payload) - allowed:
        raise LabError("unexpected_fields", "Trial accepts only model, instruction, screenshot, dimensions, screen, request_id, speed_tier, and connection_revision. No target data or history.")
    model, instruction, request_id = payload.get("model"), payload.get("instruction"), payload.get("request_id")
    if not isinstance(model, str) or not MODEL_RE.fullmatch(model):
        raise LabError("invalid_model", "Invalid model identifier.")
    if not isinstance(instruction, str) or not 1 <= len(instruction.strip()) <= 2000:
        raise LabError("invalid_instruction", "Instruction must contain 1–2000 characters.")
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
        raise LabError("invalid_request_id", "A valid fresh request_id is required.")
    speed_tier = payload.get("speed_tier", "normal")
    if not isinstance(speed_tier, str) or speed_tier not in SPEED_TIERS:
        raise LabError("invalid_speed_tier", "speed_tier must be normal, fast, ultrafast, or flex.")
    revision = payload.get("connection_revision")
    if "connection_revision" in payload and (isinstance(revision, bool) or not isinstance(revision, int) or revision < 0):
        raise LabError("invalid_connection_revision", "connection_revision must be a nonnegative integer.")
    width, height = payload.get("width"), payload.get("height")
    if any(isinstance(v, bool) or not isinstance(v, int) for v in (width, height)):
        raise LabError("invalid_dimensions", "Screenshot width and height must be integers.")
    screenshot = payload.get("screenshot")
    prefix = "data:image/png;base64,"
    if not isinstance(screenshot, str) or not screenshot.startswith(prefix) or len(screenshot) > MAX_IMAGE_BYTES * 4 // 3 + 100:
        raise LabError("invalid_screenshot", "Supply a PNG data URL no larger than 6 MiB.")
    try:
        png = base64.b64decode(screenshot[len(prefix):], validate=True)
    except (ValueError, binascii.Error) as exc:
        raise LabError("invalid_screenshot", "Invalid screenshot base64.") from exc
    if len(png) > MAX_IMAGE_BYTES:
        raise LabError("invalid_screenshot", "Screenshot exceeds 6 MiB.")
    if png_dimensions(png) != (width, height):
        raise LabError("dimension_mismatch", "Declared dimensions do not match the transmitted PNG.")
    screen = payload.get("screen")
    if not isinstance(screen, dict) or set(screen) != {"width", "height", "devicePixelRatio"}:
        raise LabError("invalid_screen", "screen must contain width, height, and devicePixelRatio only.")
    if any(not _finite_number(screen.get(k)) or not 1 <= screen[k] <= 32768 for k in ("width", "height")):
        raise LabError("invalid_screen", "Invalid screen resolution.")
    if not _finite_number(screen.get("devicePixelRatio")) or not 0.25 <= screen["devicePixelRatio"] <= 8:
        raise LabError("invalid_screen", "Invalid devicePixelRatio.")
    return {**payload, "speed_tier": speed_tier, "instruction": instruction.strip(), "image_sha256": hashlib.sha256(png).hexdigest(), "image_bytes": len(png)}


def input_item(trial: dict, *, detail: str = "high") -> dict:
    screen = trial["screen"]
    note = (f"Screenshot resolution: {trial['width']} x {trial['height']} pixels. "
            f"Reported display resolution: {screen['width']} x {screen['height']} CSS pixels; "
            f"devicePixelRatio: {screen['devicePixelRatio']}. "
            "The screenshot covers only the controlled test surface. Return screenshot pixel coordinates; "
            "do not use display pixels or apply devicePixelRatio.\nUser instruction: " + trial["instruction"])
    return {"type": "message", "role": "user", "content": [
        {"type": "input_image", "image_url": trial["screenshot"], "detail": detail},
        {"type": "input_text", "text": note},
    ]}


def parse_action(calls: list[dict], width: int, height: int) -> dict:
    if len(calls) != 1 or calls[0].get("name") != "screen_action":
        raise LabError("invalid_output", "Model must return exactly one screen_action call.", status=422)
    arguments = calls[0].get("arguments")
    try:
        action = json.loads(arguments) if isinstance(arguments, str) else arguments
    except (ValueError, TypeError) as exc:
        raise LabError("invalid_output", "Model returned invalid tool JSON.", status=422) from exc
    if not isinstance(action, dict) or set(action) != {"action", "x", "y"} or action.get("action") not in ("click", "move"):
        raise LabError("invalid_output", "Model tool must contain only action, x, and y.", status=422)
    if not _finite_number(action["x"]) or not _finite_number(action["y"]):
        raise LabError("invalid_coordinates", "Model coordinates are not finite numbers.", status=422)
    if not (0 <= action["x"] < width and 0 <= action["y"] < height):
        raise LabError("out_of_bounds", "Model coordinates are outside the screenshot; no clamping was applied.", status=422)
    return action


def responses_payload(trial: dict, model: dict) -> dict:
    detail = model.get("selected_image_detail") or select_image_detail(model)
    body = {"model": trial["model"], "instructions": INSTRUCTIONS, "input": [input_item(trial, detail=detail)],
            "tools": [copy.deepcopy(ACTION_TOOL)], "tool_choice": "required", "parallel_tool_calls": False,
            "stream": True, "store": False,
            "service_tier": SPEED_TIERS[trial.get("speed_tier", "normal")]["service_tier"]}
    if model.get("reasoning_effort"):
        body["reasoning"] = {"effort": model["reasoning_effort"]}
    # No previous_response_id, conversation, prompt cache key, or replayed messages.
    return body


def responses_trial(trial: dict, model: dict, creds: Credentials, *, timing: ProviderTiming | None = None) -> dict:
    timing = timing or ProviderTiming()
    payload = json.dumps(responses_payload(trial, model)).encode()
    timeout = FLEX_TIMEOUT if trial.get("speed_tier") == "flex" else TRIAL_TIMEOUT
    headers = {**creds.headers(), "Content-Type": "application/json", "Accept": "text/event-stream",
               "Content-Length": str(len(payload))}
    req = request.Request(creds.responses_url, data=TimedUploadBody(payload, timing), headers=headers, method="POST")
    result = {"calls": [], "text": "", "usage": None, "resolved_model": None, "provider_status": None}
    timing.start(len(payload), "http.client.body_send_returned",
                 "Offsets start before the provider HTTP request. Upload is client body-send completion, not provider receipt; "
                 "its offset includes connection setup, while upload_duration_ms covers the body send only. "
                 "request_payload_bytes is UTF-8 JSON bytes, excluding HTTP/TLS overhead.")
    started = time.monotonic()
    completed, raw_bytes = False, 0
    try:
        with request.urlopen(req, timeout=timeout) as response:
            for raw in response:
                raw_bytes += len(raw)
                if raw_bytes > 4 * 1024 * 1024:
                    raise LabError("provider_response_limit", "Provider response exceeded 4 MiB.", status=502)
                if time.monotonic() - started > timeout:
                    raise LabError("timeout", "Responses request timed out.", status=504)
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data or data == "[DONE]":
                    continue
                event = json.loads(data)
                timing.observe(event)
                kind = event.get("type")
                if kind in ("response.created", "response.in_progress"):
                    r = event.get("response") or {}
                    result["resolved_model"] = r.get("model", result["resolved_model"])
                    if isinstance(r.get("service_tier"), str):
                        result["actual_service_tier"] = r["service_tier"]
                elif kind == "response.output_text.delta":
                    result["text"] += str(event.get("delta") or "")[:8192]
                elif kind == "response.output_item.done" and (event.get("item") or {}).get("type") == "function_call":
                    item = event["item"]
                    result["calls"].append({"name": item.get("name"), "arguments": item.get("arguments")})
                elif kind in ("response.completed", "response.incomplete", "response.failed"):
                    r = event.get("response") or {}
                    result.update(usage=r.get("usage"), provider_status=r.get("status"), resolved_model=r.get("model", result["resolved_model"]))
                    if isinstance(r.get("service_tier"), str):
                        result["actual_service_tier"] = r["service_tier"]
                    final_calls = [{"name": x.get("name"), "arguments": x.get("arguments")} for x in r.get("output", []) if x.get("type") == "function_call"]
                    if final_calls:
                        result["calls"] = final_calls
                    if kind != "response.completed" or r.get("status") not in (None, "completed"):
                        raise LabError("provider_" + (r.get("status") or "failed"), redact(r.get("error") or r.get("incomplete_details") or "Provider did not complete."), status=502)
                    timing.finish("completed")
                    completed = True
                    break
                elif kind == "error":
                    raise LabError("provider_error", redact(event.get("message") or event.get("error") or "Provider error")[:500], status=502)
        if not completed:
            raise LabError("incomplete_stream", "Responses stream closed before completion.", status=502)
    except error.HTTPError as exc:
        try:
            message = exc.read(4096).decode("utf-8", "replace")
        finally:
            timing.finish("error")
        raise api_error(exc.code, message) from exc
    except (TimeoutError, OSError) as exc:
        timing.finish("error")
        raise LabError("transport_error", redact(exc)[:500], status=502) from exc
    except Exception:
        timing.finish("error")
        raise
    result.update(timing=timing.snapshot(), request_payload_bytes=timing.request_payload_bytes)
    return result


def realtime_payloads(trial: dict, *, detail: str = "high") -> tuple[dict, dict]:
    session = {"type": "session.update", "session": {
        "type": "realtime", "instructions": INSTRUCTIONS, "output_modalities": ["text"],
        "audio": {"input": {"turn_detection": None}},
        "tools": [copy.deepcopy(ACTION_TOOL)], "tool_choice": "required",
    }}
    response = {"type": "response.create", "response": {
        "conversation": "none", "input": [input_item(trial, detail=detail)], "output_modalities": ["text"],
        "instructions": INSTRUCTIONS, "tools": [copy.deepcopy(ACTION_TOOL)], "tool_choice": "required",
    }}
    return session, response


async def realtime_trial(trial: dict, model: dict, creds: Credentials, *, timing: ProviderTiming | None = None) -> dict:
    timing = timing or ProviderTiming()
    try:
        import websockets
    except ImportError as exc:
        raise LabError("dependency_missing", "Install websockets or run with Woi's research Python environment.", status=503) from exc
    url = creds.realtime_url + "?" + parse.urlencode({"model": trial["model"]})
    detail = model.get("selected_image_detail") or select_image_detail({**model, "transport": "realtime"})
    session_payload, response_payload = realtime_payloads(trial, detail=detail)
    session_json, response_json = json.dumps(session_payload), json.dumps(response_payload)
    result = {"calls": [], "text": "", "usage": None, "resolved_model": None, "provider_status": None}
    deadline = time.monotonic() + TRIAL_TIMEOUT

    async def recv(ws):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise LabError("timeout", "Realtime trial timed out.", status=504)
        event = json.loads(await asyncio.wait_for(ws.recv(), timeout=remaining))
        if event.get("type") == "error":
            detail = event.get("error") or {}
            code = str(detail.get("code", "realtime_error"))
            message = redact(detail.get("message") or detail)[:500]
            mapped = "image_unsupported" if "image" in message.lower() and "support" in message.lower() else "model_unavailable" if code in ("model_not_found", "invalid_model") else "api_request_rejected"
            raise LabError(mapped, f"{code}: {message}", status=502)
        return event

    timing.start(len(session_json.encode()) + len(response_json.encode()), "websocket.send_returned",
                 "Offsets start before the fresh WebSocket connection. Upload is response.create send completion, not provider receipt; "
                 "its offset includes connection/session setup, while upload_duration_ms covers that image/prompt message send only. "
                 "request_payload_bytes sums session.update and response.create UTF-8 JSON bytes, excluding WebSocket/TLS overhead.")
    try:
        # A new connection is opened and closed for every trial, including failures.
        async with websockets.connect(url, additional_headers=creds.headers(), open_timeout=20,
                                      close_timeout=3, max_size=4 * 1024 * 1024) as ws:
            while True:
                event = await recv(ws)
                if event.get("type") == "session.created":
                    result["resolved_model"] = (event.get("session") or {}).get("model")
                    break
            await ws.send(session_json)
            while (await recv(ws)).get("type") != "session.updated":
                pass
            body_started = timing.clock()
            await ws.send(response_json)
            timing.uploaded(body_started)
            while True:
                event = await recv(ws)
                timing.observe(event)
                kind = event.get("type")
                if kind == "response.function_call_arguments.done":
                    result["calls"].append({"name": event.get("name"), "arguments": event.get("arguments")})
                elif kind in ("response.output_text.done", "response.text.done"):
                    result["text"] += str(event.get("text") or "")[:8192]
                elif kind == "response.done":
                    response = event.get("response") or {}
                    result.update(usage=response.get("usage"), provider_status=response.get("status"))
                    final_calls = [{"name": x.get("name"), "arguments": x.get("arguments")} for x in response.get("output", []) if x.get("type") == "function_call"]
                    if final_calls:
                        result["calls"] = final_calls
                    if response.get("status") != "completed":
                        raise LabError("provider_" + str(response.get("status", "failed")), redact(response.get("status_details") or "Realtime response did not complete.")[:500], status=502)
                    timing.finish("completed")
                    result.update(timing=timing.snapshot(), request_payload_bytes=timing.request_payload_bytes)
                    return result
    except Exception:
        timing.finish("error")
        raise


def run_trial(payload: object) -> dict:
    trial = validate_trial(payload)
    with connection_lease(trial.get("connection_revision")):
        return _run_trial(trial)


def _run_trial(trial: dict) -> dict:
    catalog = discover_models()
    model = next((m for m in catalog["models"] if m["id"] == trial["model"]), None)
    if model is None:
        raise LabError("unknown_model", "Model was not found in the available catalog or Woi model registry.")
    started = time.monotonic()
    output = {"request_id": trial["request_id"], "model": trial["model"], "resolved_model": None,
              "action": None, "x": None, "y": None, "latency_ms": None, "usage": None, "error": None,
              "error_code": None, "transport": model["transport"], "fresh_context": True,
              "image_sha256": trial["image_sha256"], "image_bytes": trial["image_bytes"],
              "width": trial["width"], "height": trial["height"], "screen": trial["screen"],
              "reasoning_effort": model.get("reasoning_effort"), "prompt_sha256": hashlib.sha256(INSTRUCTIONS.encode()).hexdigest(),
              "raw_output": None, "endpoint": None, "protocol": PROTOCOL_VERSION,
              "image_detail_policy": image_detail_policy(), "image_detail": None}
    creds = None
    timing = ProviderTiming()
    output["request_image_bytes"] = trial["image_bytes"]
    output.update(speed_tier=trial["speed_tier"], requested_service_tier=SPEED_TIERS[trial["speed_tier"]]["service_tier"],
                  actual_service_tier=None, tier_status="unreported", tier_note="Provider has not reported a tier.",
                  connection_revision=_connection_revision, auth_mode=catalog["auth"]["mode"],
                  timeout_ms=(FLEX_TIMEOUT if trial["speed_tier"] == "flex" else TRIAL_TIMEOUT) * 1000)
    try:
        creds = load_credentials()
        output["auth_mode"] = creds.mode
        output["endpoint"] = creds.realtime_url if model["transport"] == "realtime" else creds.responses_url
        output.update(tier_request(trial, model["transport"]))
        if not model["available"]:
            raise LabError("unsupported_capability", model["reason"], status=422)
        detail = select_image_detail(model)
        model = {**model, "selected_image_detail": detail}
        output["image_detail"] = detail
        if model["transport"] == "realtime":
            result = asyncio.run(realtime_trial(trial, model, creds, timing=timing))
        elif model["transport"] == "responses":
            result = responses_trial(trial, model, creds, timing=timing)
        else:
            raise LabError("unsupported_capability", "This model does not support direct screenshot trials.", status=422)
        output.update(usage=result.get("usage"), resolved_model=result.get("resolved_model"),
                      raw_output=json.loads(redact(json.dumps(result))), provider_status=result.get("provider_status"))
        tier_observation(output, result)
        output.update(parse_action(result["calls"], trial["width"], trial["height"]))
    except LabError as exc:
        output.update(error=redact(exc)[:600], error_code=exc.code)
        if exc.code == "tier_unsupported_transport":
            output.update(requested_service_tier=None, tier_status="unsupported", tier_note=str(exc))
        elif exc.code == "tier_rejected" or (exc.code.startswith(("api_", "provider_")) and re.search(r"service[ _.-]?tier|ultrafast|priority|flex tier", str(exc), re.I)):
            output.update(error_code="tier_rejected", tier_status="rejected", tier_note="Provider rejected the selected tier; no fallback was attempted.")
    except Exception as exc:
        # WebSocket HTTP errors expose a response status but must never expose headers.
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", None)
        if status:
            mapped = api_error(status, f"Realtime connection rejected with HTTP {status}")
            output.update(error=str(mapped), error_code=mapped.code)
        else:
            output.update(error=redact(f"{type(exc).__name__}: {exc}")[:600], error_code="transport_error")
    output.update(timing=timing.snapshot(), request_payload_bytes=timing.request_payload_bytes)
    output["latency_ms"] = round((time.monotonic() - started) * 1000, 1)
    with _catalog_lock:
        _last_status[(credentials_cache_key(creds), trial["model"], trial["speed_tier"])] = {"test_status": output["error_code"] or "responded", "last_error": output["error"], "tier_status": output["tier_status"], "actual_service_tier": output["actual_service_tier"]}
    return output
