# claude-usebar

Widget de **bandeja do sistema (notification area)** do Windows que mostra o consumo de uso do
Claude Code em tempo real. É um port do [claudebar](https://github.com/mryll/claudebar) — que no
Linux é um widget de Waybar em Bash — para a bandeja do Windows, escrito como **um único script
PowerShell**, sem build e com dependências mínimas.

O ícone exibe o `%` de uso (cor por severidade); ao clicar, abre um popup com as três janelas
(Sessão 5h, Semana 7d e Sonnet 7d), barras de progresso, contagem regressiva até o reset, o
indicador de ritmo (pacing: `↑` acima / `→` no ritmo / `↓` abaixo do consumo sustentável),
o **modelo em uso** (lido do transcript mais recente do Claude Code) e um **countdown ao
vivo** até a próxima atualização do uso. O popup é **responsivo**: ao redimensioná-lo,
fontes, barras e espaçamentos escalam proporcionalmente. Opcionalmente, exibe uma **imagem
de fundo** (modo cover) sob um véu escuro que preserva a legibilidade.

```
Bandeja:  ...  [16]  🔊 📶 🕐
                 │ (clique)
   ┌─────────────────────────────────────┐
   │ Claude · Team · Fable 5             │
   │ Sessão (5h)                  16% →   │
   │ ▓▓░░░░░░░░░░░░░░░░░░░  reset em 4h   │
   │ Semana (7d)                  39% ↓   │
   │ ▓▓▓▓▓▓▓░░░░░░░░░░░░░  reset em 2d 23h│
   │ Sonnet (7d)                   0% →   │
   │ ░░░░░░░░░░░░░░░░░░░░  reset em 7d    │
   │ atualiza em 3:47                     │
   └─────────────────────────────────────┘
```

## Instalação

Cole este comando em qualquer janela do **PowerShell** (Win+R → `powershell` → Enter):

```powershell
irm https://raw.githubusercontent.com/EnzoBarcelos/-claude-usebar-cruzeiro/main/install.ps1 | iex
```

O instalador faz tudo: instala o PowerShell 7 se faltar (via winget), baixa o widget para
`%LOCALAPPDATA%\claude-usebar`, configura o início automático com o Windows e já inicia o
ícone na bandeja. **Para atualizar**, basta colar o mesmo comando de novo.

Para remover o autostart: `pwsh -File "$env:LOCALAPPDATA\claude-usebar\claude-usebar.ps1" -Uninstall`.

## Requisitos

- **Windows 10/11**. O PowerShell 7.4+ (`pwsh`) é instalado automaticamente pelo instalador
  se não existir. Testado em PowerShell 7.6.
- **Claude CLI logado** — o widget lê as credenciais OAuth de `%USERPROFILE%\.claude\.credentials.json`.
- Assinatura **Claude Pro/Max/Team** (o endpoint de uso só existe para essas contas).

> Não requer `curl`, `jq` nem nada além do PowerShell — `Invoke-RestMethod`, `ConvertFrom-Json`
> e `[DateTimeOffset]` cobrem tudo. As classes auxiliares em C# (P/Invoke + form do popup) são
> compiladas em runtime via `Add-Type`; não há etapa de build.

## Uso manual / desenvolvimento

Rodar diretamente (relança-se em STA e esconde o console automaticamente):

```powershell
pwsh -File .\claude-usebar.ps1
```

Para depurar com o console visível:

```powershell
pwsh -Sta -File .\claude-usebar.ps1 -Foreground
```

Diagnóstico sem UI (imprime o uso em JSON e sai — útil para checar credenciais/endpoint):

```powershell
pwsh -File .\claude-usebar.ps1 -Once
```

### Iniciar com o Windows (autostart)

```powershell
pwsh -File .\claude-usebar.ps1 -Install     # cria launcher .vbs + atalho na pasta Inicializar
pwsh -File .\claude-usebar.ps1 -Uninstall   # remove o atalho (mantém config e cache)
```

O `-Install` gera `claude-usebar-launcher.vbs` ao lado do script e um atalho em
`shell:startup`. O `.vbs` sobe o `pwsh` **oculto desde a criação** (sem flash de console no
logon). Para iniciar agora, sem reiniciar a sessão: `wscript claude-usebar-launcher.vbs`.

### Menu (clique direito no ícone)

- **Atualizar agora** — força uma consulta (respeitando o piso de rate limit).
- **Ícone: max/5h/7d** — alterna qual janela o `%` do ícone reflete.
- **Abrir página de uso** — abre `claude.ai/settings/usage`.
- **Sobre** / **Sair**.

## Configuração

`%LOCALAPPDATA%\claude-usebar\config.json` (criado/validado na primeira execução):

```jsonc
{
  "intervalSec": 300,          // intervalo de atualização (mínimo e padrão: 300s)
  "pacingTolerancePct": 5,     // banda ± para o indicador "→ no ritmo"
  "mode": "5h",                // qual % vai no ícone: "5h" (sessão, padrão) | "7d" | "max"
  "showRemaining": true,
  "iconStyle": "pct",
  "backgroundImage": null,     // caminho de imagem de fundo do popup (null = fundo sólido)
  "backgroundDarken": 0.75,    // véu escuro sobre a imagem: 0 (sem véu) a 0.95 (quase preto)
  "colors": { "low": "#7f1010", "mid": "#b71c1c", "high": "#e53935", "critical": "#ff1744" }
}
```

Severidade por uso: `low` 0–49 · `mid` 50–74 · `high` 75–89 · `critical` ≥90.

## Como funciona

- **Credenciais:** lê `.claudeAiOauth` de `%USERPROFILE%\.claude\.credentials.json`. Se o token
  expira em menos de 5 min, renova via `POST platform.claude.com/v1/oauth/token` e **regrava o
  arquivo de forma atômica** (`File.Replace` + `.bak`, UTF-8 sem BOM), preservando todos os
  outros campos e **abortando se o CLI já tiver rotacionado o token** (anti-corrupção).
- **Uso:** `GET api.anthropic.com/api/oauth/usage` (`Authorization: Bearer` + `anthropic-beta`).
- **Cache:** `%LOCALAPPDATA%\claude-usebar\cache.json`.
- **Rate limit:** o endpoint **não é documentado e tem rate limit agressivo**. Atualizações
  abaixo de **300s** podem retornar **HTTP 429** — por isso o intervalo mínimo é 300s e o
  "Atualizar agora" respeita esse piso (serve cache se chamado cedo demais). Em 429, o widget
  faz backoff exponencial automaticamente.

## Estados de erro (no ícone/tooltip)

| Ícone | Situação |
|---|---|
| `?` cinza | Não logado — rode `claude login` |
| `!` vermelho | Falha ao renovar o token |
| `·` esmaecido | Rate limited — exibindo cache |
| `-` esmaecido | Offline — exibindo cache |
| `%` esmaecido | Dado vindo do cache (não foi possível atualizar agora) |

## Limitações

- O ícone da bandeja tem ~16–32 px (conforme o DPI), então mostra apenas o `%` inteiro
  (`99+` quando ≥100). O detalhamento completo fica no popup.
- O endpoint de uso é interno/não documentado da Anthropic e pode mudar sem aviso.
- Antivírus/EDR podem sinalizar `wscript.exe` lançando `pwsh` no autostart — é o launcher do
  próprio widget.

## Licença

Port inspirado no [claudebar](https://github.com/mryll/claudebar) (mryll).
