<!-- Banner -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0F0E0D,35:8C4A32,70:D97757,100:F5E6D3&height=240&section=header&text=claude-account-manager&fontSize=52&fontColor=F5E6D3&animation=fadeIn&fontAlignY=38&desc=Switch%20Claude%20Code%20accounts%20on%20macOS%20%E2%80%94%20one%20command%2C%20no%20re-login&descAlignY=60&descSize=16" />
</div>

<!-- Typing -->
<div align="center">
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=21&duration=2800&pause=900&color=D97757&center=true&vCenter=true&width=840&lines=Switch+between+Claude+Code+accounts+with+one+command;Keychain-only+secrets+%E2%80%94+no+tokens+in+dotfiles;Every+auth+layer+swapped+atomically%2C+nothing+shadows+you;doctor+%C2%B7+status+%C2%B7+probe+%E2%80%94+never+print+a+secret" />
</div>

<!-- Status -->
<div align="center">
  <img src="https://img.shields.io/badge/Platform-macOS-0F0E0D?style=for-the-badge&logo=apple&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Secrets-Keychain%20only-D97757?style=for-the-badge&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/For-Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Bash%20%2B%20jq-8C4A32?style=for-the-badge&logo=gnubash&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/License-MIT-25a162?style=for-the-badge" />
</div>

> **claude-account-manager** turns each of your Claude Code accounts into a named profile and switches all of them with a single command: no re-login, no reboot, no token pasted into a dotfile, no silent fallback to the wrong account. Secrets live exclusively in the macOS Keychain.

> Not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are Anthropic trademarks.

[Leia em português](README.pt-BR.md)

<br>

## What it is

```yaml
product:     multi-account switcher for Claude Code on macOS
accounts:    named profiles — OAuth setup-token or native /login
vault:       macOS Keychain only (no secret in dotfiles, JSON or logs)
switch:      claude-account use <name> — atomic across every auth layer
layers:      Keychain slots · launchctl · ~/.claude.json · daemon · shells
safety:      every displaced credential archived first, fingerprint-verified
diagnostics: doctor · status · probe (SHA-256 fingerprints, never secrets)
extras:      optional Orca integration · CLAUDE_NATIVE_BIN override
```

## The problem

Claude Code resolves authentication through several layers at once: the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable, a native credential in the Keychain (`Claude Code-credentials`), account
metadata in `~/.claude.json`, your login shells, and a background daemon. Switching just one of
those layers lets another silently win.

The classic trap: you start from a setup-token, run `/login` into a second account, and then
cannot get back to the token without rebooting, because the native credential `/login` wrote into
the Keychain shadows it.

## Architecture

```
              ~/.config/claude-account/active          (profile name, no secret)
                              │
      claude (wrapper) ──▶ exec under active profile ──▶ real claude binary
                              │
        ┌─────────────────────┼─────────────────────────┐
        ▼                     ▼                         ▼
  macOS Keychain        launchctl env             ~/.claude.json
  profile slots     CLAUDE_CODE_OAUTH_TOKEN      account metadata
        └─────────────────────┴─────────────────────────┘
                              │
        claude-account use <name>  = swaps ALL of them atomically,
        archiving whatever it removes (switching never destroys a login)
```

## Quick start

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Add the line the installer prints to your `~/.zprofile`:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Register your current `/login` as a profile, add a second account by setup-token
(run `claude setup-token` while logged into it), then switch freely:

```bash
claude-account import-native personal
claude-account add-oauth work
claude-account use work
claude-account use personal
```

> [!NOTE]
> `use` restarts [Orca](https://orca.dev) (if installed) so live processes switch too; pass
> `--no-restart` to skip. New shells always pick up the active profile; already-open sessions
> keep the previous account until restarted.

## Commands

| | Command | What it does |
|:---:|---|---|
| ➕ | `add-oauth <name>` | register a profile from a setup-token (validated before storing) |
| 📥 | `import-native [name]` | import the current `/login` credential as a profile |
| 🔁 | `use <name>` | switch every auth layer to that profile, atomically |
| 📋 | `list` | profiles, the active one marked with `*` |
| 🩺 | `doctor` | check every auth layer for divergence |
| 📊 | `status` | active profile + fingerprints (never the secrets) |
| 🧪 | `probe` | authenticate and run a minimal inference |

## Troubleshooting

> [!WARNING]
> Once you adopt this tool, switch accounts **only** through `claude-account use`, never through
> `/login` inside Claude Code. A direct `/login` writes a native credential that shadows the
> active setup-token profile, and the state diverges silently.

If it happens anyway, `doctor` catches it:

```
[FAIL] launchctl diverges from the active profile
[FAIL] a stale native login is still active (it shadows the setup-token)
```

The fix is one command, no reboot: `claude-account use <any-profile>`. The `/login` credential is
not lost; it is archived in the Keychain as the `primary` profile before the slot is cleared.

## Requirements

- macOS (the Keychain `security` CLI is the vault)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` (`brew install jq`)
- zsh login shells (the macOS default)

`~/bin` must come **before** your Claude Code install directory in `PATH` (the installer warns if
it does not). Unusual install location? Point at it with `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Security notes

- Tokens are validated against `claude auth status` before being stored.
- `status` and `doctor` print SHA-256 fingerprints, never secrets.
- Every removal from the active Keychain slot is preceded by an archive copy, verified by
  fingerprint.
- `~/.claude.json` account metadata is backed up before being stripped.
- On machines without Orca, the restart helper is skipped entirely and nothing is killed.

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — invariants and ADRs
- [`install.sh`](install.sh) — what lands where (`~/bin`, `~/.local/lib`, `~/.config`)

---

## Made by Six Quasar

**Six Quasar** builds AI agents that actually work: WhatsApp as the interface, a deterministic
core, AI at the edge. This tool was born from operating multiple Claude Code accounts across that
fleet, every day.

<a href="https://github.com/ricardo-landim"><img src="https://img.shields.io/badge/GitHub%20profile-181717?style=for-the-badge&logo=github&logoColor=white" /></a>
<a href="https://sixquasar.shop"><img src="https://img.shields.io/badge/sixquasar.shop-D97757?style=for-the-badge&logo=safari&logoColor=F5E6D3" /></a>

<!-- Footer -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:D97757,40:8C4A32,100:0F0E0D&height=120&section=footer" />
</div>
