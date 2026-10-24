# InnerWarden Releases

Signed release binaries and installers for [InnerWarden](https://www.innerwarden.com), runtime security for AI agents. This repository holds release assets and installers only; it carries no source code.

Two release lines are published here:

| Release line | Tags | What it is | Licence and source |
|---|---|---|---|
| **InnerWarden Community** (free) | `guard-vX.Y.Z`, plus the rolling `iw-guard` | The AI-agent guardrail: screens the shell commands and MCP tool calls an agent tries to run and answers allow, review or deny. Linux and macOS, Windows experimental. | Apache-2.0. Source: [InnerWarden/inner-warden](https://github.com/InnerWarden/inner-warden). |
| **Host stack**, the software of **InnerWarden Pro** and **Enterprise**, released as InnerWarden Active Defence | `vX.Y.Z` | The host layer on Linux: its own sensor, incident triage and response and, with a Pro licence, the kernel Execution Gate. | Source-available to customers under licence. Not open source. |

Release notes for both lines are on the [releases page](https://github.com/InnerWarden/innerwarden-releases/releases).

## Install

**InnerWarden Community**, macOS and Linux (no root):

```sh
curl -fsSL https://www.innerwarden.com/free | sh
```

Windows (PowerShell):

```powershell
irm https://www.innerwarden.com/free.ps1 | iex
```

npm, any OS: `npm install -g innerwarden`.

To install an exact Community release, set the tag on the `sh` side of the pipe (the installer reads it; set before `curl`, it is ignored and you get the newest):

```sh
curl -fsSL https://www.innerwarden.com/free | IW_GUARD_TAG=guard-v1.6.10 sh
```

**Host stack and InnerWarden Pro**, Linux with systemd only (x86_64 or aarch64; it refuses macOS, where Community above is the install):

```sh
curl -fsSL https://www.innerwarden.com/install | sudo bash -s -- --license=/path/to/license.txt
```

Without `--license` it installs the free tier of the host stack; with the licence file from the purchase email it installs InnerWarden Pro.

## Verification

Every binary and installer in a release ships a `.sha256` file and an Ed25519 signature (`.sig`), and the installers check both before anything is installed. There is no combined checksum manifest: each file carries its own. The Community signing key is [`innerwarden-release.pub`](innerwarden-release.pub), also attached to every Community release. Step-by-step instructions are in the [documentation](https://www.innerwarden.com/docs).

The `install.sh` at the root of this repository is not an installer: it prints where the installers above are and exits. The installers that run are the release assets the commands above download.
