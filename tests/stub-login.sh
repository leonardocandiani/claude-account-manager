# Sourced by the scenario tests after $S (the stub dir, holding a `security` stub) exists.
# Writes two stubs for the login check, so no test reaches the network:
#   curl     answers /api/oauth/profile: a Bearer token starting with DEAD is refused (401);
#            any other one is the account named in $STUB_EMAILS ("<token> <email>" lines),
#            or x@example.com; one starting with NET never gets an answer (000), one starting with NOMAIL answers 200 without an e-mail. /v1/messages (measure) logs the Bearer to $STUB_MEASURE_LOG
#            and answers allowed at 12% (5h) and 34% (7d).
#   claude-p plays `claude -p` refreshing the login kept for CLAUDE_SECURESTORAGE_CONFIG_DIR:
#            a refresh token starting with DEAD fails like an expired session; any other one
#            rotates (access and refresh get a -r suffix, expiry one hour ahead).
# A test's own `claude` stub hands `-p` over to claude-p.
cat > "$S/curl" <<'EOF'
#!/usr/bin/env bash
out=""; auth=""; url=""; hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) hdr="$2"; shift ;;
    -w|--max-time|-d) shift ;;
    -H) case "$2" in authorization:*) auth="${2#authorization: Bearer }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */api/oauth/profile)
    case "$auth" in DEAD*|'') printf 401; exit 0 ;; NET*) printf 000; exit 0 ;; NOMAIL*) printf '{"account":{}}' > "${out:-/dev/null}"; printf 200; exit 0 ;; esac
    email="$(grep "^$auth " "${STUB_EMAILS:-/dev/null}" 2>/dev/null | head -1 | cut -d' ' -f2)"
    printf '{"account":{"email":"%s"}}' "${email:-x@example.com}" > "${out:-/dev/null}"
    printf 200 ;;
  */v1/messages)
    echo "$auth" >> "${STUB_MEASURE_LOG:-/dev/null}"
    case "$auth" in DEAD*|'') printf 401; exit 0 ;; esac
    printf 'anthropic-ratelimit-unified-5h-status: allowed\nanthropic-ratelimit-unified-5h-utilization: 0.12\nanthropic-ratelimit-unified-7d-status: allowed\nanthropic-ratelimit-unified-7d-utilization: 0.34\n' > "${hdr:-/dev/null}"
    printf 200 ;;
  *) printf 000 ;;
esac
EOF
cat > "$S/claude-p" <<'EOF'
#!/usr/bin/env bash
item="Claude Code-credentials-$(printf '%s' "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" | shasum -a 256 | cut -c1-8)"
blob="$(security find-generic-password -a x -s "$item" -w 2>/dev/null)" || { echo "Not logged in"; exit 1; }
case "$(printf '%s' "$blob" | jq -r '.claudeAiOauth.refreshToken // ""')" in
  DEAD*|'') echo "Failed to authenticate: OAuth session expired and could not be refreshed"; exit 1 ;;
esac
echo "$item" >> "${STUB_REFRESH_LOG:-/dev/null}"
blob="$(printf '%s' "$blob" | jq -c --argjson e "$(( ($(date +%s) + 3600) * 1000 ))" \
  '.claudeAiOauth.accessToken += "-r" | .claudeAiOauth.refreshToken += "-r" | .claudeAiOauth.expiresAt = $e')"
security add-generic-password -U -a x -s "$item" -w "$blob"
echo ok
EOF
chmod +x "$S/curl" "$S/claude-p"
# Far in the future, in milliseconds: a fixture login that needs no refresh.
FAR=4102444800000
