#!/usr/bin/env bash
# Scenario tests for full-login profiles (`login`, `use` with secureStorageDir),
# moving background sessions (`bg-restart`, `bg-status`) and `claude-sessions`.
# The Keychain, `launchctl` and the Claude binary are stubbed and HOME is a
# scratch directory, so nothing here touches the real Keychain, daemon or jobs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CA="$here/../bin/claude-account"
CS="$here/../bin/claude-sessions"
TOKEN_VAR="CLAUDE_CODE_""OAUTH_TOKEN"
unset "$TOKEN_VAR" CLAUDE_SECURESTORAGE_CONFIG_DIR
fails=0; runs=0

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
S="$W/stub"; mkdir -p "$S" "$W/kc" "$W/lc" "$W/home/bin" "$W/home/.claude/jobs" "$W/cfg/profiles" "$W/login-work"
export STUB_KC="$W/kc" STUB_LC="$W/lc" STUB_LOG="$W/claude.log" STUB_AGENTS="$W/agents.json" STUB_LOGGED="$W/logged-in" STUB_EMAILS="$W/emails" STUB_REFRESH_LOG="$W/refresh.log"
: > "$STUB_LOG"; echo '[]' > "$STUB_AGENTS"

cat > "$S/security" <<'EOF'
#!/usr/bin/env bash
op="$1"; shift; svc=""; val=""; want=false
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift ;;
    -a) shift ;;
    -w) if [ "$op" = add-generic-password ]; then val="$2"; shift; else want=true; fi ;;
  esac
  shift
done
f="$STUB_KC/$(printf %s "$svc" | shasum | cut -c1-16)"
case "$op" in
  find-generic-password)
    [ -f "$f" ] || exit 44
    if $want; then cat "$f"; else printf '    "mdat"<timedate>=0x00  "%sZ\\000"\n' "$(cat "$f.mdat")"; fi ;;
  add-generic-password) printf %s "$val" > "$f"; date -u +%Y%m%d%H%M%S > "$f.mdat" ;;
  delete-generic-password) [ -f "$f" ] || exit 44; rm -f "$f" "$f.mdat" ;;
esac
EOF
cat > "$S/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  setenv) printf %s "$3" > "$STUB_LC/$2" ;;
  unsetenv) rm -f "$STUB_LC/$2" ;;
  getenv) [ -f "$STUB_LC/$2" ] && cat "$STUB_LC/$2" || exit 1 ;;
esac
EOF
# auth status is signed in under a secure-storage dir listed in $STUB_LOGGED, or with a token.
cat > "$S/claude" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -p) exec "$(dirname "$0")/claude-p" ;;
  auth)
    if [ "${2:-}" = login ]; then
      # STUB_LOGIN_FAIL: the browser step breaks halfway, leaving a broken item behind.
      item="Claude Code-credentials-$(printf '%s' "$CLAUDE_SECURESTORAGE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
      if [ -n "${STUB_LOGIN_FAIL:-}" ]; then security add-generic-password -U -a x -s "$item" -w '{}'; exit 1; fi
      security add-generic-password -U -a x -s "$item" -w "{\"claudeAiOauth\":{\"accessToken\":\"${STUB_LOGIN_AS:-WN}\",\"refreshToken\":\"RL\",\"expiresAt\":4102444800000}}"
      exit 0
    fi
    if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ] && grep -qx "$CLAUDE_SECURESTORAGE_CONFIG_DIR" "$STUB_LOGGED" 2>/dev/null; then
      if [ -n "${STUB_NOEMAIL:-}" ]; then echo '{"loggedIn":true,"email":null}'
      elif [ -n "${STUB_OTHER:-}" ]; then echo '{"loggedIn":true,"email":"other@example.com"}'
      else echo '{"loggedIn":true,"email":"work@example.com"}'; fi
    elif [ -n "$(printenv CLAUDE_CODE_""OAUTH_TOKEN)" ]; then echo '{"loggedIn":true}'
    else echo '{"loggedIn":false}'; fi ;;
  agents) [ -f "$STUB_AGENTS.fail" ] && exit 1; cat "$STUB_AGENTS" ;;
  daemon|respawn|stop) echo "$*" >> "$STUB_LOG" ;;
  --bg) echo "bg ss=${CLAUDE_SECURESTORAGE_CONFIG_DIR:-none} $*" >> "$STUB_LOG"; echo "backgrounded · abcd1234 · X" ;;
esac
EOF
chmod +x "$S/security" "$S/launchctl" "$S/claude"
. "$here/stub-login.sh"
printf '#!/bin/sh\n' > "$W/home/bin/claude"; chmod +x "$W/home/bin/claude"
printf 'source claude-account\n' > "$W/home/.zprofile"
echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$W/home/.claude/settings.json"

envs=(HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg" CLAUDE_NATIVE_BIN="$S/claude" CLAUDE_ACCOUNT_BG_SETTLE=0 PATH="$S:$PATH")
ca() { env "${envs[@]}" STUB_NOEMAIL="${STUB_NOEMAIL:-}" STUB_OTHER="${STUB_OTHER:-}" "$CA" "$@"; }
cs() { env "${envs[@]}" CLAUDE_ACCOUNT_BIN="$CA" "$CS" "$@"; }
kc_get() { PATH="$S:$PATH" security find-generic-password -a x -s "$1" -w; }
kc_put() { PATH="$S:$PATH" security add-generic-password -U -a x -s "$1" -w "$2"; }
live() { kc_get "Claude Code-credentials" | jq -r "$1"; }
lc() { cat "$STUB_LC/$1" 2>/dev/null || echo absent; }
check() {
  runs=$((runs + 1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}
wait_worker() { # until the detached worker writes its end line
  local n=0
  until grep -q ' end$' "$W/cfg/bg-restart.log" 2>/dev/null || [ "$n" -ge 50 ]; do sleep 0.2; n=$((n + 1)); done
}
job() { # id sessionId name flags-json
  mkdir -p "$W/home/.claude/jobs/$1"
  jq -n --arg i "$1" --arg s "$2" --arg n "$3" --argjson f "$4" --arg c "$W" \
    '{daemonShort:$i, sessionId:$s, name:$n, nameSource:"user", respawnFlags:$f, cwd:$c, color:null}' \
    > "$W/home/.claude/jobs/$1/state.json"
}

# Profiles: a native one owning the slot, an OAuth one with a full login of its own.
kc_put "Claude Code-credentials-personal-archive" '{"claudeAiOauth":{"accessToken":"A1","refreshToken":"R1","expiresAt":4102444800000}}'
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A1","refreshToken":"R1","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
kc_put "Claude Code OAuth Token - work" "sk-ant-oat01-WORK"
jq -n '{version:2,name:"personal",type:"native_archive",keychainService:"Claude Code-credentials-personal-archive",label:"personal"}' > "$W/cfg/profiles/personal.json"
jq -n --arg d "$W/login-work" '{version:2,name:"work",type:"oauth_token",keychainService:"Claude Code OAuth Token - work",label:"work",secureStorageDir:$d,account:"work@example.com"}' > "$W/cfg/profiles/work.json"
echo personal > "$W/cfg/active"
echo personal > "$W/cfg/native-owner"

# Full-login profile whose login is gone: refused before any layer moves.
set +e; out="$(ca use work --no-restart 2>&1)"; rc=$?; set -e
check "use full-login profile without its login: refused" 1 "$rc"
check "refusal names the fix" 1 "$(printf '%s' "$out" | grep -c 'claude-account login work')"
check "refusal left the active profile alone" personal "$(cat "$W/cfg/active")"

# With the login present: launchctl points to the dir, no token, native slot untouched.
echo "$W/login-work" > "$STUB_LOGGED"
item_of() { printf 'Claude Code-credentials-%s' "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"; }
kc_put "$(item_of "$W/login-work")" '{"claudeAiOauth":{"accessToken":"W1","refreshToken":"RW1","expiresAt":4102444800000}}'
echo "W1 work@example.com" > "$STUB_EMAILS"
ca use work --no-restart >/dev/null
check "use full-login: launchctl carries the secure-storage dir" "$W/login-work" "$(lc CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "use full-login: no OAuth token in launchctl" absent "$(lc "$TOKEN_VAR")"
check "use full-login: native slot keeps the native login" A1 "$(live .claudeAiOauth.accessToken)"
check "doctor: full login signed in" 1 "$(ca doctor 2>/dev/null | grep -c '\[ok\] full login of the active profile is signed in')"
check "doctor: launchctl on the full login" 1 "$(ca doctor 2>/dev/null | grep -c '\[ok\] launchctl points to the full login')"
# 22/10/2026: a /login into another account rewrote the shared metadata, and the
# healthy full login was refused on that e-mail. The credential's own identity decides.
check "doctor: shared metadata of another account does not fail a healthy full login" 1 "$(STUB_OTHER=1 ca doctor 2>/dev/null | grep -c '\[ok\] full login of the active profile is signed in as work@example.com')"
echo "W1 other@example.com" > "$STUB_EMAILS"
check "doctor: a full login of another account fails" 1 "$(ca doctor 2>/dev/null | grep -c '\[FAIL\] full login .*signed in as other@example.com')"
echo "W1 work@example.com" > "$STUB_EMAILS"
check "exec exports the secure-storage dir" "$W/login-work" "$(env "${envs[@]}" CLAUDE_NATIVE_BIN=/usr/bin/env "$CA" exec printenv CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "exec exports no OAuth token" "" "$(env "${envs[@]}" CLAUDE_NATIVE_BIN=/usr/bin/env "$CA" exec printenv "$TOKEN_VAR" || true)"

# Login shells (lib/shell-init.zsh) follow the same rule as `exec`.
shell_env() { env HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg" PATH="$S:$PATH" zsh -fc "source '$here/../lib/shell-init.zsh'; printenv $1 || true"; }
check "shell-init: full-login profile exports the dir" "$W/login-work" "$(shell_env CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "shell-init: full-login profile exports no token" "" "$(env "$TOKEN_VAR=stale" bash -c "$(declare -f shell_env); W='$W' S='$S' here='$here'; shell_env $TOKEN_VAR")"

# The native login kept refreshing while the full-login profile was active; going back
# must archive that live login, never restore the older archive over it.
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A2","refreshToken":"R2","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
ca use personal --no-restart >/dev/null
check "back to native after full-login: live login kept" A2 "$(live .claudeAiOauth.accessToken)"
check "back to native after full-login: archive refreshed" A2 "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"
check "back to native: secure-storage dir removed from launchctl" absent "$(lc CLAUDE_SECURESTORAGE_CONFIG_DIR)"

# bg-restart: idle sessions are resumed by id, no flag besides the wake prompt.
ca use work --no-restart >/dev/null
job aaaa1111 aaaa1111-0000-0000-0000-000000000001 ALPHA '["--name","ALPHA","--dangerously-skip-permissions"]'
job bbbb2222 bbbb2222-0000-0000-0000-000000000002 BETA '["-n","BETA"]'
jq -n --arg c "$W" '[{kind:"background",id:"aaaa1111",sessionId:"aaaa1111-0000-0000-0000-000000000001",name:"ALPHA",status:"idle",cwd:$c},
                     {kind:"background",id:"bbbb2222",sessionId:"bbbb2222-0000-0000-0000-000000000002",name:"BETA",status:"idle",cwd:$c},
                     {kind:"interactive",id:"cccc3333",sessionId:"x",name:"TERM",status:"busy",cwd:$c}]' > "$STUB_AGENTS"
: > "$STUB_LOG"
ca bg-restart >/dev/null; wait_worker
check "bg-restart: daemon stopped once" 1 "$(grep -c '^daemon stop --any$' "$STUB_LOG")"
check "bg-restart: both background sessions resumed" 2 "$(grep -c '^bg ss=.* --bg --resume ' "$STUB_LOG")"
check "bg-restart: resumed under the new profile's login" 2 "$(grep -c "^bg ss=$W/login-work " "$STUB_LOG")"
check "bg-restart: no flag besides the prompt" 0 "$(grep '^bg ' "$STUB_LOG" | grep -cE ' (-n|--name|--model|--dangerously-skip-permissions) ')"
check "bg-restart: interactive session left alone" 0 "$(grep -c 'resume x ' "$STUB_LOG")"
check "bg-restart: daemon profile recorded" work "$(cat "$W/cfg/daemon-profile")"
check "bg-restart: lock released" absent "$([ -d "$W/cfg/bg-restart.lock" ] && echo present || echo absent)"
check "bg-restart: BETA got bypass back (global default is bypass)" 1 "$(jq '.respawnFlags | index("--dangerously-skip-permissions") != null' "$W/home/.claude/jobs/bbbb2222/state.json" | grep -c true)"
check "bg-restart: BETA respawned to apply it" 1 "$(grep -c '^respawn bbbb2222$' "$STUB_LOG")"
check "bg-restart: ALPHA already right, not respawned" 0 "$(grep -c '^respawn aaaa1111$' "$STUB_LOG")"
check "bg-status: daemon on the active profile" "daemon_profile: work" "$(ca bg-status | grep '^daemon_profile:')"

# A busy session defers the move; the pending marker keeps the first timestamp.
jq '(.[0].status) = "busy"' "$STUB_AGENTS" > "$STUB_AGENTS.tmp" && mv "$STUB_AGENTS.tmp" "$STUB_AGENTS"
: > "$STUB_LOG"; rm -f "$W/cfg/bg-restart.log"
check "bg-restart busy: deferred" 1 "$(ca bg-restart | grep -c 'deferred, busy: ALPHA')"
check "bg-restart busy: pending written" work "$(cat "$W/cfg/bg-restart.pending")"
check "bg-restart busy: nothing stopped" "" "$(cat "$STUB_LOG")"
check "bg-restart --if-pending, still busy: still deferred" 1 "$(ca bg-restart --if-pending | grep -c deferred)"
touch -t 200001010000 "$W/cfg/bg-restart.pending"
ca bg-restart --if-pending >/dev/null
check "old pending, still busy: never forced headless" "" "$(cat "$STUB_LOG")"
jq '(.[0].status) = "idle"' "$STUB_AGENTS" > "$STUB_AGENTS.tmp" && mv "$STUB_AGENTS.tmp" "$STUB_AGENTS"
ca bg-restart --if-pending >/dev/null; wait_worker
check "pending, all idle: moved" 1 "$(grep -c '^daemon stop --any$' "$STUB_LOG")"
check "the move clears the pending marker" absent "$([ -f "$W/cfg/bg-restart.pending" ] && echo present || echo absent)"

# A manual switch moves everything at once, busy sessions included; only the headless
# switcher (--no-restart --move-agents) waits for them.
jq '(.[0].status) = "busy"' "$STUB_AGENTS" > "$STUB_AGENTS.tmp" && mv "$STUB_AGENTS.tmp" "$STUB_AGENTS"
: > "$STUB_LOG"
ca use personal --no-restart --move-agents >/dev/null
check "autoswitch path, busy: deferred" personal "$(cat "$W/cfg/bg-restart.pending")"
check "autoswitch path, busy: nothing stopped" 0 "$(grep -c '^daemon stop --any$' "$STUB_LOG")"
rm -f "$W/cfg/bg-restart.log"; ca use work >/dev/null; wait_worker
check "manual use, busy: daemon stopped" 1 "$(grep -c '^daemon stop --any$' "$STUB_LOG")"
check "manual use, busy: busy session resumed too" 1 "$(grep -c '^bg .*--resume aaaa1111-' "$STUB_LOG")"
check "manual use: nothing left pending" absent "$([ -f "$W/cfg/bg-restart.pending" ] && echo present || echo absent)"
jq '(.[0].status) = "idle"' "$STUB_AGENTS" > "$STUB_AGENTS.tmp" && mv "$STUB_AGENTS.tmp" "$STUB_AGENTS"

# Another move in progress (lock held): deferred and pending, nothing stopped.
mkdir "$W/cfg/bg-restart.lock"; : > "$STUB_LOG"
check "lock held: deferred" 1 "$(ca bg-restart --force | grep -c 'another restart is running')"
check "lock held: nothing stopped" "" "$(cat "$STUB_LOG")"
check "lock held: move kept pending" work "$(cat "$W/cfg/bg-restart.pending")"
rmdir "$W/cfg/bg-restart.lock"; rm -f "$W/cfg/bg-restart.pending"

# The daemon does not answer: error, pending kept, nothing stopped.
touch "$STUB_AGENTS.fail"
set +e; ca bg-restart >/dev/null; rc=$?; set -e
check "agents failing: exit 1" 1 "$rc"
check "agents failing: pending kept" work "$(cat "$W/cfg/bg-restart.pending")"
check "agents failing: nothing stopped" "" "$(cat "$STUB_LOG")"
rm -f "$STUB_AGENTS.fail" "$W/cfg/bg-restart.pending"

# claude-sessions
check "sessions: list shows both" 2 "$(cs | grep -cE '^  (aaaa1111|bbbb2222),')"
check "sessions: list header" "active_profile: work" "$(cs | head -1)"
set +e; out="$(cs color ALPHA purple-ish)"; rc=$?; set -e
check "sessions: invalid color is a usage error" 2 "$rc"
set +e; out="$(cs color NOPE red)"; rc=$?; set -e
check "sessions: unknown target" "1 code: NOT_FOUND" "$rc $(printf '%s' "$out" | grep '^code:')"
: > "$STUB_LOG"
cs color ALPHA green >/dev/null
check "sessions color: written" green "$(jq -r .color "$W/home/.claude/jobs/aaaa1111/state.json")"
check "sessions color: live session respawned" 1 "$(grep -c '^respawn aaaa1111$' "$STUB_LOG")"
check "sessions color again: no-op" 1 "$(cs color ALPHA green | grep -c unchanged)"
cs rename BETA GAMMA >/dev/null
check "sessions rename: name and flags" "GAMMA --name GAMMA" "$(jq -r '.name + " " + (.respawnFlags[0:2] | join(" "))' "$W/home/.claude/jobs/bbbb2222/state.json")"
jq '(.[0].status) = "busy"' "$STUB_AGENTS" > "$STUB_AGENTS.tmp" && mv "$STUB_AGENTS.tmp" "$STUB_AGENTS"
set +e; out="$(cs mode aaaa1111 plan)"; rc=$?; set -e
check "sessions mode on a busy session: refused" "1 code: BUSY" "$rc $(printf '%s' "$out" | grep '^code:')"
cs mode aaaa1111 plan --force >/dev/null
check "sessions mode --force: flags" "--permission-mode plan" "$(jq -r '.respawnFlags | map(select(. == "--permission-mode" or . == "plan")) | join(" ")' "$W/home/.claude/jobs/aaaa1111/state.json")"
job dddd4444 dddd4444-0000-0000-0000-000000000004 DELTA '["--name","DELTA"]'
: > "$STUB_LOG"
cs resume DELTA >/dev/null
check "sessions resume: by session id, no flags" 1 "$(grep -cx "bg ss=$W/login-work --bg --resume dddd4444-0000-0000-0000-000000000004" "$STUB_LOG")"
cs new --name NEWONE --dir "$W" --mode bypass >/dev/null
check "sessions new: named, bypass, active profile" 1 "$(grep -c "^bg ss=$W/login-work --bg -n NEWONE --dangerously-skip-permissions" "$STUB_LOG")"
set +e; cs new --name ALPHA --dir "$W" >/dev/null; rc=$?; set -e
check "sessions new: a live name is taken" 1 "$rc"

# Two native profiles with a full-login one in between: the slot's /login always goes back
# to the profile that owns it, never to whichever profile was active last.
kc_put "Claude Code-credentials-pb-archive" '{"claudeAiOauth":{"accessToken":"B1","refreshToken":"RB1","expiresAt":4102444800000}}'
jq -n '{version:2,name:"pb",type:"native_archive",keychainService:"Claude Code-credentials-pb-archive",label:"pb"}' > "$W/cfg/profiles/pb.json"
echo '[]' > "$STUB_AGENTS"
ca use personal --no-restart >/dev/null
ca use work --no-restart >/dev/null
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A3","refreshToken":"R3","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
ca use pb --no-restart >/dev/null
check "native, full-login, other native: live login kept by its owner" A3 "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"
check "native, full-login, other native: the other's archive untouched" B1 "$(kc_get 'Claude Code-credentials-pb-archive' | jq -r .claudeAiOauth.accessToken)"
check "native, full-login, other native: slot carries the other login" B1 "$(live .claudeAiOauth.accessToken)"
check "slot owner follows" pb "$(cat "$W/cfg/native-owner")"
ca use personal --no-restart >/dev/null
check "and back: the first login returns intact" A3 "$(live .claudeAiOauth.accessToken)"

# Upgrade path: a native profile active with no owner record yet still owns the slot.
rm -f "$W/cfg/native-owner"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A4","refreshToken":"R4","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
ca use work --no-restart >/dev/null
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A5","refreshToken":"R5","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
ca use pb --no-restart >/dev/null
ca use personal --no-restart >/dev/null
check "no owner record, native active before: its refreshed login comes back" A5 "$(live .claudeAiOauth.accessToken)"

# --- 22/10/2026, defect 1: a switch to a native login that no longer refreshes. ---
# The archive said "allowed" through its measuring token while its own login was dead;
# the switch went through and 22 sessions came back on "Login expired".
kc_put "Claude Code-credentials-pb-archive" '{"claudeAiOauth":{"accessToken":"B9","refreshToken":"DEAD-B","expiresAt":1000},"mcpOAuth":{}}'
set +e; out="$(ca use pb --no-restart 2>&1)"; rc=$?; set -e
check "dead native archive: switch refused" 1 "$rc"
check "dead native archive: the reason is the failed refresh" 1 "$(printf '%s' "$out" | grep -c 'does not sign in (Failed to authenticate: OAuth session expired')"
check "dead native archive: active profile kept" personal "$(cat "$W/cfg/active")"
check "dead native archive: the slot keeps the working login" A5 "$(live .claudeAiOauth.accessToken)"
# Expired access token, live refresh token: switched, and the rotated login is kept.
kc_put "Claude Code-credentials-pb-archive" '{"claudeAiOauth":{"accessToken":"B2","refreshToken":"RB2","expiresAt":1000}}'
ca use pb --no-restart >/dev/null
check "refreshable archive: switched" pb "$(cat "$W/cfg/active")"
check "refreshable archive: rotated login written back" "B2-r RB2-r" "$(kc_get 'Claude Code-credentials-pb-archive' | jq -r '.claudeAiOauth | .accessToken + " " + .refreshToken')"
check "refreshable archive: the slot carries the rotated login" B2-r "$(live .claudeAiOauth.accessToken)"

# The bg-restart worker proves the daemon's credential before stopping it. When it fails,
# only the switch is undone: the sessions never leave the daemon they were on.
ca use work --no-restart >/dev/null
echo work > "$W/cfg/daemon-profile"
echo pb > "$W/cfg/active"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"DEAD1","refreshToken":"DEAD-R","expiresAt":1000},"mcpOAuth":{"srv":1}}'
jq -n --arg c "$W" '[{kind:"background",id:"aaaa1111",sessionId:"aaaa1111-0000-0000-0000-000000000001",name:"ALPHA",status:"idle",cwd:$c}]' > "$STUB_AGENTS"
: > "$STUB_LOG"; : > "$W/cfg/bg-restart.log"; : > "$W/cfg/autoswitch.log"
ca bg-restart --force >/dev/null; wait_worker
check "canary: the broken login is caught before the stop" 1 "$(grep -c '^auth_canary_failed profile=pb' "$W/cfg/bg-restart.log")"
check "canary: back to the sessions' profile" work "$(cat "$W/cfg/active")"
check "canary: the rollback is in the autoswitch log" 1 "$(grep -c 'bg_restart_rolled_back from=pb to=work' "$W/cfg/autoswitch.log")"
check "canary: the daemon is not stopped" 0 "$(grep -c 'daemon stop' "$STUB_LOG" || true)"
check "canary: no session is resumed or cut" 0 "$(grep -c -- '--resume' "$STUB_LOG" || true)"
check "canary: daemon still on the working profile" work "$(cat "$W/cfg/daemon-profile")"
# No other profile to go back to: the daemon is left running, nothing is cut.
echo pb > "$W/cfg/active"; echo pb > "$W/cfg/daemon-profile"
: > "$STUB_LOG"; : > "$W/cfg/bg-restart.log"
ca bg-restart --force >/dev/null; wait_worker
check "canary without a way back: aborted" 1 "$(grep -c '^abort: no working profile' "$W/cfg/bg-restart.log")"
check "canary without a way back: daemon not stopped" 0 "$(grep -c 'daemon stop' "$STUB_LOG" || true)"
check "canary without a way back: logged for the autoswitch" 1 "$(grep -c 'bg_restart_rollback_failed profile=pb' "$W/cfg/autoswitch.log")"
# The API not answering is no verdict on the login: the move goes on.
echo work > "$W/cfg/active"; ca use work --no-restart >/dev/null; echo personal > "$W/cfg/daemon-profile"
kc_put "$(item_of "$W/login-work")" '{"claudeAiOauth":{"accessToken":"NET1","refreshToken":"RN1","expiresAt":4102444800000}}'
: > "$STUB_LOG"; : > "$W/cfg/bg-restart.log"
ca bg-restart --force >/dev/null; wait_worker
check "canary with the API down: noted, not a failure" 1 "$(grep -c '^auth_canary_unverified profile=work' "$W/cfg/bg-restart.log")"
check "canary with the API down: the sessions are moved" 1 "$(grep -c -- '--resume aaaa1111' "$STUB_LOG")"
kc_put "$(item_of "$W/login-work")" '{"claudeAiOauth":{"accessToken":"W1","refreshToken":"RW1","expiresAt":4102444800000}}'
echo '[]' > "$STUB_AGENTS"

# A refresh spends the old refresh token everywhere: the slot and its owner's archive hold
# the same login, so a rotation in one is carried to the other.
echo personal > "$W/cfg/native-owner"; echo personal > "$W/cfg/active"
SAME='{"claudeAiOauth":{"accessToken":"S1","refreshToken":"RS1","expiresAt":1000},"mcpOAuth":{"srv":1}}'
kc_put "Claude Code-credentials" "$SAME"; kc_put "Claude Code-credentials-personal-archive" "$SAME"
pb_before="$(kc_get 'Claude Code-credentials-pb-archive')"
ca import-native twin >/dev/null
check "rotation by import: the new archive" "S1-r RS1-r" "$(kc_get 'Claude Code-credentials-twin-archive' | jq -r '.claudeAiOauth | .accessToken + " " + .refreshToken')"
check "rotation by import: carried to the live slot" "S1-r RS1-r" "$(live '.claudeAiOauth | .accessToken + " " + .refreshToken')"
check "rotation by import: carried to the owner's archive" "S1-r RS1-r" "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r '.claudeAiOauth | .accessToken + " " + .refreshToken')"
check "rotation by import: the slot keeps its other keys" 1 "$(live .mcpOAuth.srv)"
check "rotation by import: another login is not touched" "$pb_before" "$(kc_get 'Claude Code-credentials-pb-archive')"
check "import records the account from the credential" x@example.com "$(jq -r .account "$W/cfg/profiles/twin.json")"
rm -f "$W/cfg/profiles/twin.json"
# Doctor only reads: a slot due for a refresh is a warning, and nothing is rotated.
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"S2","refreshToken":"RS2","expiresAt":1000},"mcpOAuth":{"srv":1}}'
: > "$STUB_REFRESH_LOG"
check "doctor: a login due for a refresh is a warning" 1 "$(ca doctor 2>/dev/null | grep -c '\[warn\] the native login in the live slot was not verified')"
check "doctor: nothing refreshed" 0 "$(wc -l < "$STUB_REFRESH_LOG" | tr -d ' ')"
check "doctor: the slot is unchanged" RS2 "$(live .claudeAiOauth.refreshToken)"

# sync-archive (the wizard's "Sync native archive"): the live login goes into its owner.
echo personal > "$W/cfg/native-owner"; echo personal > "$W/cfg/active"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A7","refreshToken":"R7","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
check "sync-archive: names the owner" 1 "$(ca sync-archive | grep -c "live login of 'personal' was copied")"
check "sync-archive: archive refreshed" A7 "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"
# With the owner's account recorded, a slot signed in as someone else never lands in it.
jq '.account = "me@example.com"' "$W/cfg/profiles/personal.json" > "$W/p.tmp" && mv "$W/p.tmp" "$W/cfg/profiles/personal.json"
echo "A8 stranger@example.com" >> "$STUB_EMAILS"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A8","refreshToken":"R8","expiresAt":4102444800000},"mcpOAuth":{"srv":1}}'
ca sync-archive >/dev/null
check "sync-archive, slot of another account: owner's archive untouched" A7 "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"
check "sync-archive, slot of another account: kept as the last login" A8 "$(kc_get 'Claude Code-credentials-last-login-archive' | jq -r .claudeAiOauth.accessToken)"

# --- 22/10/2026, defect 3: `login` never leaves a broken full login behind. ---
WITEM="$(item_of "$W/login-work")"
kc_put "$WITEM" '{"claudeAiOauth":{"accessToken":"W1","refreshToken":"RW1","expiresAt":4102444800000}}'
export STUB_LOGIN_FAIL=1
set +e; out="$(ca login work 2>&1)"; rc=$?; set -e
unset STUB_LOGIN_FAIL
check "cancelled re-login: exit 1" 1 "$rc"
check "cancelled re-login: says the previous state is back" 1 "$(printf '%s' "$out" | grep -c 'previous state was restored')"
check "cancelled re-login: the working login is back" W1 "$(kc_get "$WITEM" | jq -r .claudeAiOauth.accessToken)"
export STUB_LOGIN_AS=WX; echo "WX other@example.com" >> "$STUB_EMAILS"
set +e; out="$(ca login work 2>&1)"; rc=$?; set -e
unset STUB_LOGIN_AS
check "re-login as another account: refused" 1 "$rc"
check "re-login as another account: names both accounts" 1 "$(printf '%s' "$out" | grep -c "signed in as other@example.com, but profile 'work' is work@example.com")"
check "re-login as another account: the working login is back" W1 "$(kc_get "$WITEM" | jq -r .claudeAiOauth.accessToken)"
kc_put "Claude Code OAuth Token - fresh" "sk-ant-oat01-FRESH"
jq -n '{version:2,name:"fresh",type:"oauth_token",keychainService:"Claude Code OAuth Token - fresh",label:"fresh"}' > "$W/cfg/profiles/fresh.json"
export STUB_LOGIN_FAIL=1
set +e; ca login fresh >/dev/null 2>&1; set -e
unset STUB_LOGIN_FAIL
check "first login that fails: no item left" absent "$(kc_get "$(item_of "$W/cfg/logins/fresh")" >/dev/null 2>&1 && echo present || echo absent)"
check "first login that fails: no dir left" absent "$([ -d "$W/cfg/logins/fresh" ] && echo present || echo absent)"
check "first login that fails: profile unchanged" null "$(jq -r '.secureStorageDir // null' "$W/cfg/profiles/fresh.json")"
export STUB_LOGIN_AS=FN; echo "FN fresh@example.com" >> "$STUB_EMAILS"
ca login fresh >/dev/null 2>&1
unset STUB_LOGIN_AS
check "first login: profile points to its dir" "$W/cfg/logins/fresh" "$(jq -r .secureStorageDir "$W/cfg/profiles/fresh.json")"
check "first login: account from the credential" fresh@example.com "$(jq -r .account "$W/cfg/profiles/fresh.json")"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
