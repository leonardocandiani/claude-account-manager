# claude-account-manager

Troque entre múltiplas contas do Claude Code no macOS com um comando. Segredos vivem só no
Keychain do macOS: nada de token em dotfile, nada de re-login, nada de fallback silencioso pra
conta errada.

> Não afiliado nem endossado pela Anthropic. "Claude" e "Claude Code" são marcas da Anthropic.

[Read in English](README.md)

## O problema

O Claude Code resolve autenticação por várias camadas ao mesmo tempo: a variável
`CLAUDE_CODE_OAUTH_TOKEN`, uma credencial nativa no Keychain (`Claude Code-credentials`), metadado
de conta em `~/.claude.json`, seus shells de login e um daemon de fundo. Se você usa mais de uma
conta (uma assinatura Max pessoal e uma de trabalho, por exemplo), trocar só uma dessas camadas
deixa outra vencer em silêncio. A armadilha clássica: você parte de um setup-token, faz `/login`
numa segunda conta e depois não consegue voltar pro token sem reiniciar a máquina, porque a
credencial nativa que o `/login` gravou no Keychain sombreia o token.

Esta ferramenta transforma cada conta num perfil nomeado e troca todas as camadas de forma atômica.

## Como funciona

- Cada conta é um **perfil**: um **setup-token** OAuth (de `claude setup-token`) ou um **login
  nativo** (o que o `/login` cria).
- Todos os segredos ficam como itens do **Keychain** do macOS. Os arquivos de perfil e o marcador
  de perfil ativo não contêm segredo nenhum.
- `claude-account use <nome>` troca os slots do Keychain, sincroniza o `launchctl`, limpa metadado
  de conta antigo, para o daemon do Claude e (opcionalmente) reinicia o [Orca](https://orca.dev)
  pros processos persistentes pegarem a mudança. Toda credencial removida do slot ativo é
  arquivada no Keychain antes: a troca nunca destrói um login.
- Um wrapper `claude` em `~/bin` faz toda invocação da CLI rodar sob o perfil ativo, e o
  `shell-init.zsh` faz o mesmo pros shells de login.

## Requisitos

- macOS (a CLI `security` do Keychain é o cofre)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) instalado
- `jq` (`brew install jq`)
- shells de login zsh (o padrão do macOS)

## Instalação

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Depois adicione ao seu `~/.zprofile` a linha que o instalador imprime:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Garanta que `~/bin` vem **antes** do diretório do Claude Code no `PATH` (o instalador avisa se não
vier). Se o binário `claude` mora num lugar incomum, aponte com `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Uso

Registre a conta atual do `/login` como perfil e adicione uma segunda conta por setup-token
(rode `claude setup-token` logado nela pra obter um):

```bash
claude-account import-native pessoal
claude-account add-oauth trabalho
```

Troque entre elas, a qualquer hora, em qualquer direção, sem reboot:

```bash
claude-account use trabalho
claude-account use pessoal
```

Inspecione o estado:

```bash
claude-account list      # perfis, o ativo marcado com *
claude-account status    # perfil ativo + fingerprints (nunca os segredos)
claude-account doctor    # checa divergência em todas as camadas de auth
claude-account probe     # autentica e roda uma inferência mínima
```

O `use` reinicia o Orca (se instalado) pros processos vivos trocarem também; use `--no-restart`
pra pular. Shells novos sempre pegam o perfil ativo; sessões já abertas seguem na conta anterior
até reiniciar.

## Troubleshooting: `/login` sombreia o setup-token

Regra de bolso: depois de adotar esta ferramenta, troque de conta **somente** via
`claude-account use`, nunca pelo `/login` dentro do Claude Code.

Se o `/login` direto acontecer, ele grava uma credencial nativa no slot do Keychain que sombreia o
perfil de setup-token ativo, e o estado diverge em silêncio. O `claude-account doctor` mostra:

```
[FAIL] launchctl diverges from the active profile
[FAIL] a stale native login is still active (it shadows the setup-token)
```

A correção é um comando, sem reboot: `claude-account use <qualquer-perfil>`. A credencial do
`/login` não se perde; ela é arquivada no Keychain como o perfil `primary` antes do slot ser limpo.

## Integração com Orca

Se o [Orca](https://orca.dev) está instalado, a troca de perfil o reinicia pra o daemon e as
sessões Claude que ele criou adotarem a conta nova. Em máquinas sem Orca o helper nem é instalado
e nada é derrubado; reinicie seus terminais depois da troca.

## Notas de segurança

- Tokens são validados contra `claude auth status` antes de serem guardados.
- `status` e `doctor` imprimem fingerprints SHA-256, nunca segredos.
- Toda remoção do slot ativo do Keychain é precedida de cópia de arquivo, verificada por
  fingerprint.
- O metadado de conta em `~/.claude.json` é backupeado antes de ser limpo.

## Licença

[MIT](LICENSE)
