# claude-account-manager na frota (Studio e Mini)

Fork operacional do repo de ricardo-landim, adaptado em 08/09/2026 depois de
medir o comportamento real do Claude Code 2.1.263 nesta frota. O upstream é um
trocador manual; aqui ele ganhou a troca automática por limite e perdeu tudo
que matava processo.

## O que mudou em relação ao upstream

1. **A variável vence o Keychain.** `CLAUDE_CODE_OAUTH_TOKEN` no ambiente ganha
   do login nativo: `claude auth status` devolve `authMethod=oauth_token` com os
   dois presentes. Por isso `use <perfil-token>` não apaga mais a credencial
   nativa nem mexe em `~/.claude.json`. Sessão nativa que já estava rodando
   continua renovando o token dela.
2. **Nada é morto.** O `restart-orca.sh` do upstream mandava SIGTERM pra todo
   processo `claude`, o que aqui derruba jobs em background e workers de
   produção. Ele não é instalado. Processo novo pega o perfil ativo; processo
   vivo fica na conta em que nasceu. `use --stop-daemon` existe como opt-in.
3. **Arquivo do nativo é atualizado antes de ser deslocado.** O login nativo
   rotaciona token enquanto está no slot; o upstream restaurava uma cópia velha.
   Agora todo `use` re-arquiva o slot vivo no perfil nativo ativo antes de
   trocar qualquer coisa.
4. **`measure`.** Um setup-token só tem escopo de inferência (não lê
   `/api/oauth/usage`), então o estado real de limite sai dos headers
   `anthropic-ratelimit-unified-*` de uma chamada mínima (haiku, 1 token de
   saída). Perfil nativo mede por um token da mesma conta
   (`measureKeychainService`). É o mesmo mecanismo que o probe do segsclaw usa
   no Mini desde agosto.
5. **`claude-account-autoswitch`.** Script puro (bash, jq, curl), sem IA, que o
   launchd roda a cada 5 min: mede os dois perfis e troca quando a conta
   preferida estourou e a outra tem folga. Histerese pra voltar, intervalo
   mínimo entre trocas, teto diário, kill switch por arquivo, log sem segredo.

## Layout

```
~/bin/claude-account               CLI (add-oauth, import-native, use, list,
                                   status, doctor, probe, measure, exec)
~/bin/claude-account-autoswitch    decisor headless
~/bin/claude                       wrapper genérico (não usado onde a função
                                   claude() do shell já roteia pelo perfil)
~/.config/claude-account/
  active                           nome do perfil ativo (sem segredo)
  profiles/<nome>.json             tipo, serviço do Keychain, rótulo
  policy.json                      preferida, fallback, limiares, tetos
  autoswitch.log                   uma linha por rodada
  autoswitch-state.json            última troca, contagem do dia
  autoswitch.off                   se existir, o autoswitch não faz nada
~/Library/LaunchAgents/com.leo.claude-account-autoswitch.plist
Keychain:
  Claude Code OAuth Token - <nome>          setup-token de cada conta
  Claude Code-credentials-<nome>-archive    cópia do login nativo
```

## Contas e perfis nesta frota

| Perfil | Conta | Tipo no Studio e no Mini | Overage |
|---|---|---|---|
| proteauto | comercial@proteautobrasil.com.br (Max) | native_archive (login nativo, mede por token) | habilitado (cobra extra) |
| leo-iacall | conta do Leo | oauth_token (setup-token) | sem crédito |

Política: preferida `proteauto`, fallback `leo-iacall`. Estourou = status
`rejected` ou 5h >= 95% ou 7d >= 97%. Volta pra preferida quando ela estiver
abaixo de 70% (5h) e 90% (7d). Máximo 12 trocas por dia, 10 min entre trocas.

A troca é por `launchctl setenv`, e job novo do launchd herda (provado com um
agente descartável). Cobre: sessão interativa nova (função `claude()` do
`.zshrc`/`.zprofile`), qualquer coisa que o launchd inicie depois da troca e não
tenha token fixo no plist, e `claude-account exec`.

Não cobre: processo que já estava rodando; job spawnado pelo daemon do Claude
Code enquanto o daemon não reinicia (ele nasce com o ambiente da sessão que o
subiu); plist com `CLAUDE_CODE_OAUTH_TOKEN` fixo (no Mini: whatsapp-agent e o
probe do segsclaw, que têm failover próprio). Pra um job específico seguir o
perfil ativo na hora, invocar por `~/bin/claude-account exec -p ...`.

## Operação

```
claude-account status               perfil ativo e fingerprints
claude-account measure              limite real das duas contas
claude-account use leo-iacall       troca manual (o autoswitch respeita
                                    histerese, mas volta pra preferida quando
                                    ela tiver folga; pra segurar, touch
                                    ~/.config/claude-account/autoswitch.off)
claude-account-autoswitch --dry-run decisão sem aplicar
tail -f ~/.config/claude-account/autoswitch.log
```

## Como o Mini foi instalado

O Keychain de login não atende sessão SSH ("User interaction is not allowed"),
então `lib/setup-frota.sh` roda dentro da sessão gráfica por um agente launchd
descartável no domínio `gui`. O script lê os dois tokens do plist local do
whatsapp-agent, confere o SHA-256 de cada um contra os fingerprints conhecidos
(`a10c8c0e` proteauto, `51e2e513` leo-iacall) antes de rotular, e faz o resto.
Observação: o plist `com.segsclaw.claude-account-probe` do Mini tem os dois
tokens em ordem invertida em relação ao `com.claude.whatsapp-agent`, e os
rótulos do state (`~/.segsclaw/claude-accounts.json`) saem trocados por isso.
O roteamento por índice funciona; só o nome no log está errado.
