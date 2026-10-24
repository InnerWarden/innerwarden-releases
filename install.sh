#!/bin/sh
# This file is NOT an installer.
#
# It used to hold a copy of the Linux host installer (last updated July 2026)
# that nothing serves or links any more, and an old copy pins whatever it
# pinned then. It stays at this path only so an old bookmark fails loudly
# instead of running stale code. The installers that run are release assets:
#   https://www.innerwarden.com/free     -> iw-guard release, iw-guard-install.sh
#   https://www.innerwarden.com/free.ps1 -> iw-guard release, install.ps1
#   https://www.innerwarden.com/install  -> a pinned vX.Y.Z release, install.sh

cat >&2 <<'MSG'

This install.sh is not an installer, and nothing was installed.

InnerWarden Community (free), macOS and Linux:
  curl -fsSL https://www.innerwarden.com/free | sh

InnerWarden Community, Windows (PowerShell):
  irm https://www.innerwarden.com/free.ps1 | iex

Host stack and InnerWarden Pro, Linux with systemd:
  curl -fsSL https://www.innerwarden.com/install | sudo bash

Releases and their notes:
  https://github.com/InnerWarden/innerwarden-releases/releases

MSG
exit 1
