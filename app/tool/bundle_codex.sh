#!/usr/bin/env bash
# Copies the pinned Codex CLI (Linux x64, musl static) into the Flutter Linux
# bundle so the built-in terminal has `codex` on PATH. Called by the install
# step in linux/CMakeLists.txt; the binary (300+ MB) is never committed.
#
# Usage: bundle_codex.sh <dest: bundle/lib/codex> <cache dir> [cpu]
#
# Bundle layout (same as the npm vendor dir, which codex understands):
#   lib/codex/bin/codex  lib/codex/codex-path/rg  lib/codex/codex-resources/bwrap
#   lib/codex/codex-package.json
#
# Source, first match wins (each must report `codex-cli $VERSION`):
#   $WOI_CODEX_BIN                         a codex binary (vendor or flat layout)
#   <repo>/research/codex-cli/bin/x64      from research/codex-cli/fetch_codex.sh
#   the main checkout's research/codex-cli/bin/x64 (when built from a worktree)
#   an npm install of @openai/codex (`codex` on PATH, nvm, /usr/lib)
#   WOI_CODEX_FETCH=1: download it with fetch_codex.sh (sha512-verified)
# WOI_SKIP_CODEX=1 skips bundling. A missing source is a warning, not an error.
set -uo pipefail

VERSION="${CODEX_VERSION:-0.166.0}"
DEST="${1:?usage: bundle_codex.sh <dest> <cache> [cpu]}"
CACHE="${2:?usage: bundle_codex.sh <dest> <cache> [cpu]}"
CPU="${3:-$(uname -m)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

log() { echo "bundle_codex: $*" >&2; }

if [[ "${WOI_SKIP_CODEX:-}" == 1 ]]; then log "skipped (WOI_SKIP_CODEX=1)"; exit 0; fi
case "$CPU" in
  x86_64|AMD64|amd64) ;;
  *) log "no bundled codex for CPU '$CPU' (x64 only); skipping"; exit 0 ;;
esac

# Prints the package root (dir with codex-package.json or the codex binary)
# for a codex binary path, if it is the pinned version.
check() {
  local bin="$1"
  [[ -x "$bin" ]] || return 1
  local v; v="$("$bin" --version 2>/dev/null)" || return 1
  if [[ "$v" != "codex-cli $VERSION" ]]; then
    log "ignoring $bin: '$v' (want codex-cli $VERSION)"
    return 1
  fi
  local d; d="$(dirname "$bin")"
  if [[ "$(basename "$d")" == bin && -f "$(dirname "$d")/codex-package.json" ]]; then
    dirname "$d"   # npm vendor layout: <root>/bin/codex
  else
    echo "$d"      # fetch_codex.sh layout: <root>/codex
  fi
}

candidates() {
  [[ -n "${WOI_CODEX_BIN:-}" ]] && echo "$WOI_CODEX_BIN"
  echo "$REPO/research/codex-cli/bin/x64/codex"
  local common
  if common="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    echo "$(dirname "$common")/research/codex-cli/bin/x64/codex"
  fi
  local vendor="node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  local onpath
  if onpath="$(command -v codex 2>/dev/null)"; then
    onpath="$(readlink -f "$onpath")"   # .../lib/node_modules/@openai/codex/bin/codex.js
    echo "$(dirname "$(dirname "$onpath")")/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  fi
  for d in "$HOME"/.config/nvm/versions/node/*/lib "$HOME"/.nvm/versions/node/*/lib /usr/lib /usr/local/lib; do
    echo "$d/$vendor"
  done
}

SRC=""
while IFS= read -r c; do
  if root="$(check "$c")"; then SRC="$root"; SRC_BIN="$c"; break; fi
done < <(candidates)

if [[ -z "$SRC" && "${WOI_CODEX_FETCH:-}" == 1 ]]; then
  log "fetching codex $VERSION"
  if CODEX_VERSION="$VERSION" bash "$REPO/research/codex-cli/fetch_codex.sh" x64 >&2; then
    c="$REPO/research/codex-cli/bin/x64/codex"
    if root="$(check "$c")"; then SRC="$root"; SRC_BIN="$c"; fi
  fi
fi

if [[ -z "$SRC" ]]; then
  log "WARNING: codex $VERSION not found; the bundle has no codex."
  log "  run research/codex-cli/fetch_codex.sh x64, set WOI_CODEX_BIN, or build with WOI_CODEX_FETCH=1"
  exit 0
fi

# 1) Cache a copy in the build dir (once per source change): the install step
#    wipes the bundle on every build, and re-copying 300 MB each time is slow.
C="$CACHE/codex-$VERSION"
stamp="$SRC_BIN $(stat -c '%s %Y' "$SRC_BIN")"
if [[ ! -x "$C/bin/codex" || "$(cat "$C/.source" 2>/dev/null)" != "$stamp" ]]; then
  log "caching $SRC_BIN -> $C"
  rm -rf "$C.tmp" && mkdir -p "$C.tmp/bin" || exit 1
  cp --reflink=auto "$SRC_BIN" "$C.tmp/bin/codex" || exit 1
  for f in codex-path/rg codex-resources/bwrap codex-package.json; do
    if [[ -e "$SRC/$f" ]]; then
      mkdir -p "$C.tmp/$(dirname "$f")"
      cp --reflink=auto "$SRC/$f" "$C.tmp/$f" || exit 1
    fi
  done
  [[ -f "$C.tmp/codex-package.json" ]] || cat > "$C.tmp/codex-package.json" <<EOF
{
  "layoutVersion": 1,
  "version": "$VERSION",
  "target": "x86_64-unknown-linux-musl",
  "variant": "codex",
  "entrypoint": "bin/codex",
  "resourcesDir": "codex-resources",
  "pathDir": "codex-path"
}
EOF
  chmod 755 "$C.tmp/bin/codex"
  echo "$stamp" > "$C.tmp/.source"
  rm -rf "$C" && mv "$C.tmp" "$C" || exit 1
fi

# 2) Into the bundle: hard links when the bundle is on the same filesystem
#    (instant, no extra space), else a reflink/copy.
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")" || exit 1
if ! cp -al "$C" "$DEST" 2>/dev/null; then
  rm -rf "$DEST"
  cp -a --reflink=auto "$C" "$DEST" || exit 1
fi
rm -f "$DEST/.source"
log "bundled $("$DEST/bin/codex" --version) -> $DEST"
