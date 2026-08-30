# Bootstrap de conta Claude para shells login (incluindo os criados pelo Orca).
# Nao contem segredo: le o perfil ativo e busca a credencial no Keychain.

_CLAUDE_ACCOUNT_HOME="${CLAUDE_ACCOUNT_HOME:-$HOME/.config/claude-account}"
_CLAUDE_ACCOUNT_ACTIVE_FILE="$_CLAUDE_ACCOUNT_HOME/active"

if [ -r "$_CLAUDE_ACCOUNT_ACTIVE_FILE" ]; then
  _CLAUDE_ACCOUNT_ACTIVE="$(tr -d '[:space:]' < "$_CLAUDE_ACCOUNT_ACTIVE_FILE")"
  _CLAUDE_ACCOUNT_PROFILE="$_CLAUDE_ACCOUNT_HOME/profiles/$_CLAUDE_ACCOUNT_ACTIVE.json"
  if [ -r "$_CLAUDE_ACCOUNT_PROFILE" ] && command -v jq >/dev/null 2>&1; then
    _CLAUDE_ACCOUNT_TYPE="$(jq -r '.type // empty' "$_CLAUDE_ACCOUNT_PROFILE" 2>/dev/null)"
    _CLAUDE_ACCOUNT_SERVICE="$(jq -r '.keychainService // empty' "$_CLAUDE_ACCOUNT_PROFILE" 2>/dev/null)"
    case "$_CLAUDE_ACCOUNT_TYPE" in
      oauth_token)
        _CLAUDE_ACCOUNT_TOKEN="$(security find-generic-password \
          -a "$USER" -s "$_CLAUDE_ACCOUNT_SERVICE" -w 2>/dev/null || true)"
        if [ -n "$_CLAUDE_ACCOUNT_TOKEN" ]; then
          export CLAUDE_CODE_OAUTH_TOKEN="$_CLAUDE_ACCOUNT_TOKEN"
        fi
        unset _CLAUDE_ACCOUNT_TOKEN
        ;;
      native_archive)
        unset CLAUDE_CODE_OAUTH_TOKEN
        ;;
    esac
  fi
fi

unset _CLAUDE_ACCOUNT_HOME _CLAUDE_ACCOUNT_ACTIVE_FILE _CLAUDE_ACCOUNT_ACTIVE
unset _CLAUDE_ACCOUNT_PROFILE _CLAUDE_ACCOUNT_TYPE _CLAUDE_ACCOUNT_SERVICE
