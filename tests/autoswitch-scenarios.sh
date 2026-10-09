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
  use) shift; echo "use $*" >> "$CLAUDE_ACCOUNT_HOME/calls.log" ;;
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

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
