#!/usr/bin/env bash
# Scenario tests for `claude-account renew`. `security`, `launchctl`, `curl`
# and the native `claude` are stubs on PATH. Pure: no network, no Keychain.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CLI="$here/../bin/claude-account"
fails=0; runs=0

STUB="$(mktemp -d)"
KC="$STUB/keychain"; mkdir -p "$KC"
cat > "$STUB/security" <<'EOF'
#!/usr/bin/env bash
KC="$(dirname "$0")/keychain"
cmd="$1"; shift
svc=""; blob=""; want_w=false
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift ;;
    -w) if [ "$cmd" = add-generic-password ]; then blob="$2"; shift; else want_w=true; fi ;;
    -a|-U) [ "$1" = -a ] && shift ;;
  esac
  shift
done
f="$KC/$(printf '%s' "$svc" | tr '/ ' '__')"
case "$cmd" in
  find-generic-password) [ -f "$f" ] || exit 44; $want_w && cat "$f"; exit 0 ;;
  add-generic-password) printf '%s' "$blob" > "$f"; exit 0 ;;
esac
EOF
cat > "$STUB/launchctl" <<'EOF'
#!/usr/bin/env bash
ENVF="$(dirname "$0")/launchctl.env"
case "$1" in setenv) printf '%s' "$3" > "$ENVF" ;; unsetenv) rm -f "$ENVF" ;; getenv) [ -f "$ENVF" ] && cat "$ENVF" ;; esac
exit 0
EOF
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
CFG="$(dirname "$0")/claude.cfg"
case "$1" in
  setup-token)
    echo "Opening browser..."; echo "Paste the code here:"
    [ -f "$CFG.notoken" ] && { echo "login cancelled"; exit 1; }
    echo " sk-ant-oat01-$(cat "$CFG.fake" 2>/dev/null || echo NEWTOKEN)"; exit 0 ;;
  auth)
    email="$(cat "$CFG.email" 2>/dev/null || echo leo@iacall.ai)"
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then printf '{"loggedIn":true,"email":"%s"}\n' "$email"; else echo '{"loggedIn":true,"email":"native@x"}'; fi ;;
esac
EOF
cat > "$STUB/curl" <<'EOF'
#!/usr/bin/env bash
# emulate: -o /dev/null -D <hdr> -w %{http_code} ... prints 200 and writes headers
hdr=""; while [ $# -gt 0 ]; do [ "$1" = -D ] && hdr="$2"; shift; done
ST="$(cat "$(dirname "$0")/curl.status" 2>/dev/null || echo 200)"
if [ "$ST" = 200 ]; then
  printf 'anthropic-ratelimit-unified-5h-status: allowed\r\nanthropic-ratelimit-unified-5h-utilization: 0.1\r\nanthropic-ratelimit-unified-5h-reset: 1\r\nanthropic-ratelimit-unified-7d-status: allowed\r\nanthropic-ratelimit-unified-7d-utilization: 0.2\r\nanthropic-ratelimit-unified-7d-reset: 2\r\nanthropic-ratelimit-unified-overage-status: allowed\r\n' > "$hdr"
fi
printf '%s' "$ST"
EOF
chmod +x "$STUB"/security "$STUB"/launchctl "$STUB"/claude "$STUB"/curl
export PATH="$STUB:$PATH" CLAUDE_NATIVE_BIN="$STUB/claude"

kc_get() { cat "$KC/$(printf '%s' "$1" | tr '/ ' '__')" 2>/dev/null || true; }
OAUTH="Claude Code OAuth Token - leo-iacall"; MEAS="Claude Code OAuth Token - proteauto-measure"

setup() {
  rm -rf "$KC"; mkdir -p "$KC"; rm -f "$STUB/launchctl.env" "$STUB"/claude.cfg.* "$STUB/curl.status"
  H="$(mktemp -d)"; export CLAUDE_ACCOUNT_HOME="$H"; mkdir -p "$H/profiles"
  printf '{"version":2,"name":"leo-iacall","type":"oauth_token","keychainService":"%s","label":"leo-iacall (setup-token leo@iacall.ai)"}' "$OAUTH" > "$H/profiles/leo-iacall.json"
  printf '{"version":2,"name":"proteauto","type":"native_archive","keychainService":"Claude Code-credentials-proteauto-archive","label":"proteauto","measureKeychainService":"%s"}' "$MEAS" > "$H/profiles/proteauto.json"
  printf 'sk-ant-oat01-OLD' > "$KC/$(printf '%s' "$OAUTH" | tr '/ ' '__')"
  printf 'proteauto' > "$H/active"
}
check_eq() { runs=$((runs + 1)); if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s: esperado [%s], veio [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }

# 1. happy path with --yes: token replaced, measured allowed
setup; out="$("$CLI" renew leo-iacall --yes 2>&1)"; rc=$?
check_eq "1a renew stores the new token" "$(kc_get "$OAUTH")" "sk-ant-oat01-NEWTOKEN"
check_eq "1b renew reports allowed" "$(printf '%s' "$out" | grep -c 'renewed: leo-iacall,allowed')" "1"
check_eq "1c launchctl untouched (profile not active)" "$(cat "$STUB/launchctl.env" 2>/dev/null || echo none)" "none"

# 2. renewing the ACTIVE oauth profile also updates launchctl
setup; printf 'leo-iacall' > "$H/active"; "$CLI" renew leo-iacall --yes >/dev/null 2>&1
check_eq "2  active profile: launchctl gets the new token" "$(cat "$STUB/launchctl.env")" "sk-ant-oat01-NEWTOKEN"

# 3. browser login cancelled: nothing changes
setup; touch "$STUB/claude.cfg.notoken"; "$CLI" renew leo-iacall --yes >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "3a cancelled login exits 1" "$rc" "1"
check_eq "3b old token kept" "$(kc_get "$OAUTH")" "sk-ant-oat01-OLD"

# 4. interactive: answering N aborts without writing
setup; printf '\nn\n' | "$CLI" renew leo-iacall >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "4a 'n' aborts" "$rc" "1"
check_eq "4b old token kept" "$(kc_get "$OAUTH")" "sk-ant-oat01-OLD"

# 5. interactive without a recorded account: asks the e-mail, stores it in the profile
setup; jq '.label = "leo-iacall (setup-token)"' "$H/profiles/leo-iacall.json" > "$H/p.tmp" && mv "$H/p.tmp" "$H/profiles/leo-iacall.json"
out="$(printf '\nleo@iacall.ai\ny\n' | "$CLI" renew leo-iacall 2>&1 || true)"
check_eq "5a asked for the e-mail" "$(printf '%s' "$out" | grep -c 'Which e-mail')" "1"
check_eq "5b token stored after y" "$(kc_get "$OAUTH")" "sk-ant-oat01-NEWTOKEN"
check_eq "5c e-mail recorded in the profile" "$(jq -r .account "$H/profiles/leo-iacall.json")" "leo@iacall.ai"
check_eq "5d token never echoed by the wizard" "$(printf '%s' "$out" | grep -c 'sk-ant-oat01-NEWTOKEN')" "0"

# 6. native_archive profile renews its measurement token
setup; "$CLI" renew proteauto --yes >/dev/null 2>&1
check_eq "6  native profile: measure token renewed" "$(kc_get "$MEAS")" "sk-ant-oat01-NEWTOKEN"

# 7. API refuses the new token (401): refused BEFORE storing, old token kept
setup; printf 401 > "$STUB/curl.status"; "$CLI" renew leo-iacall --yes >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "7a refused token exits 1" "$rc" "1"
check_eq "7b old token kept" "$(kc_get "$OAUTH")" "sk-ant-oat01-OLD"
# 8. --token-stdin: a token piped in without a trailing newline is still stored
setup; printf 'sk-ant-oat01-NONEWLINE' | "$CLI" renew leo-iacall --token-stdin >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "8a token-stdin without newline exits 0" "$rc" "0"
check_eq "8b token-stdin stored it" "$(kc_get "$OAUTH")" "sk-ant-oat01-NONEWLINE"

# 9. add-oauth --token-stdin: new profile with account, joins the rotation, token never printed
setup; printf '{"preferred":"proteauto","fallback":"leo-iacall","move_agents":true}' > "$H/policy.json"
out="$(printf 'sk-ant-oat01-ADDED' | "$CLI" add-oauth terceira --token-stdin --account t@x.io --reserve 2>&1)" && rc=0 || rc=$?
check_eq "9a add exits 0" "$rc" "0"
check_eq "9b token stored under the new profile" "$(kc_get "Claude Code OAuth Token - terceira")" "sk-ant-oat01-ADDED"
check_eq "9c account recorded" "$(jq -r .account "$H/profiles/terceira.json")" "t@x.io"
check_eq "9d appended to the chain as a reserve" "$(jq -c .reserves "$H/policy.json")" '["terceira"]'
check_eq "9e policy keeps its other keys" "$(jq -r .move_agents "$H/policy.json")" "true"
check_eq "9f measured on the way in" "$(printf '%s' "$out" | grep -c 'added: terceira,allowed')" "1"
check_eq "9g token never printed" "$(printf '%s' "$out" | grep -c 'sk-ant-oat01-ADDED')" "0"
printf 'sk-ant-oat01-ADDED' | "$CLI" add-oauth terceira --token-stdin --reserve >/dev/null 2>&1
check_eq "9h adding twice does not duplicate it in the chain" "$(jq -c .reserves "$H/policy.json")" '["terceira"]'

# 10. re-adding an existing OAuth profile replaces the token and keeps account and full login
setup; jq '.account = "leo@iacall.ai" | .secureStorageDir = "/x/logins/leo-iacall"' "$H/profiles/leo-iacall.json" > "$H/p.tmp" && mv "$H/p.tmp" "$H/profiles/leo-iacall.json"
printf 'sk-ant-oat01-READD' | "$CLI" add-oauth leo-iacall --token-stdin >/dev/null 2>&1
check_eq "10a token replaced" "$(kc_get "$OAUTH")" "sk-ant-oat01-READD"
check_eq "10b full login kept" "$(jq -r .secureStorageDir "$H/profiles/leo-iacall.json")" "/x/logins/leo-iacall"
check_eq "10c account kept" "$(jq -r .account "$H/profiles/leo-iacall.json")" "leo@iacall.ai"

# 11. add-oauth: refused token stores nothing, garbage on stdin is refused
setup; printf 401 > "$STUB/curl.status"
printf 'sk-ant-oat01-BAD' | "$CLI" add-oauth nova --token-stdin >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "11a refused token exits 1" "$rc" "1"
check_eq "11b no profile written" "$([ -f "$H/profiles/nova.json" ] && echo present || echo absent)" "absent"
check_eq "11c no Keychain item written" "$(kc_get "Claude Code OAuth Token - nova")" ""
printf 'not-a-token' | "$CLI" add-oauth nova --token-stdin >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "11d garbage on stdin exits 1" "$rc" "1"

# 9i. first account ever added to the rotation: no policy yet, bash 3.2 must not choke
setup; out="$(printf 'sk-ant-oat01-FIRST' | "$CLI" add-oauth primeira --token-stdin --reserve 2>&1)" && rc=0 || rc=$?
check_eq "9i no policy: add --reserve exits 0" "$rc" "0"
check_eq "9j no policy: it becomes the first of the chain" "$(jq -r .preferred "$H/policy.json")" "primeira"
check_eq "9k no policy: no fallback key invented" "$(jq -r 'has("fallback")' "$H/policy.json")" "false"

# 11e. the API cannot be reached: said as such, nothing stored
setup; printf 000 > "$STUB/curl.status"
out="$(printf 'sk-ant-oat01-NET' | "$CLI" add-oauth nova --token-stdin 2>&1)" && rc=0 || rc=$?
check_eq "11e network down exits 1" "$rc" "1"
check_eq "11f network down is named" "$(printf '%s' "$out" | grep -c 'could not reach the API')" "1"
check_eq "11g network down stores nothing" "$(kc_get "Claude Code OAuth Token - nova")" ""
setup; printf 204 > "$STUB/curl.status"
printf 'sk-ant-oat01-NOHDR' | "$CLI" add-oauth nova --token-stdin >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "11h a 2xx without quota headers is still a valid token" "$rc" "0"

# 12. rotation: show, set, on/off
setup; out="$("$CLI" rotation)"
check_eq "12a no policy: empty chain stated" "$(printf '%s' "$out" | grep -c '^chain: 0 accounts')" "1"
"$CLI" rotation set leo-iacall proteauto >/dev/null
check_eq "12b set writes preferred and fallback" "$(jq -c '[.preferred,.fallback,.reserves]' "$H/policy.json")" '["leo-iacall","proteauto",[]]'
out="$("$CLI" rotation)"
check_eq "12c show lists the chain in order" "$(printf '%s\n' "$out" | grep -E '^  [0-9],' | tr '\n' ' ')" "  1,leo-iacall   2,proteauto "
"$CLI" rotation set ghost proteauto >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "12d unknown profile refused" "$rc" "1"
"$CLI" rotation set proteauto proteauto >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "12e duplicate refused as usage" "$rc" "2"
"$CLI" rotation set proteauto >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "12e2 a rotation of one account is a usage error" "$rc" "2"
jq '.custom = {"keep": null}' "$H/policy.json" > "$H/pol.tmp" && mv "$H/pol.tmp" "$H/policy.json"
"$CLI" rotation set proteauto leo-iacall >/dev/null
check_eq "12e3 a null the user wrote survives set" "$(jq -c .custom "$H/policy.json")" '{"keep":null}'
"$CLI" rotation set leo-iacall proteauto >/dev/null
check_eq "12f refused set leaves the policy" "$(jq -r .preferred "$H/policy.json")" "leo-iacall"
"$CLI" rotation off >/dev/null
check_eq "12g off writes the kill switch" "$([ -e "$H/autoswitch.off" ] && echo yes || echo no)" "yes"
"$CLI" rotation on >/dev/null
check_eq "12h on removes it" "$([ -e "$H/autoswitch.off" ] && echo yes || echo no)" "no"
"$CLI" rotation bogus >/dev/null 2>&1 && rc=0 || rc=$?
check_eq "12i unknown subcommand exits 2" "$rc" "2"

rm -rf "$STUB"
printf '%d cenários, %d falhas\n' "$runs" "$fails"
[ "$fails" -eq 0 ]
