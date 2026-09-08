#!/usr/bin/env bash
# One-shot setup for a fleet Mac. Runs INSIDE the user's GUI session (a launchd
# agent in the gui domain, or an interactive terminal), because the login
# Keychain refuses SSH sessions ("User interaction is not allowed").
#
# What it does, idempotently:
#   1. installs the tool (~/bin, ~/.local/lib)
#   2. copies the two setup-tokens from the local whatsapp-agent plist into the
#      Keychain (primary slot = proteauto, fallback slot = leo-iacall, checked by
#      SHA-256 fingerprint so a swapped plist can never mislabel an account)
#   3. imports the native login under the profile that matches its e-mail and
#      registers the other account as a setup-token profile
#   4. writes policy.json (preferred proteauto, fallback leo-iacall) and the
#      autoswitch launchd agent (5 min)
#   5. activates the native profile and prints doctor + measure
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/.config/claude-account/setup-frota.log"
mkdir -p "$HOME/.config/claude-account"
exec > >(tee -a "$LOG") 2>&1
echo "== setup-frota $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$(hostname -s) user=$USER"

fp() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
FP_PROTEAUTO=a10c8c0e
FP_LEO=51e2e513
PLIST="$HOME/Library/LaunchAgents/com.claude.whatsapp-agent.plist"

bash "$ROOT/install.sh" >/dev/null || { echo "install failed"; exit 1; }

if [ -f "$PLIST" ]; then
  for pair in "CLAUDE_CODE_OAUTH_TOKEN" "CLAUDE_CODE_OAUTH_TOKEN_FALLBACK"; do
    v="$(/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:$pair" "$PLIST" 2>/dev/null || true)"
    [ -n "$v" ] || continue
    case "$(fp "$v")" in
      "$FP_PROTEAUTO") name=proteauto ;;
      "$FP_LEO") name=leo-iacall ;;
      *) echo "token in $pair has unknown fingerprint $(fp "$v"); skipped"; continue ;;
    esac
    security add-generic-password -U -a "$USER" -s "Claude Code OAuth Token - $name" -w "$v" >/dev/null \
      && echo "keychain: token for $name stored (fp $(fp "$v"))"
    unset v
  done
elif [ -f "$HOME/.config/claude-account/.tokens-import" ]; then
  # Machine without the agent plist: tokens delivered in a 600 file with lines
  # "<profile> <token>", consumed and shredded here.
  while read -r name v; do
    [ -n "$name" ] && [ -n "$v" ] || continue
    case "$(fp "$v")" in
      "$FP_PROTEAUTO"|"$FP_LEO") ;;
      *) echo "token for $name has unknown fingerprint $(fp "$v"); skipped"; continue ;;
    esac
    security add-generic-password -U -a "$USER" -s "Claude Code OAuth Token - $name" -w "$v" >/dev/null \
      && echo "keychain: token for $name stored from import file (fp $(fp "$v"))"
  done < "$HOME/.config/claude-account/.tokens-import"
  rm -P "$HOME/.config/claude-account/.tokens-import" 2>/dev/null || rm -f "$HOME/.config/claude-account/.tokens-import"
else
  echo "no whatsapp-agent plist here; expecting tokens already in the Keychain"
fi

for name in proteauto leo-iacall; do
  security find-generic-password -a "$USER" -s "Claude Code OAuth Token - $name" >/dev/null 2>&1 \
    || { echo "missing Keychain token for $name"; exit 1; }
done

email="$(CLAUDE_CODE_OAUTH_TOKEN= "$HOME/.local/bin/claude" auth status 2>/dev/null | jq -r '.email // empty')"
echo "native login e-mail: ${email:-none}"
# The native item is readable by `security` only where the user once granted it
# "always allow" (Studio). Elsewhere the ACL blocks it, so both accounts become
# setup-token profiles and the native login stays untouched in its slot.
if ! security find-generic-password -a "$USER" -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  echo "native credential not readable by security(1) here; using setup-token profiles only"
  email=""
fi
case "$email" in
  comercial@proteautobrasil.com.br) native=proteauto; other=leo-iacall ;;
  "") native=""; other="" ;;
  *) native=leo-iacall; other=proteauto; echo "assuming native login ($email) is the leo-iacall account" ;;
esac

CA="$HOME/bin/claude-account"
if [ -n "$native" ]; then
  [ -f "$HOME/.config/claude-account/profiles/$native.json" ] || "$CA" import-native "$native"
  "$CA" add-oauth "$native" --existing --measure-for "$native"
  [ -f "$HOME/.config/claude-account/profiles/$other.json" ] || "$CA" add-oauth "$other" --existing
else
  for name in proteauto leo-iacall; do
    [ -f "$HOME/.config/claude-account/profiles/$name.json" ] || "$CA" add-oauth "$name" --existing
  done
fi

POLICY="$HOME/.config/claude-account/policy.json"
PREF="${CLAUDE_ACCOUNT_PREFERRED:-proteauto}"
FALL=leo-iacall; [ "$PREF" = leo-iacall ] && FALL=proteauto
[ -f "$POLICY" ] || cat > "$POLICY" <<EOF
{
  "preferred": "$PREF",
  "fallback": "$FALL",
  "exhausted_at": { "five_hour": 0.95, "seven_day": 0.97 },
  "return_below": { "five_hour": 0.70, "seven_day": 0.90 },
  "min_switch_interval_min": 10,
  "max_switches_per_day": 12
}
EOF
chmod 600 "$POLICY"

AGENT="$HOME/Library/LaunchAgents/com.leo.claude-account-autoswitch.plist"
cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.leo.claude-account-autoswitch</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$HOME/bin/claude-account-autoswitch</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>HOME</key>
		<string>$HOME</string>
	</dict>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HOME/.config/claude-account/autoswitch.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/.config/claude-account/autoswitch.launchd.log</string>
</dict>
</plist>
EOF

active="${native:-$PREF}"
"$CA" use "$active"
"$CA" list
"$CA" status
"$CA" doctor; echo "doctor rc=$?"
"$CA" measure
launchctl bootout "gui/$(id -u)/com.leo.claude-account-autoswitch" >/dev/null 2>&1
launchctl bootstrap "gui/$(id -u)" "$AGENT" && echo "autoswitch agent loaded"
echo "== setup-frota done"
