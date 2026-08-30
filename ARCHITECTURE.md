# Architecture: claude-account-manager

## Problem

Claude Code on macOS resolves authentication through more than one layer: the OAuth environment
variable, the native Keychain credential, account metadata in `~/.claude.json`, persistent login
shells, the Claude daemon, and (when present) the Orca daemon. Switching only one of them allows a
silent fallback to the previous account.

## Features

- Named profiles for multiple Claude subscriptions.
- Setup-tokens stored exclusively in the Keychain.
- The active account declared in a file that holds no secret.
- Integration with login shells, Orca, `launchctl` and the Claude daemon.
- A recoverable archive of any native credential that gets displaced.
- `status`, `doctor` and `probe` that never print tokens.

## Dependencies

| Foundation | Consumers |
|---|---|
| Keychain | OAuth profiles and native archives |
| active-profile marker | wrapper, shell-init, doctor |
| shell-init | Orca and login shells |
| launchctl | new GUI processes |
| controlled restart | making the switch effective in persistent processes |

## Invariants

1. No token in `.zshrc`, `.zprofile`, profile JSON, logs or persistent arguments.
2. An active OAuth profile implies absence of `Claude Code-credentials` in the native active slot.
3. An active native profile implies absence of `CLAUDE_CODE_OAUTH_TOKEN` in `launchctl`.
4. A switch only completes after the daemon stops and (when applicable) Orca restarts.
5. Every removal from the active slot has a recoverable archive in the Keychain.
6. `doctor` never prints a secret; it compares truncated SHA-256 fingerprints only.
7. The restart helper never kills processes on a machine without Orca.

## ADR-001: Keychain as the single vault

**Status:** accepted.

OAuth tokens live in services named `Claude Code OAuth Token - <profile>`. Archived native
credentials live in `Claude Code-credentials-<profile>-archive`. The file
`~/.config/claude-account/active` contains only the profile name.

Consequence: profile selection works for the CLI and for Orca without spreading secrets, but an
account switch requires restarting persistent processes.

## ADR-002: detect the native binary, allow override

**Status:** accepted.

The real Claude Code binary is discovered by probing common install locations and then `PATH`
(always excluding the `~/bin/claude` wrapper itself), with `CLAUDE_NATIVE_BIN` as the explicit
override. Hardcoding a single path broke on installs done via other methods.
