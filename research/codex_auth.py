"""Shared helpers: load Codex ChatGPT auth from ~/.codex/auth.json, build headers,
refresh tokens, and redact secrets from anything we print.

Never print raw tokens. Use `redact()` on any string that might contain them.

Verified 2026-11-02 against Codex CLI 0.166.0 source (codex-rs/login/src/auth/manager.rs):
refresh = POST https://auth.openai.com/oauth/token, JSON body {client_id, grant_type, refresh_token};
a bogus refresh token returns 401 {"error":{"code":"invalid_refresh_token",...}}.
The ChatGPT access token (aud https://api.openai.com/v1) is accepted as a Bearer by
wss://api.openai.com/v1/realtime and /v1/live; chatgpt-account-id is required for chatgpt.com.
"""
from __future__ import annotations

import base64
import json
import os
import platform
import re
import time
from pathlib import Path

AUTH_PATH = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "auth.json"
CHATGPT_BASE = "https://chatgpt.com/backend-api/codex"
OPENAI_BASE = "https://api.openai.com/v1"
REFRESH_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"  # Codex CLI OAuth client id (public)
CODEX_VERSION = "0.166.0"
ORIGINATOR = "codex_cli_rs"

_SECRETS: list[str] = []


def load_auth(path: Path = AUTH_PATH) -> dict:
    d = json.loads(path.read_text())
    t = d.get("tokens") or {}
    for k in ("access_token", "refresh_token", "id_token", "account_id"):
        if t.get(k):
            _SECRETS.append(t[k])
    if d.get("OPENAI_API_KEY"):
        _SECRETS.append(d["OPENAI_API_KEY"])
    return d


def redact(s) -> str:
    s = str(s)
    for sec in _SECRETS:
        if sec:
            s = s.replace(sec, "<redacted>")
    # generic JWT / sk- key patterns
    s = re.sub(r"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+", "<jwt>", s)
    s = re.sub(r"sk-[A-Za-z0-9_-]{16,}", "sk-<redacted>", s)
    return s


def jwt_claims(token: str) -> dict:
    p = token.split(".")[1]
    p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))


def access_token_expires_in(auth: dict) -> float:
    return jwt_claims(auth["tokens"]["access_token"])["exp"] - time.time()


def user_agent() -> str:
    return f"{ORIGINATOR}/{CODEX_VERSION} (Linux {platform.release()}; {platform.machine()}) woi-research"


def chatgpt_headers(auth: dict) -> dict:
    t = auth["tokens"]
    return {
        "Authorization": f"Bearer {t['access_token']}",
        "chatgpt-account-id": t["account_id"],
        "originator": ORIGINATOR,
        "version": CODEX_VERSION,
        "User-Agent": user_agent(),
    }


def live_headers(auth: dict) -> dict:
    """Headers for the gpt-live (frameless / "quicksilver v2") endpoints:
    POST {CHATGPT_BASE}/realtime/calls and wss://api.openai.com/v1/live/{call_id}."""
    return dict(chatgpt_headers(auth), **{"openai-alpha": "quicksilver=v2"})


def api_key_headers(api_key: str) -> dict:
    _SECRETS.append(api_key)
    return {"Authorization": f"Bearer {api_key}"}


def refresh_tokens(auth: dict, persist: bool = False, path: Path = AUTH_PATH) -> dict:
    """POST https://auth.openai.com/oauth/token (JSON body). Refresh tokens ROTATE:
    if you refresh, you must persist the new refresh_token (Codex CLI shares the file)."""
    import httpx

    body = {
        "client_id": CLIENT_ID,
        "grant_type": "refresh_token",
        "refresh_token": auth["tokens"]["refresh_token"],
    }
    r = httpx.post(REFRESH_URL, json=body, timeout=45)
    if r.status_code != 200:
        raise RuntimeError(f"refresh failed {r.status_code}: {redact(r.text[:500])}")
    new = r.json()
    for k in ("access_token", "refresh_token", "id_token"):
        if new.get(k):
            auth["tokens"][k] = new[k]
            _SECRETS.append(new[k])
    if persist:
        from datetime import datetime, timezone

        auth["last_refresh"] = datetime.now(timezone.utc).isoformat()
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(auth, indent=2))
        os.chmod(tmp, 0o600)
        tmp.replace(path)
    return auth


def ensure_fresh(auth: dict, min_seconds: float = 300) -> dict:
    if access_token_expires_in(auth) < min_seconds:
        return refresh_tokens(auth, persist=True)
    return auth
