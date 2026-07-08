# InnerWarden Releases

Prebuilt release binaries and install scripts for [InnerWarden](https://www.innerwarden.com), the runtime guardrail for AI agents.

InnerWarden is **source-available**: the source is licensed to customers and is not in this repository. This repo hosts only the signed release artifacts and the installers.

## Install

**Linux / macOS**
```
curl -fsSL https://www.innerwarden.com/install | sudo bash
```

**Windows (PowerShell)**
```
irm https://raw.githubusercontent.com/InnerWarden/innerwarden-releases/main/install.ps1 | iex
```

Every binary ships an Ed25519 signature (`.sig`) and a `SHA256SUMS` manifest; the installer verifies them before running. See [innerwarden.com](https://www.innerwarden.com/defend) for full instructions and verification steps.
