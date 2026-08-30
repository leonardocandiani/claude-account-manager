# claude-account-manager

Switch between multiple Claude Code accounts on macOS with one command. Secrets live only in
the macOS Keychain: no tokens in dotfiles, no re-login, no silent fallback to the wrong account.

> Not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are Anthropic trademarks.

[Leia em português](README.pt-BR.md)

## The problem

Claude Code resolves authentication through several layers at once: the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable, a native credential in the Keychain (`Claude Code-credentials`), account
metadata in `~/.claude.json`, your login shells, and a background daemon. If you use more than one
account (say, a personal Max subscription and a work one), switching just one of those layers lets
another silently win. The classic trap: you start from a setup-token, run `/login` to a second
account, and then cannot get back to the token without rebooting, because the native credential
`/login` wrote into the Keychain shadows it.

This tool makes the account a named profile and switches every layer atomically.

## How it works

- Each account is a **profile**: either an OAuth **setup-token** (from `claude setup-token`) or a
  **native login** (what `/login` creates).
- All secrets are stored as macOS **Keychain** items. Profile files and the active-profile marker
  contain no secrets at all.
- `claude-account use <name>` swaps the Keychain slots, syncs `launchctl`, clears stale account
  metadata, stops the Claude daemon, and (optionally) restarts [Orca](https://orca.dev) so
  persistent processes pick up the change. Whatever credential it removes from the active slot is
  archived in the Keychain first: switching never destroys a login.
- A small `claude` wrapper in `~/bin` makes every CLI invocation run under the active profile, and
  a `shell-init.zsh` snippet does the same for login shells.

## Requirements

- macOS (the Keychain `security` CLI is the vault)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` (`brew install jq`)
- zsh login shells (the default on macOS)

## Install

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Then add the printed line to your `~/.zprofile`:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Make sure `~/bin` comes **before** your Claude Code install directory in `PATH` (the installer
warns you if it does not). If your `claude` binary lives somewhere unusual, point the tool at it
with `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Usage

Register your current `/login` account as a profile, then add a second account by setup-token
(run `claude setup-token` while logged into that account to get one):

```bash
claude-account import-native personal
claude-account add-oauth work
```

Switch between them, any time, in any direction, no reboot:

```bash
claude-account use work
claude-account use personal
```

Inspect state:

```bash
claude-account list      # profiles, active one marked with *
claude-account status    # active profile + fingerprints (never the secrets)
claude-account doctor    # checks every auth layer for divergence
claude-account probe     # authenticates and runs a minimal inference
```

`use` restarts Orca (if installed) so live processes switch too; pass `--no-restart` to skip it.
New shells always pick up the active profile; already-open sessions keep the previous account
until restarted.

## Troubleshooting: `/login` shadows your setup-token

Rule of thumb: once you use this tool, switch accounts **only** through `claude-account use`,
never through `/login` inside Claude Code.

If you do run `/login` directly, it writes a native credential into the Keychain slot that shadows
the active setup-token profile, and the state diverges silently. `claude-account doctor` will show:

```
[FAIL] launchctl diverges from the active profile
[FAIL] a stale native login is still active (it shadows the setup-token)
```

The fix is one command, no reboot: `claude-account use <any-profile>`. The credential `/login`
created is not lost; it is archived in the Keychain as the `primary` profile before the slot is
cleared.

## Orca integration

If [Orca](https://orca.dev) is installed, the profile switch restarts it so its daemon and the
Claude sessions it spawned adopt the new account. On machines without Orca the helper is skipped
entirely and nothing is killed; restart your terminal sessions after switching.

## Security notes

- Tokens are validated against `claude auth status` before being stored.
- `status` and `doctor` print SHA-256 fingerprints, never secrets.
- Every removal from the active Keychain slot is preceded by an archive copy, verified by
  fingerprint.
- `~/.claude.json` account metadata is backed up before being stripped.

## License

[MIT](LICENSE)
