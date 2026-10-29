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
    case " ${STUB_USE_FAIL:-} " in *" $1 "*) echo "claude-account: ERROR: the login of profile '$1' does not sign in (refresh revoked)" >&2; exit 1 ;; esac
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

# --- A switch `use` refuses (dead login) quarantines that account and falls through to the
# next one with room in the same run, never staying on the exhausted account. ---
policy '["c"]'
rm -f "$W/cfg/calls.log" "$W/cfg/autoswitch-state.json" "$W/cfg/autoswitch-quarantine.json" "$W/cfg/bg-restart.pending"
usage 0.99 0.5 0.1 0.1 0.1 0.1
echo a > "$W/cfg/active"; echo a > "$W/cfg/daemon-profile"
STUB_USE_FAIL=b bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "refused target: tried, then the next one with room" "use b --no-restart|use c --no-restart" "$(paste -sd'|' "$W/cfg/calls.log")"
check "refused target: the run ends on the healthy account" c "$(jq -r .to "$W/cfg/autoswitch-state.json")"
check "refused target: quarantined with the reason" 1 "$(jq -r '.b.reason' "$W/cfg/autoswitch-quarantine.json" | grep -c 'does not sign in')"
check "refused target: logged" 1 "$(grep -c 'switch_failed=b quarantined=6h' "$W/cfg/autoswitch.log")"
# Quarantined: skipped even with room, both going down and coming back up.
echo c > "$W/cfg/active"; jq -n '{to:"c"}' > "$W/cfg/autoswitch-state.json"
usage 0.99 0.5 0.1 0.1 0.1 0.1
check "quarantined account is no way back up" "decision=c reason=reserve_still_has_room" "$(decide c c)"
usage 0.99 0.5 0.1 0.1 0.99 0.5
check "quarantined account is no way down either" "decision=c reason=both_exhausted_stay" "$(decide c c)"
# The quarantine ends by itself.
jq '.b.until = 1' "$W/cfg/autoswitch-quarantine.json" > "$W/q.tmp" && mv "$W/q.tmp" "$W/cfg/autoswitch-quarantine.json"
check "expired quarantine: the account counts again" "decision=b reason=fallback_recovered" "$(decide c c)"
# Every candidate refused: the run stays where it is and says so.
rm -f "$W/cfg/calls.log" "$W/cfg/autoswitch-quarantine.json" "$W/cfg/autoswitch-state.json"
usage 0.99 0.5 0.1 0.1 0.1 0.1
echo a > "$W/cfg/active"
STUB_USE_FAIL="b c" bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "all refused: both tried once" "use b --no-restart|use c --no-restart" "$(paste -sd'|' "$W/cfg/calls.log")"
check "all refused: stays and says so" 1 "$(tail -1 "$W/cfg/autoswitch.log" | grep -c 'reason=no_healthy_account_left')"
check "all refused: active unchanged" a "$(cat "$W/cfg/active")"
# A refused move up is no reason to move down: the active account still has room, it stays.
rm -f "$W/cfg/calls.log" "$W/cfg/autoswitch-quarantine.json"
usage 0.1 0.1 0.1 0.1 0.1 0.1
echo b > "$W/cfg/active"; jq -n '{to:"b"}' > "$W/cfg/autoswitch-state.json"
STUB_USE_FAIL=a bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "refused move up: only the refused one was tried" "use a --no-restart" "$(paste -sd'|' "$W/cfg/calls.log")"
check "refused move up: stays on the active account" b "$(cat "$W/cfg/active")"
check "refused move up: says so" 1 "$(tail -1 "$W/cfg/autoswitch.log" | grep -c 'reason=stays_after_failed_switch')"
# An unreadable quarantine file never stops a run, and the next refusal rewrites it.
echo garbage > "$W/cfg/autoswitch-quarantine.json"
rm -f "$W/cfg/calls.log"
STUB_USE_FAIL=a bash "$ROOT/bin/claude-account-autoswitch" >/dev/null
check "garbage quarantine file: rewritten with the refusal" 1 "$(jq -r 'has("a")' "$W/cfg/autoswitch-quarantine.json" | grep -c true)"
rm -f "$W/cfg/autoswitch-quarantine.json"

# --- Order by weekly reset and the floor. On 29/10/2026 leo-iacall, picked by hand, was at
# 93% of its week while proteauto and quasar held quota that would reset before it, and the
# chain order would have reached leonardo-rejani (reset in 4 days) before quasar. ---
rm -f "$W/cfg/autoswitch-quarantine.json" "$W/cfg/bg-restart.pending"
policy '["c"]'
usage_r() { # a5 a7 a_h b5 b7 b_h c5 c7 c_h: utilizations and hours until each weekly reset
  local now; now="$(date -u +%s)"
  { echo "a,allowed,200,$1,0,$2,$((now + $3 * 3600)),,"
    echo "b,allowed,200,$4,0,$5,$((now + $6 * 3600)),,"
    echo "c,allowed,200,$7,0,$8,$((now + ${9} * 3600)),,"; } > "$W/cfg/measured.csv"
}
usage_r 0.99 0.5 100  0.1 0.1 100  0.1 0.1 30
check "reset order: an exhausted account goes to the one that resets first" "decision=c reason=exhausted_next_has_room" "$(decide a)"
usage_r 0.1 0.1 200  0.1 0.1 100  0.1 0.1 30
check "reset order: up to an account that resets sooner" "decision=c reason=resets_sooner_has_room" "$(decide b)"
check "reset order: the log carries the order" 1 "$(tail -1 "$W/cfg/autoswitch.log" | grep -cE ' order=c,b,a( |$)')"
usage_r 0.1 0.1 200  0.1 0.1 100  0.8 0.1 30
check "reset order: not up while its five hours have not recovered" "decision=b reason=fallback_still_has_room" "$(decide b)"
usage_r 0.1 0.1 200  0.1 0.5 100  0.1 0.85 30
check "reset order: a sooner reset with little room is no switch" "decision=b reason=fallback_still_has_room" "$(decide b)"
usage_r 0.1 0.1 200  0.1 0.5 100  0.1 0.85 10
check "reset order: in its last day the floor is released and it is used" "decision=c reason=resets_sooner_has_room" "$(decide b)"
usage_r 0.1 0.9 50  0.1 0.5 100  0.1 0.5 120
check "floor: an account down to its floor hands over" "decision=b reason=at_floor_next_has_room" "$(decide a)"
usage_r 0.1 0.92 10  0.1 0.5 100  0.1 0.5 120
check "floor: released in the last 24h, the account keeps going" "decision=a reason=preferred_has_room" "$(decide a)"
usage_r 0.1 0.9 50  0.1 0.9 100  0.1 0.9 120
check "floor: all down to their floor, the active spends its own" "decision=a reason=floor_in_use_no_other_room" "$(decide a)"
usage_r 0.1 0.98 50  0.1 0.9 100  0.1 0.9 60
check "floor: exhausted, the floor that resets first is used" "decision=c reason=exhausted_next_has_room" "$(decide a)"
usage_r 0.1 0.5 100  0.99 0.5 30  0.1 0.9 50
check "manual: down to its floor, moves to the account with room" "decision=a reason=manual_choice_at_floor" "$(decide c a)"
usage_r 0.1 0.5 100  0.1 0.1 20  0.1 0.5 50
check "manual: above its floor, respected even with a sooner reset" "decision=c reason=manual_choice_respected" "$(decide c a)"

# The 29/10/2026 numbers, four accounts.
jq -n '{preferred:"proteauto", fallback:"leo-iacall", reserves:["leonardo-rejani","quasar"],
  exhausted_at:{five_hour:0.95, seven_day:0.97}, return_below:{five_hour:0.70, seven_day:0.90}}' > "$W/cfg/policy.json"
real29() { # hours until proteauto resets; the others keep their distance to it
  local now; now="$(date -u +%s)"
  { echo "proteauto,allowed,200,0.02,0,0.84,$((now + $1 * 3600)),,"
    echo "leo-iacall,allowed,200,0.63,0,0.93,$((now + ($1 + 8) * 3600)),,"
    echo "leonardo-rejani,allowed,200,0.0,0,0.37,$((now + ($1 + 56) * 3600)),,"
    echo "quasar,allowed,200,0.0,0,0.65,$((now + ($1 + 7) * 3600)),,"; } > "$W/cfg/measured.csv"
}
real29 32
check "29/10: leo-iacall picked by hand at 93% hands over to quasar" "decision=quasar reason=manual_choice_at_floor" "$(decide leo-iacall proteauto)"
real29 10
check "29/10: proteauto's last day, its quota is spent before it resets" "decision=proteauto reason=preferred_recovered" "$(decide quasar quasar)"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
