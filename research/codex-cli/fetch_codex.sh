#!/usr/bin/env bash
# Fetch the pinned Codex CLI native binaries (Linux x64 + Linux/Android arm64)
# from the npm registry, verify the npm sha512 integrity, and unpack them into
# research/codex-cli/bin/<arch>/ (gitignored; the binaries are 300+ MB each).
#
# Usage: ./fetch_codex.sh [x64|arm64|all]   (default: all)
#        CODEX_VERSION=0.166.0 ./fetch_codex.sh
#
# Output layout (per arch):
#   bin/<arch>/codex                  main CLI (static-pie musl ELF)
#   bin/<arch>/codex-path/rg          ripgrep helper (codex puts codex-path/ on PATH)
#   bin/<arch>/codex-package.json     layout descriptor read by codex
#   bin/<arch>/codex-resources/...    bwrap + voice host (NOT needed for login/API)
#   bin/<arch>/codex-code-mode-host   code-mode helper (NOT needed for login/API)
set -euo pipefail

VERSION="${CODEX_VERSION:-0.166.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/bin"
WHICH="${1:-all}"

# npm "dist.integrity" values for the pinned version. Update them together with
# VERSION: `npm view @openai/codex@<ver>-linux-<arch> dist.integrity`.
declare -A INTEGRITY=(
  [0.166.0-linux-x64]="sha512-CxDm3+D1cpbGJeHrdzINoG+3wn9BVncP4qpZaaNYkxe8iPtRJOYyCJnnPoVjWRIBvI9vPKbRoifsMSA5xDaUpw=="
  [0.166.0-linux-arm64]="sha512-w0ScAsBr9aZKtIFrh6HN6KU2yjKKeSCzYfbb7DB0Ccj4BYPzeZtUeQprbycLCwuX3AFQdbdjapmLho2iot74jQ=="
)
declare -A TRIPLE=(
  [x64]="x86_64-unknown-linux-musl"
  [arm64]="aarch64-unknown-linux-musl"
)

fetch() {
  local arch="$1" key="$VERSION-linux-$1"
  local url="https://registry.npmjs.org/@openai/codex/-/codex-$key.tgz"
  local want="${INTEGRITY[$key]:-}"
  if [[ -z "$want" ]]; then
    want="$(npm view "@openai/codex@$key" dist.integrity 2>/dev/null || true)"
    [[ -n "$want" ]] || { echo "no integrity known for $key (add it to INTEGRITY)" >&2; exit 1; }
    echo "warning: integrity for $key taken from the registry, not pinned" >&2
  fi
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  echo "==> $url"
  curl -fsSL --retry 3 -o "$tmp/pkg.tgz" "$url"
  local got="sha512-$(sha512sum "$tmp/pkg.tgz" | cut -d' ' -f1 | xxd -r -p | base64 -w0)"
  if [[ "$got" != "$want" ]]; then
    echo "integrity mismatch for $key" >&2; echo " want $want" >&2; echo " got  $got" >&2; exit 1
  fi
  mkdir -p "$tmp/x"
  tar -xzf "$tmp/pkg.tgz" -C "$tmp/x"
  local src="$tmp/x/package/vendor/${TRIPLE[$arch]}"
  [[ -x "$src/bin/codex" ]] || { echo "codex binary not found in tarball" >&2; exit 1; }
  rm -rf "$OUT/$arch"; mkdir -p "$OUT/$arch"
  cp -a "$src/bin/." "$OUT/$arch/"
  cp -a "$src/codex-path" "$src/codex-resources" "$src/codex-package.json" "$OUT/$arch/"
  echo "$VERSION" > "$OUT/$arch/VERSION"
  file "$OUT/$arch/codex" || true
  ls -la "$OUT/$arch/codex" "$OUT/$arch/codex-path/rg"
}

case "$WHICH" in
  x64|arm64) fetch "$WHICH" ;;
  all) fetch x64; fetch arm64 ;;
  *) echo "usage: $0 [x64|arm64|all]" >&2; exit 2 ;;
esac
