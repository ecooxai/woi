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
from urllib import error, parse, request
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
REQUEST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
MAX_IMAGE_BYTES = 6 * 1024 * 1024
MAX_PIXELS = 16_777_216
TRIAL_TIMEOUT = 120
PROTOCOL_VERSION = "screenshot-only-v2"
CODEX_BASE = "https://chatgpt.com/backend-api/codex"
PUBLIC_BASE = "https://api.openai.com/v1"
SECRET_VALUES: set[str] = set()
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
    settings = read_json(settings_path())
    auth = read_json(auth_path())
    tokens = auth.get("tokens") or {}
    for value in [auth.get("OPENAI_API_KEY"), settings.get("apiKey"), *tokens.values()]:
        if isinstance(value, str) and len(value) >= 8:
            SECRET_VALUES.add(value)
    env_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if env_key:
        SECRET_VALUES.add(env_key)
    mode = os.environ.get("WOI_LAB_AUTH", "auto").lower()
    if mode not in ("auto", "codex", "api"):
        raise LabError("auth_configuration", "WOI_LAB_AUTH must be auto, codex, or api.", status=503)
    if mode == "auto":
        configured_mode = settings.get("backendMode")
        if configured_mode:
            mode = "api" if configured_mode == "apiKey" else "codex"
        else:
            mode = "api" if env_key or auth.get("OPENAI_API_KEY") else "codex"
    if mode == "api":
        key = str(settings.get("apiKey") or env_key or auth.get("OPENAI_API_KEY") or "").strip()
        if not key:
            raise LabError("auth_missing", "Woi selects API-key authentication, but no API key is configured.", status=503)
        base = os.environ.get("WOI_LAB_API_BASE", PUBLIC_BASE).rstrip("/")
        parsed = parse.urlsplit(base)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise LabError("auth_configuration", "WOI_LAB_API_BASE must be an HTTPS base URL without credentials or query.", status=503)
        SECRET_VALUES.add(key)
        return Credentials("api", key, source="Woi API settings / OPENAI_API_KEY", api_base=base)
    token = tokens.get("access_token")
    if not isinstance(token, str) or not token:
        raise LabError("auth_missing", "No Codex login is available. Sign in through Woi or configure an API key.", status=503)
    return Credentials("codex", token, str(tokens.get("account_id") or ""), "Woi Codex login (read-only)")


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
    if status == 401:
        code = "authentication_error"
    elif status == 403:
        code = "access_denied"
    elif status == 429:
        code = "rate_limit"
    elif status in (400, 404):
        if "image" in lower and any(word in lower for word in ["unsupported", "support", "invalid"]):
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
_last_status: dict[str, dict] = {}


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
        reason = "Live audio does not accept screenshots directly; vision is performed by a separate delegated text model."
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
    global _catalog, _catalog_time
    with _catalog_lock:
        if _catalog is not None and not force and time.monotonic() - _catalog_time < 300:
            result = copy.deepcopy(_catalog)
        else:
            rows, warnings = [], []
            try:
                creds = load_credentials()
                public_auth = creds.public()
            except LabError as exc:
                creds = None
                public_auth = {"mode": "unavailable", "configured": False, "reason": redact(exc)}
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
            _catalog, _catalog_time = copy.deepcopy(result), time.monotonic()
        result["protocol"] = PROTOCOL_VERSION
        result["image_detail_policy"] = image_detail_policy()
        for row in result["models"]:
            row.update(_last_status.get(row["id"], {}))
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
    allowed = {"model", "instruction", "screenshot", "width", "height", "screen", "request_id"}
    if set(payload) - allowed:
        raise LabError("unexpected_fields", "Trial accepts only model, instruction, screenshot, dimensions, screen, and request_id. No target data or history.")
    model, instruction, request_id = payload.get("model"), payload.get("instruction"), payload.get("request_id")
    if not isinstance(model, str) or not MODEL_RE.fullmatch(model):
        raise LabError("invalid_model", "Invalid model identifier.")
    if not isinstance(instruction, str) or not 1 <= len(instruction.strip()) <= 2000:
        raise LabError("invalid_instruction", "Instruction must contain 1–2000 characters.")
    if not isinstance(request_id, str) or not REQUEST_RE.fullmatch(request_id):
        raise LabError("invalid_request_id", "A valid fresh request_id is required.")
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
    return {**payload, "instruction": instruction.strip(), "image_sha256": hashlib.sha256(png).hexdigest(), "image_bytes": len(png)}


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
            "stream": True, "store": False}
    if model.get("reasoning_effort"):
        body["reasoning"] = {"effort": model["reasoning_effort"]}
    # No previous_response_id, conversation, prompt cache key, or replayed messages.
    return body


def responses_trial(trial: dict, model: dict, creds: Credentials) -> dict:
    body = responses_payload(trial, model)
    headers = {**creds.headers(), "Content-Type": "application/json", "Accept": "text/event-stream"}
    req = request.Request(creds.responses_url, data=json.dumps(body).encode(), headers=headers, method="POST")
    result = {"calls": [], "text": "", "usage": None, "resolved_model": None, "provider_status": None}
    started = time.monotonic()
    completed, raw_bytes = False, 0
    try:
        with request.urlopen(req, timeout=TRIAL_TIMEOUT) as response:
            for raw in response:
                raw_bytes += len(raw)
                if raw_bytes > 4 * 1024 * 1024:
                    raise LabError("provider_response_limit", "Provider response exceeded 4 MiB.", status=502)
                if time.monotonic() - started > TRIAL_TIMEOUT:
                    raise LabError("timeout", "Responses request timed out.", status=504)
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data or data == "[DONE]":
                    continue
                event = json.loads(data)
                kind = event.get("type")
                if kind in ("response.created", "response.in_progress"):
                    r = event.get("response") or {}
                    result["resolved_model"] = r.get("model", result["resolved_model"])
                elif kind == "response.output_text.delta":
                    result["text"] += str(event.get("delta") or "")[:8192]
                elif kind == "response.output_item.done" and (event.get("item") or {}).get("type") == "function_call":
                    item = event["item"]
                    result["calls"].append({"name": item.get("name"), "arguments": item.get("arguments")})
                elif kind in ("response.completed", "response.incomplete", "response.failed"):
                    r = event.get("response") or {}
                    result.update(usage=r.get("usage"), provider_status=r.get("status"), resolved_model=r.get("model", result["resolved_model"]))
                    final_calls = [{"name": x.get("name"), "arguments": x.get("arguments")} for x in r.get("output", []) if x.get("type") == "function_call"]
                    if final_calls:
                        result["calls"] = final_calls
                    if kind != "response.completed" or r.get("status") not in (None, "completed"):
                        raise LabError("provider_" + (r.get("status") or "failed"), redact(r.get("error") or r.get("incomplete_details") or "Provider did not complete."), status=502)
                    completed = True
                    break
                elif kind == "error":
                    raise LabError("provider_error", redact(event.get("message") or event.get("error") or "Provider error")[:500], status=502)
    except error.HTTPError as exc:
        raise api_error(exc.code, exc.read(4096).decode("utf-8", "replace")) from exc
    except (TimeoutError, OSError) as exc:
        raise LabError("transport_error", redact(exc)[:500], status=502) from exc
    if not completed:
        raise LabError("incomplete_stream", "Responses stream closed before completion.", status=502)
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


async def realtime_trial(trial: dict, model: dict, creds: Credentials) -> dict:
    try:
        import websockets
    except ImportError as exc:
        raise LabError("dependency_missing", "Install websockets or run with Woi's research Python environment.", status=503) from exc
    url = creds.realtime_url + "?" + parse.urlencode({"model": trial["model"]})
    detail = model.get("selected_image_detail") or select_image_detail({**model, "transport": "realtime"})
    session_payload, response_payload = realtime_payloads(trial, detail=detail)
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

    # A new connection is opened and closed for every trial, including failures.
    async with websockets.connect(url, additional_headers=creds.headers(), open_timeout=20,
                                  close_timeout=3, max_size=4 * 1024 * 1024) as ws:
        while True:
            event = await recv(ws)
            if event.get("type") == "session.created":
                result["resolved_model"] = (event.get("session") or {}).get("model")
                break
        await ws.send(json.dumps(session_payload))
        while (await recv(ws)).get("type") != "session.updated":
            pass
        await ws.send(json.dumps(response_payload))
        while True:
            event = await recv(ws)
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
                return result


def run_trial(payload: object) -> dict:
    trial = validate_trial(payload)
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
    try:
        if not model["available"]:
            raise LabError("unsupported_capability", model["reason"], status=422)
        detail = select_image_detail(model)
        model = {**model, "selected_image_detail": detail}
        output["image_detail"] = detail
        creds = load_credentials()
        output["auth_mode"] = creds.mode
        output["endpoint"] = creds.realtime_url if model["transport"] == "realtime" else creds.responses_url
        if model["transport"] == "realtime":
            result = asyncio.run(realtime_trial(trial, model, creds))
        elif model["transport"] == "responses":
            result = responses_trial(trial, model, creds)
        else:
            raise LabError("unsupported_capability", "This model does not support direct screenshot trials.", status=422)
        output.update(usage=result.get("usage"), resolved_model=result.get("resolved_model"),
                      raw_output=json.loads(redact(json.dumps(result))), provider_status=result.get("provider_status"))
        output.update(parse_action(result["calls"], trial["width"], trial["height"]))
    except LabError as exc:
        output.update(error=redact(exc)[:600], error_code=exc.code)
    except Exception as exc:
        # WebSocket HTTP errors expose a response status but must never expose headers.
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", None)
        if status:
            mapped = api_error(status, f"Realtime connection rejected with HTTP {status}")
            output.update(error=str(mapped), error_code=mapped.code)
        else:
            output.update(error=redact(f"{type(exc).__name__}: {exc}")[:600], error_code="transport_error")
    output["latency_ms"] = round((time.monotonic() - started) * 1000, 1)
    with _catalog_lock:
        _last_status[trial["model"]] = {"test_status": output["error_code"] or "responded", "last_error": output["error"]}
    return output
