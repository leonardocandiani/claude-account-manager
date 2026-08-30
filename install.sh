#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOME/.local/lib/claude-account-manager"
BIN="$HOME/bin"
CONFIG="$HOME/.config/claude-account"

command -v security >/dev/null 2>&1 || {
  echo "ERROR: 'security' CLI not found. This tool is macOS-only (it stores secrets in the Keychain)." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required. Install it with: brew install jq" >&2
  exit 1
}

mkdir -p "$LIB" "$BIN" "$CONFIG/profiles"
chmod 700 "$LIB" "$CONFIG" "$CONFIG/profiles"

install -m 700 "$ROOT/bin/claude-account" "$BIN/claude-account"
install -m 700 "$ROOT/bin/claude" "$BIN/claude"
install -m 600 "$ROOT/lib/shell-init.zsh" "$LIB/shell-init.zsh"

if [ -d "/Applications/Orca.app" ] || [ -d "$HOME/Applications/Orca.app" ]; then
  install -m 700 "$ROOT/lib/restart-orca.sh" "$LIB/restart-orca.sh"
  echo "Orca detected: restart helper installed."
else
  echo "Orca not detected: restart helper skipped. After switching accounts, restart your terminal sessions."
fi

echo
echo "Installed. Add this line to your ~/.zprofile:"
# $HOME must stay literal in the printed instruction.
# shellcheck disable=SC2016
printf '  [ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"\n'

resolved="$(command -v claude 2>/dev/null || true)"
if [ "$resolved" != "$BIN/claude" ]; then
  echo
  echo "WARNING: 'claude' currently resolves to: ${resolved:-nothing}"
  echo "Make sure $BIN comes BEFORE it in your PATH, otherwise the profile wrapper never runs."
fi
