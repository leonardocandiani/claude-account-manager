<!-- Banner -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0F0E0D,35:8C4A32,70:D97757,100:F5E6D3&height=240&section=header&text=claude-account-manager&fontSize=52&fontColor=F5E6D3&animation=fadeIn&fontAlignY=38&desc=Troque%20de%20conta%20do%20Claude%20Code%20no%20macOS%20%E2%80%94%20um%20comando%2C%20sem%20re-login&descAlignY=60&descSize=16" />
</div>

<!-- Typing -->
<div align="center">
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=21&duration=2800&pause=900&color=D97757&center=true&vCenter=true&width=840&lines=Troque+entre+contas+do+Claude+Code+com+um+comando;Segredos+s%C3%B3+no+Keychain+%E2%80%94+nada+de+token+em+dotfile;Todas+as+camadas+de+auth+trocadas+atomicamente;doctor+%C2%B7+status+%C2%B7+probe+%E2%80%94+nunca+imprimem+segredo" />
</div>

<!-- Status -->
<div align="center">
  <img src="https://img.shields.io/badge/Plataforma-macOS-0F0E0D?style=for-the-badge&logo=apple&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Segredos-S%C3%B3%20Keychain-D97757?style=for-the-badge&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/Para-Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Bash%20%2B%20jq-8C4A32?style=for-the-badge&logo=gnubash&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Licen%C3%A7a-MIT-25a162?style=for-the-badge" />
</div>

> O **claude-account-manager** transforma cada conta do Claude Code num perfil nomeado e troca todas com um único comando: sem re-login, sem reboot, sem token colado em dotfile, sem fallback silencioso pra conta errada. Segredos vivem exclusivamente no Keychain do macOS.

> Não afiliado nem endossado pela Anthropic. "Claude" e "Claude Code" são marcas da Anthropic.

[Read in English](README.md)

<br>

## O que é

```yaml
produto:      trocador multi-conta do Claude Code no macOS
contas:       perfis nomeados — setup-token OAuth ou /login nativo
cofre:        só o Keychain do macOS (zero segredo em dotfile, JSON ou log)
troca:        claude-account use <nome> — atômica em todas as camadas
camadas:      slots do Keychain · launchctl · ~/.claude.json · daemon · shells
segurança:    credencial deslocada é arquivada antes, verificada por fingerprint
diagnóstico:  doctor · status · probe (fingerprints SHA-256, nunca segredos)
extras:       integração Orca opcional · override CLAUDE_NATIVE_BIN
```

## O problema

O Claude Code resolve autenticação por várias camadas ao mesmo tempo: a variável
`CLAUDE_CODE_OAUTH_TOKEN`, uma credencial nativa no Keychain (`Claude Code-credentials`), metadado
de conta em `~/.claude.json`, seus shells de login e um daemon de fundo. Trocar só uma dessas
camadas deixa outra vencer em silêncio.

A armadilha clássica: você parte de um setup-token, faz `/login` numa segunda conta e depois não
consegue voltar pro token sem reiniciar a máquina, porque a credencial nativa que o `/login`
gravou no Keychain sombreia o token.

## Arquitetura

```
              ~/.config/claude-account/active          (nome do perfil, sem segredo)
                              │
      claude (wrapper) ──▶ exec sob o perfil ativo ──▶ binário claude real
                              │
        ┌─────────────────────┼─────────────────────────┐
        ▼                     ▼                         ▼
  Keychain do macOS      launchctl env             ~/.claude.json
  slots por perfil   CLAUDE_CODE_OAUTH_TOKEN     metadado de conta
        └─────────────────────┴─────────────────────────┘
                              │
        claude-account use <nome>  = troca TODAS atomicamente,
        arquivando o que remove (a troca nunca destrói um login)
```

## Quick start

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Adicione ao `~/.zprofile` a linha que o instalador imprime:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Registre o `/login` atual como perfil, adicione a segunda conta por setup-token
(rode `claude setup-token` logado nela) e troque à vontade:

```bash
claude-account import-native pessoal
claude-account add-oauth trabalho
claude-account use trabalho
claude-account use pessoal
```

> [!NOTE]
> O `use` reinicia o [Orca](https://orca.dev) (se instalado) pros processos vivos trocarem também;
> use `--no-restart` pra pular. Shells novos sempre pegam o perfil ativo; sessões já abertas
> seguem na conta anterior até reiniciar.

## Comandos

| | Comando | O que faz |
|:---:|---|---|
| ➕ | `add-oauth <nome>` | registra um perfil por setup-token (validado antes de guardar) |
| 📥 | `import-native [nome]` | importa a credencial do `/login` atual como perfil |
| 🔁 | `use <nome>` | troca todas as camadas de auth pro perfil, atomicamente |
| 📋 | `list` | perfis, o ativo marcado com `*` |
| 🩺 | `doctor` | checa divergência em todas as camadas |
| 📊 | `status` | perfil ativo + fingerprints (nunca os segredos) |
| 🧪 | `probe` | autentica e roda uma inferência mínima |

## Troubleshooting

> [!WARNING]
> Depois de adotar a ferramenta, troque de conta **somente** via `claude-account use`, nunca pelo
> `/login` dentro do Claude Code. Um `/login` direto grava uma credencial nativa que sombreia o
> perfil de setup-token ativo, e o estado diverge em silêncio.

Se acontecer mesmo assim, o `doctor` pega:

```
[FAIL] launchctl diverges from the active profile
[FAIL] a stale native login is still active (it shadows the setup-token)
```

A correção é um comando, sem reboot: `claude-account use <qualquer-perfil>`. A credencial do
`/login` não se perde; ela é arquivada no Keychain como o perfil `primary` antes do slot ser limpo.

## Requisitos

- macOS (a CLI `security` do Keychain é o cofre)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) instalado
- `jq` (`brew install jq`)
- shells de login zsh (o padrão do macOS)

`~/bin` precisa vir **antes** do diretório do Claude Code no `PATH` (o instalador avisa se não
vier). Instalação em lugar incomum? Aponte com `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Notas de segurança

- Tokens são validados contra `claude auth status` antes de serem guardados.
- `status` e `doctor` imprimem fingerprints SHA-256, nunca segredos.
- Toda remoção do slot ativo do Keychain é precedida de cópia de arquivo, verificada por
  fingerprint.
- O metadado de conta em `~/.claude.json` é backupeado antes de ser limpo.
- Em máquina sem Orca, o helper de restart nem é instalado e nada é derrubado.

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — invariantes e ADRs
- [`install.sh`](install.sh) — o que vai pra onde (`~/bin`, `~/.local/lib`, `~/.config`)

---

## Feito pela Six Quasar

A **Six Quasar** constrói agentes de IA que trabalham de verdade: WhatsApp como interface, núcleo
determinístico, IA na borda. Esta ferramenta nasceu da operação diária de múltiplas contas do
Claude Code nessa frota.

<a href="https://github.com/ricardo-landim"><img src="https://img.shields.io/badge/Perfil%20no%20GitHub-181717?style=for-the-badge&logo=github&logoColor=white" /></a>
<a href="https://sixquasar.shop"><img src="https://img.shields.io/badge/sixquasar.shop-D97757?style=for-the-badge&logo=safari&logoColor=F5E6D3" /></a>

<!-- Footer -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:D97757,40:8C4A32,100:0F0E0D&height=120&section=footer" />
</div>
