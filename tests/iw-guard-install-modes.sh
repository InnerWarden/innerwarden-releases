#!/bin/sh
# Runs iw-guard-install.sh offline (curl stubbed) and checks what it leaves
# behind:
#   1. under umask 0002 (Ubuntu/Debian login default) every directory it
#      creates and the binary are 0755, never group-writable (rc.1 F10,
#      rc.2 F7: Active Defence refuses a group-writable CLI path);
#   2. a pre-existing group-writable directory is left alone and named in a
#      warning with the one chmod that fixes it;
#   3. with a stock Ubuntu ~/.profile that adds ~/.local/bin the PATH hint
#      says "new login shell", not "export PATH" (rc.2 P15); without one it
#      still prints the export hint.
# Usage: sh tests/iw-guard-install-modes.sh   (exit 0 = pass)
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
installer="$here/iw-guard-install.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A fake release: the "binary" is a script that prints a version.
mkdir -p "$work/release" "$work/stubs"
printf '#!/bin/sh\necho "innerwarden 0.0.0-test"\n' > "$work/release/bin"
if command -v sha256sum >/dev/null 2>&1; then
  sum="$(sha256sum "$work/release/bin" | awk '{print $1}')"
else
  sum="$(shasum -a 256 "$work/release/bin" | awk '{print $1}')"
fi
printf '%s  innerwarden\n' "$sum" > "$work/release/bin.sha256"

# curl stub: serves the binary and its .sha256, fails the .sig (the installer
# then needs IW_GUARD_ALLOW_UNSIGNED=1, set below) and anything else.
cat > "$work/stubs/curl" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --output|-o) out="\$2"; shift 2 ;;
    -m) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  *.sha256) src="$work/release/bin.sha256" ;;
  *.sig) exit 22 ;;
  */innerwarden-*) src="$work/release/bin" ;;
  *) exit 22 ;;
esac
cat "\$src" > "\$out"
STUB
chmod 0755 "$work/stubs/curl"

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
failures=0
check() { # check <what> <expected> <actual>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; failures=$((failures + 1)); fi
}

run_installer() { # run_installer <home> -> output on stdout
  ( umask 0002
    HOME="$1" PATH="$work/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    IW_GUARD_ALLOW_UNSIGNED=1 IW_GUARD_NO_HOOK=1 INNERWARDEN_NO_TELEMETRY=1 \
      sh "$installer" 2>&1 )
}

# Case 1 + 3: fresh home, stock Ubuntu ~/.profile.
home1="$work/home1"; mkdir -p "$home1"; chmod 0755 "$home1"
cat > "$home1/.profile" <<'PROFILE'
# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi
PROFILE
out1="$(run_installer "$home1")"
check "~/.local is 755 under umask 0002" 755 "$(mode "$home1/.local")"
check "~/.local/bin is 755 under umask 0002" 755 "$(mode "$home1/.local/bin")"
check "the binary is 755 under umask 0002" 755 "$(mode "$home1/.local/bin/innerwarden")"
case "$out1" in *"new login shell"*) r=yes ;; *) r=no ;; esac
check "stock ~/.profile: says a new login shell adds it" yes "$r"
case "$out1" in *"export PATH"*) r=yes ;; *) r=no ;; esac
check "stock ~/.profile: no export PATH hint" no "$r"
case "$out1" in *"another account can write"*) r=yes ;; *) r=no ;; esac
check "a clean tree gives no writable-path warning" no "$r"

# Case 2 + 3: ~/.local/bin already exists group-writable, no profile.
home2="$work/home2"; mkdir -p "$home2/.local/bin"; chmod 0755 "$home2" "$home2/.local"
chmod 0775 "$home2/.local/bin"
out2="$(run_installer "$home2")"
check "a pre-existing directory keeps the operator's mode" 775 "$(mode "$home2/.local/bin")"
case "$out2" in *"chmod g-w,o-w $home2/.local/bin"*) r=yes ;; *) r=no ;; esac
check "the writable directory is named with its fix" yes "$r"
case "$out2" in *"export PATH"*) r=yes ;; *) r=no ;; esac
check "no profile: the export PATH hint stays" yes "$r"

[ "$failures" -eq 0 ] || { echo "$failures check(s) failed"; exit 1; }
echo "all checks passed"
