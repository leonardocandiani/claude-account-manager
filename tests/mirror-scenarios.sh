#!/usr/bin/env bash
# Scenario tests for `claude-account mirror`: setup-tokens copied to a laptop's
# claude-account (through its inbox and `mirror-import`) and to a server's name=token file. ssh is stubbed: it runs the remote
# command locally under a HOME of its own per host, so nothing leaves this machine, and it
# logs every command line, which proves no token ever travels in argv.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CA="$here/../bin/claude-account"
fails=0; runs=0

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
S="$W/stub"; mkdir -p "$S" "$W/kc" "$W/cfg/profiles" "$W/r/macpro/kc" "$W/r/macpro/.config/claude-account/profiles" "$W/r/node02"
export STUB_KC="$W/kc" SSH_LOG="$W/ssh.log" R="$W/r"
: > "$SSH_LOG"

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
  find-generic-password) [ -f "$f" ] || exit 44; $want && cat "$f" ;;
  add-generic-password) printf %s "$val" > "$f" ;;
esac
EOF
# ssh [-o opt]... host command: the command runs under $R/<host>; STUB_DOWN lists dead hosts.
cat > "$S/ssh" <<'EOF'
#!/usr/bin/env bash
while [ "$1" = -o ]; do shift 2; done
host="$1"; shift
printf '%s %s\n' "$host" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$SSH_LOG"
case " ${STUB_DOWN:-} " in *" $host "*) echo "ssh: connect to host $host: Operation timed out" >&2; exit 255 ;; esac
HOME="$R/$host" STUB_KC="$R/$host/kc" CLAUDE_ACCOUNT_HOME= exec sh -c "$*"
EOF
# What add-oauth checks a token with: signed in, and an allowed answer from the API.
cat > "$S/claude" <<'EOF'
#!/usr/bin/env bash
[ "$1" = auth ] && echo '{"loggedIn":true}'
EOF
cat > "$S/curl" <<'EOF'
#!/usr/bin/env bash
hdr=""; while [ $# -gt 0 ]; do [ "$1" = -D ] && hdr="$2"; shift; done
printf 'anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-7d-status: allowed\r\n' > "$hdr"
printf 200
EOF
chmod +x "$S"/*
export PATH="$S:$PATH" CLAUDE_ACCOUNT_HOME="$W/cfg" CLAUDE_NATIVE_BIN="$S/claude"
LAP="$W/r/macpro/.config/claude-account"
# The laptop's autoswitch run: its own HOME, Keychain and config.
laptop_import() { HOME="$W/r/macpro" STUB_KC="$W/r/macpro/kc" CLAUDE_ACCOUNT_HOME="$LAP" "$CA" mirror-import >/dev/null 2>&1; }
lap_kc() { STUB_KC="$W/r/macpro/kc" security find-generic-password -s "Claude Code OAuth Token - $1" -w; }

kc() { STUB_KC="$1" security add-generic-password -U -a x -s "$2" -w "$3"; }
check() {
  runs=$((runs + 1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $(printf %s "$2" | tr '\n' '|')"; echo "     got:  $(printf %s "$3" | tr '\n' '|')"; fails=$((fails + 1)); fi
}

# This machine: two setup-token profiles, two native ones (one measured by a token).
P="$W/cfg/profiles"
echo '{"name":"leo","type":"oauth_token","keychainService":"Claude Code OAuth Token - leo","account":"leo@example.com"}' > "$P/leo.json"
echo '{"name":"Ana","type":"oauth_token","keychainService":"Claude Code OAuth Token - Ana","account":"ana@example.com"}' > "$P/Ana.json"
echo '{"name":"proteauto","type":"native_archive","keychainService":"Claude Code-credentials-proteauto-archive","measureKeychainService":"Claude Code OAuth Token - proteauto"}' > "$P/proteauto.json"
echo '{"name":"quasar","type":"native_archive","keychainService":"Claude Code-credentials-quasar-archive","measureKeychainService":"Claude Code OAuth Token - quasar"}' > "$P/quasar.json"
echo '{"name":"solo","type":"native_archive","keychainService":"Claude Code-credentials-solo-archive"}' > "$P/solo.json"
kc "$W/kc" "Claude Code OAuth Token - leo" "sk-ant-oat01-LEOTOKEN"
kc "$W/kc" "Claude Code OAuth Token - Ana" "sk-ant-oat01-ANATOKEN"
kc "$W/kc" "Claude Code OAuth Token - proteauto" "sk-ant-oat01-PROTNEW"
kc "$W/kc" "Claude Code OAuth Token - quasar" "sk-ant-oat01-QUASTOKEN"
kc "$W/kc" "Claude Code-credentials-solo-archive" '{"claudeAiOauth":{"refreshToken":"SOLOREFRESH"}}'

# The server: leo first (its fail-safe), an old proteauto, a quasar it must lose.
ENVF="$W/r/node02/claude-tokens.env"
printf 'leo=sk-ant-oat01-LEOTOKEN\nproteauto=sk-ant-oat01-PROTOLD\nquasar=sk-ant-oat01-QUASTOKEN\n' > "$ENVF"
# The laptop: leo is its own native login, proteauto an old setup-token.
RP="$W/r/macpro/.config/claude-account/profiles"
echo '{"name":"leo","type":"native_archive","keychainService":"Claude Code-credentials-leo-archive"}' > "$RP/leo.json"
echo '{"name":"proteauto","type":"oauth_token","keychainService":"Claude Code OAuth Token - proteauto"}' > "$RP/proteauto.json"
echo '{"preferred":"leo","fallback":"proteauto"}' > "$LAP/policy.json"
kc "$W/r/macpro/kc" "Claude Code OAuth Token - proteauto" "sk-ant-oat01-PROTOLD"

cat > "$W/cfg/mirror.json" <<EOF
{"targets":[{"host":"macpro","kind":"claude-account"},
  {"host":"node02","kind":"env-file","path":"$ENVF","exclude":["quasar"]}]}
EOF

out="$("$CA" mirror 2>&1)"; rc=$?
check 'mirror: exit 0' 0 "$rc"
check 'server: known names keep their place, the new one goes last, the excluded one goes away' \
  "$(printf 'leo=sk-ant-oat01-LEOTOKEN\nproteauto=sk-ant-oat01-PROTNEW\nana=sk-ant-oat01-ANATOKEN')" "$(cat "$ENVF")"
check 'server: the file stays 600' 600 "$(stat -f %Lp "$ENVF")"
check 'laptop: Ana, proteauto and quasar wait in its inbox, its own native login does not' \
  "Ana proteauto quasar" "$(ls "$LAP/inbox" | tr '\n' ' ' | sed 's/ $//')"
check 'laptop: the inbox is 700 and its files 600' "700 600" "$(stat -f %Lp "$LAP/inbox") $(stat -f %Lp "$LAP/inbox/Ana")"
laptop_import
check 'laptop import: the inbox is emptied' "" "$(ls "$LAP/inbox")"
check 'laptop import: the tokens arrived whole' "sk-ant-oat01-PROTNEW sk-ant-oat01-ANATOKEN" "$(lap_kc proteauto) $(lap_kc Ana)"
check 'laptop import: the new accounts join the end of its chain, with their e-mail' \
  'leo proteauto Ana quasar ana@example.com' "$(jq -r '[.preferred, .fallback] + .reserves | join(" ")' "$LAP/policy.json") $(jq -r .account "$LAP/profiles/Ana.json")"
check 'laptop import: its own native login is untouched' native_archive "$(jq -r .type "$LAP/profiles/leo.json")"
check 'a native login with no setup-token never travels' 0 "$(grep -rc SOLOREFRESH "$ENVF" "$SSH_LOG" "$LAP" | awk -F: '{s+=$2} END {print s}')"
check 'no token in any ssh command line' 0 "$(grep -c 'sk-ant-oat01-[A-Z]' "$SSH_LOG" || true)"
check 'no token in the output or the log' 0 "$(printf '%s\n' "$out" | cat - "$W/cfg/mirror.log" | grep -c 'sk-ant-oat01-[A-Z]' || true)"
check 'the log names what moved' 1 "$(grep -c 'node02: .*-quasar +ana(.*) +proteauto(' "$W/cfg/mirror.log")"

# Nothing changed: no write, no add-oauth, both say up to date.
: > "$SSH_LOG"; sum="$(shasum "$ENVF")"
out="$("$CA" mirror 2>&1)"
check 'second run: both targets up to date' 2 "$(printf '%s\n' "$out" | grep -c 'up to date')"
check 'second run: the server file is not rewritten' "$sum" "$(shasum "$ENVF")"
check 'second run: only the two inventories went out' 2 "$(wc -l < "$SSH_LOG" | tr -d ' ')"

# --auto (what the autoswitch runs): within the hour and with the same tokens, no ssh at all.
: > "$SSH_LOG"
"$CA" mirror --auto >/dev/null 2>&1
check 'auto: nothing changed in the last hour, nothing sent' 0 "$(wc -l < "$SSH_LOG" | tr -d ' ')"
# A renewed token goes out on the next run.
kc "$W/kc" "Claude Code OAuth Token - Ana" "sk-ant-oat01-ANARENEWED"
"$CA" mirror --auto >/dev/null 2>&1
check 'auto: a renewed token reaches the server' "ana=sk-ant-oat01-ANARENEWED" "$(grep '^ana=' "$ENVF")"
laptop_import
check 'auto: and the laptop, as an update' "sk-ant-oat01-ANARENEWED" "$(lap_kc Ana)"
# A token left for a name that is a login of its own there is dropped, never imported.
mkdir -p "$LAP/inbox"; printf 'sk-ant-oat01-INTRUDER\n\n0\n' > "$LAP/inbox/leo"
laptop_import
check 'import: never over a login of its own' "native_archive " "$(jq -r .type "$LAP/profiles/leo.json") $(ls "$LAP/inbox")"

# A host that does not answer: exit 1, said in the log, and retried next run.
kc "$W/kc" "Claude Code OAuth Token - leo" "sk-ant-oat01-LEORENEWED"
set +e; STUB_DOWN=macpro "$CA" mirror --auto >/dev/null 2>&1; rc=$?; set -e
check 'down: exit 1' 1 "$rc"
check 'down: the log says it' 1 "$(grep -c 'macpro: unreachable' "$W/cfg/mirror.log")"
check 'down: the other target still got it' "leo=sk-ant-oat01-LEORENEWED" "$(head -1 "$ENVF")"
: > "$SSH_LOG"
"$CA" mirror --auto >/dev/null 2>&1
check 'down: the next run tries the laptop again' 1 "$(grep -c '^macpro ' "$SSH_LOG")"

# No mirror.json: nothing to do, quiet.
mv "$W/cfg/mirror.json" "$W/cfg/mirror.off"
check 'no targets: exit 0 and a note' "claude-account: mirror: no targets (write $W/cfg/mirror.json)" "$("$CA" mirror 2>&1)"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
