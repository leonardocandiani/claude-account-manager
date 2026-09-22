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

rm -rf "$STUB"
printf '%d cenários, %d falhas\n' "$runs" "$fails"
[ "$fails" -eq 0 ]
