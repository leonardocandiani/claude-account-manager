#!/usr/bin/env bash
# Decisions of claude-account-autoswitch over a chain of accounts (preferred, fallback,
# reserves), with `claude-account measure` stubbed. No Keychain, no network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/home/bin" "$W/cfg"
export HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg"

cat > "$HOME/bin/claude-account" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  measure)
    shift
    echo "profiles[$#]{name,status,http,util_5h,reset_5h,util_7d,reset_7d,overage,overage_in_use}:"
    for p in "$@"; do grep "^$p," "$CLAUDE_ACCOUNT_HOME/measured.csv" | sed 's/^/  /'; done ;;
  use) shift; echo "use $*" >> "$CLAUDE_ACCOUNT_HOME/calls.log"
    if [ -n "${STUB_DEFER:-}" ]; then echo "$1" > "$CLAUDE_ACCOUNT_HOME/bg-restart.pending"; fi ;;
  bg-restart) echo "bg-restart ${2:-}${3:+ $3}" >> "$CLAUDE_ACCOUNT_HOME/calls.log"
    case "$*" in *--force*) rm -f "$CLAUDE_ACCOUNT_HOME/bg-restart.pending" ;; esac ;;
  *) : ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/bin/claude-account-regime"
chmod +x "$HOME/bin/claude-account" "$HOME/bin/claude-account-regime"

runs=0; fails=0
check() {
  runs=$((runs + 1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}
policy() { # reserves-json
  jq -n --argjson r "$1" '{preferred:"a", fallback:"b", reserves:$r,
    exhausted_at:{five_hour:0.95, seven_day:0.97}, return_below:{five_hour:0.70, seven_day:0.90}}' > "$W/cfg/policy.json"
}
usage() { # a5 a7 b5 b7 c5 c7
  { echo "a,allowed,200,$1,0,$2,0,,"; echo "b,allowed,200,$3,0,$4,0,,"; echo "c,allowed,200,$5,0,$6,0,,"; } > "$W/cfg/measured.csv"
}
decide() { # active [last_to]
  echo "$1" > "$W/cfg/active"
  if [ -n "${2:-}" ]; then jq -n --arg t "$2" '{to:$t}' > "$W/cfg/autoswitch-state.json"; else rm -f "$W/cfg/autoswitch-state.json"; fi
  bash "$ROOT/bin/claude-account-autoswitch" --dry-run | tail -1 | grep -oE 'decision=[^ ]+ reason=[^ ]+'
}

# Two accounts: same decisions as before reserves existed.
policy '[]'
usage 0.1 0.1 0.1 0.1 0.1 0.1
check "2 accounts: preferred with room stays" "decision=a reason=preferred_has_room" "$(decide a)"
usage 0.99 0.5 0.1 0.1 0.1 0.1
check "2 accounts: preferred exhausted goes to fallback" "decision=b reason=preferred_exhausted_fallback_has_room" "$(decide a)"
usage 0.8 0.5 0.1 0.1 0.1 0.1
check "2 accounts: on fallback, preferred above return_below stays" "decision=b reason=fallback_still_has_room" "$(decide b)"
usage 0.99 0.5 0.99 0.5 0.1 0.1
check "2 accounts: both exhausted stays, reserve not in policy" "decision=b reason=both_exhausted_stay" "$(decide b)"
check "2 accounts: account outside the policy is left alone" "decision=c reason=manual_profile_active" "$(decide c)"
check "2 accounts: summary has no reserve" 0 "$(decide a >/dev/null; tail -1 "$W/cfg/autoswitch.log" | grep -c ' c=\[')"

# Three accounts.
policy '["c"]'
usage 0.99 0.5 0.99 0.5 0.1 0.1
check "3 accounts: preferred and fallback exhausted go to the reserve" "decision=c reason=exhausted_next_has_room" "$(decide b)"
check "3 accounts: from the preferred too" "decision=c reason=exhausted_next_has_room" "$(decide a)"
check "3 accounts: reserve measured and logged" 1 "$(tail -1 "$W/cfg/autoswitch.log" | grep -c ' c=\[allowed/5h=0.1/7d=0.1\]')"
usage 0.8 0.5 0.99 0.5 0.1 0.1
check "3 accounts: on the reserve, preferred above return_below stays" "decision=c reason=reserve_still_has_room" "$(decide c)"
usage 0.5 0.5 0.99 0.5 0.1 0.1
check "3 accounts: preferred recovered, back to it" "decision=a reason=preferred_recovered" "$(decide c)"
usage 0.8 0.5 0.5 0.5 0.1 0.1
check "3 accounts: fallback recovered first, back to it" "decision=b reason=fallback_recovered" "$(decide c)"
usage 0.99 0.5 0.99 0.5 0.99 0.5
check "3 accounts: all exhausted, reserve stays" "decision=c reason=both_exhausted_stay" "$(decide c)"
usage 0.99 0.5 0.5 0.5 0.99 0.5
check "3 accounts: reserve exhausted, fallback has room" "decision=b reason=fallback_recovered" "$(decide c)"
usage 0.5 0.5 0.5 0.5 0.1 0.1
check "3 accounts: manual pick of the reserve is respected" "decision=c reason=manual_choice_respected" "$(decide c a)"
usage 0.99 0.5 0.5 0.5 0.99 0.5
check "3 accounts: manual reserve exhausted goes to the first with room" "decision=b reason=manual_choice_exhausted" "$(decide c a)"

# A real run switches through `use --no-restart`.
rm -f "$W/cfg/calls.log" "$W/cfg/autoswitch-state.json"
usage 0.99 0.5 0.99 0.5 0.1 0.1
echo a > "$W/cfg/active"
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "real run: use called on the reserve" "use c --no-restart" "$(cat "$W/cfg/calls.log")"
check "real run: state records the reserve" c "$(jq -r .to "$W/cfg/autoswitch-state.json")"

# Background sessions stuck on an exhausted account: the pending move is forced.
policy '["c"]'; jq '.move_agents = true' "$W/cfg/policy.json" > "$W/p.tmp" && mv "$W/p.tmp" "$W/cfg/policy.json"
rm -f "$W/cfg/calls.log" "$W/cfg/autoswitch-state.json"
usage 0.99 0.5 0.99 0.5 0.1 0.1
echo a > "$W/cfg/active"; echo a > "$W/cfg/daemon-profile"
STUB_DEFER=1 bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "exhausted switch: the deferred move is forced in the same run" 1 "$(grep -c '^bg-restart --force' "$W/cfg/calls.log")"
check "exhausted switch: the force is logged with the account" 1 "$(grep -c 'bg_restart_forced sessions_on=a' "$W/cfg/autoswitch.log")"

# Sessions already on the new account, or the old one still with room: never forced.
rm -f "$W/cfg/calls.log"; echo c > "$W/cfg/active"; echo c > "$W/cfg/daemon-profile"
echo c > "$W/cfg/bg-restart.pending"; jq -n '{to:"c"}' > "$W/cfg/autoswitch-state.json"
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "sessions on an account with room: not forced" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c -- '--force')"
rm -f "$W/cfg/calls.log"; usage 0.5 0.5 0.99 0.5 0.1 0.1
echo b > "$W/cfg/active"; echo a > "$W/cfg/daemon-profile"; jq -n '{to:"b"}' > "$W/cfg/autoswitch-state.json"
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "a return switch with the old account still alive: not forced" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c -- '--force')"
rm -f "$W/cfg/calls.log"; echo a > "$W/cfg/active"; echo z > "$W/cfg/daemon-profile"
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "daemon on an account outside the chain: left alone" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c -- '--force')"
rm -f "$W/cfg/calls.log" "$W/cfg/bg-restart.pending"; usage 0.99 0.5 0.99 0.5 0.1 0.1
echo a > "$W/cfg/daemon-profile"; echo a > "$W/cfg/active"; rm -f "$W/cfg/autoswitch-state.json"
bash "$ROOT/bin/claude-account-autoswitch" --dry-run >/dev/null
check "dry run never forces" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c -- '--force')"

# --- 22/10/2026, defect 2: an account without a quota reading is not a full account. ---
# A native profile with no measuring token read "unmeasurable", and the switcher took that
# as exhausted and tried to leave it every 5 minutes.
unmeasured() { # name: replaces that account's line with an unmeasurable one
  grep -v "^$1," "$W/cfg/measured.csv" > "$W/m.tmp"; echo "$1,unmeasurable,,,,,,," >> "$W/m.tmp"; mv "$W/m.tmp" "$W/cfg/measured.csv"
}
policy '["c"]'
usage 0.1 0.1 0.1 0.1 0.1 0.1; unmeasured a
check "unmeasurable preferred, active: stays" "decision=a reason=active_unmeasured" "$(decide a)"
check "unmeasurable preferred picked by hand: stays" "decision=a reason=active_unmeasured" "$(decide a b)"
usage 0.1 0.1 0.1 0.1 0.1 0.1; unmeasured b
check "unmeasurable fallback, active: stays" "decision=b reason=active_unmeasured" "$(decide b)"
usage 0.99 0.5 0.1 0.1 0.1 0.1; unmeasured b
check "preferred exhausted, unmeasurable fallback skipped for the reserve" "decision=c reason=exhausted_next_has_room" "$(decide a)"
usage 0.1 0.1 0.1 0.1 0.1 0.1; unmeasured a
check "on the fallback, an unmeasurable preferred is no way back" "decision=b reason=fallback_still_has_room" "$(decide b)"
rm -f "$W/cfg/calls.log"; echo a > "$W/cfg/active"; rm -f "$W/cfg/autoswitch-state.json"
usage 0.1 0.1 0.1 0.1 0.1 0.1; unmeasured a
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "real run on an unmeasurable active: no use call" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c '^use')"
# Sessions waiting on an unmeasurable account are not forced off it either.
jq '.move_agents = true' "$W/cfg/policy.json" > "$W/p.tmp" && mv "$W/p.tmp" "$W/cfg/policy.json"
rm -f "$W/cfg/calls.log"; echo b > "$W/cfg/active"; echo a > "$W/cfg/daemon-profile"
echo b > "$W/cfg/bg-restart.pending"; jq -n '{to:"b"}' > "$W/cfg/autoswitch-state.json"
usage 0.5 0.5 0.1 0.1 0.1 0.1; unmeasured a
bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "sessions on an unmeasurable account: not forced" 0 "$(cat "$W/cfg/calls.log" 2>/dev/null | grep -c -- '--force')"
rm -f "$W/cfg/bg-restart.pending"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
