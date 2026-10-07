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
export STUB_KC="$W/kc" STUB_LC="$W/lc" STUB_LOG="$W/claude.log" STUB_AGENTS="$W/agents.json" STUB_LOGGED="$W/logged-in"
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
  auth)
    if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ] && grep -qx "$CLAUDE_SECURESTORAGE_CONFIG_DIR" "$STUB_LOGGED" 2>/dev/null; then
      echo '{"loggedIn":true,"email":"work@example.com"}'
    elif [ -n "$(printenv CLAUDE_CODE_""OAUTH_TOKEN)" ]; then echo '{"loggedIn":true}'
    else echo '{"loggedIn":false}'; fi ;;
  agents) [ -f "$STUB_AGENTS.fail" ] && exit 1; cat "$STUB_AGENTS" ;;
  daemon|respawn|stop) echo "$*" >> "$STUB_LOG" ;;
  --bg) echo "bg ss=${CLAUDE_SECURESTORAGE_CONFIG_DIR:-none} $*" >> "$STUB_LOG"; echo "backgrounded · abcd1234 · X" ;;
esac
EOF
chmod +x "$S/security" "$S/launchctl" "$S/claude"
printf '#!/bin/sh\n' > "$W/home/bin/claude"; chmod +x "$W/home/bin/claude"
printf 'source claude-account\n' > "$W/home/.zprofile"
echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > "$W/home/.claude/settings.json"

envs=(HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg" CLAUDE_NATIVE_BIN="$S/claude" CLAUDE_ACCOUNT_BG_SETTLE=0 PATH="$S:$PATH")
ca() { env "${envs[@]}" "$CA" "$@"; }
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
kc_put "Claude Code-credentials-personal-archive" '{"claudeAiOauth":{"accessToken":"A1","refreshToken":"R1"}}'
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A1","refreshToken":"R1"},"mcpOAuth":{"srv":1}}'
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
ca use work --no-restart >/dev/null
check "use full-login: launchctl carries the secure-storage dir" "$W/login-work" "$(lc CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "use full-login: no OAuth token in launchctl" absent "$(lc "$TOKEN_VAR")"
check "use full-login: native slot keeps the native login" A1 "$(live .claudeAiOauth.accessToken)"
check "doctor: full login signed in" 1 "$(ca doctor 2>/dev/null | grep -c '\[ok\] full login of the active profile is signed in')"
check "doctor: launchctl on the full login" 1 "$(ca doctor 2>/dev/null | grep -c '\[ok\] launchctl points to the full login')"
check "exec exports the secure-storage dir" "$W/login-work" "$(env "${envs[@]}" CLAUDE_NATIVE_BIN=/usr/bin/env "$CA" exec printenv CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "exec exports no OAuth token" "" "$(env "${envs[@]}" CLAUDE_NATIVE_BIN=/usr/bin/env "$CA" exec printenv "$TOKEN_VAR" || true)"

# Login shells (lib/shell-init.zsh) follow the same rule as `exec`.
shell_env() { env HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg" PATH="$S:$PATH" zsh -fc "source '$here/../lib/shell-init.zsh'; printenv $1 || true"; }
check "shell-init: full-login profile exports the dir" "$W/login-work" "$(shell_env CLAUDE_SECURESTORAGE_CONFIG_DIR)"
check "shell-init: full-login profile exports no token" "" "$(env "$TOKEN_VAR=stale" bash -c "$(declare -f shell_env); W='$W' S='$S' here='$here'; shell_env $TOKEN_VAR")"

# The native login kept refreshing while the full-login profile was active; going back
# must archive that live login, never restore the older archive over it.
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A2","refreshToken":"R2"},"mcpOAuth":{"srv":1}}'
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
kc_put "Claude Code-credentials-pb-archive" '{"claudeAiOauth":{"accessToken":"B1","refreshToken":"RB1"}}'
jq -n '{version:2,name:"pb",type:"native_archive",keychainService:"Claude Code-credentials-pb-archive",label:"pb"}' > "$W/cfg/profiles/pb.json"
echo '[]' > "$STUB_AGENTS"
ca use personal --no-restart >/dev/null
ca use work --no-restart >/dev/null
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A3","refreshToken":"R3"},"mcpOAuth":{"srv":1}}'
ca use pb --no-restart >/dev/null
check "native, full-login, other native: live login kept by its owner" A3 "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"
check "native, full-login, other native: the other's archive untouched" B1 "$(kc_get 'Claude Code-credentials-pb-archive' | jq -r .claudeAiOauth.accessToken)"
check "native, full-login, other native: slot carries the other login" B1 "$(live .claudeAiOauth.accessToken)"
check "slot owner follows" pb "$(cat "$W/cfg/native-owner")"
ca use personal --no-restart >/dev/null
check "and back: the first login returns intact" A3 "$(live .claudeAiOauth.accessToken)"

# Upgrade path: a native profile active with no owner record yet still owns the slot.
rm -f "$W/cfg/native-owner"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A4","refreshToken":"R4"},"mcpOAuth":{"srv":1}}'
ca use work --no-restart >/dev/null
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A5","refreshToken":"R5"},"mcpOAuth":{"srv":1}}'
ca use pb --no-restart >/dev/null
ca use personal --no-restart >/dev/null
check "no owner record, native active before: its refreshed login comes back" A5 "$(live .claudeAiOauth.accessToken)"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
