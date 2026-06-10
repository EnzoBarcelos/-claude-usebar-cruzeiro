# Design — Instalação em 1 comando e distribuição do claude-usebar

**Data:** 2026-06-10
**Objetivo:** permitir que colegas da Engetower instalem o claude-usebar colando um único comando no PowerShell, substituindo o processo manual (copiar script, ter pwsh 7.4+, rodar `-Install` na mão).

## Decisões

| Tema | Decisão |
|---|---|
| Público | Colegas da Engetower |
| Experiência de instalação | Um comando colado: `irm <url> \| iex` |
| Hospedagem | Repositório **público** no GitHub (URL raw acessível sem login) |
| PowerShell 7 ausente | O instalador instala automaticamente via `winget` |
| Atualizações | Reexecutar o mesmo comando baixa a versão nova por cima (sem auto-update no widget) |

## Arquitetura

- **`install.ps1`** (novo, raiz do repo): roda no **Windows PowerShell 5.1** (nativo de todo Windows), pois é nele que o `irm | iex` será colado. Responsabilidades, em ordem:
  1. Forçar TLS 1.2 (necessário no PS 5.1).
  2. Resolver `pwsh` 7.4+ (PATH ou `$env:ProgramFiles\PowerShell\7\pwsh.exe`); instalar `Microsoft.PowerShell` via winget se ausente/antigo.
  3. Baixar `claude-usebar.ps1` (raw do GitHub) para `%LOCALAPPDATA%\claude-usebar\` — local fixo e padronizado, mesmo diretório do config/cache.
  4. Encerrar instância em execução (atualização): processos `pwsh` com `claude-usebar.ps1` na linha de comando.
  5. Rodar `pwsh -NoProfile -File <script> -Install` (reusa o `Install-Autostart` existente, que é independente de caminho).
  6. Iniciar o widget agora via `wscript` no launcher gerado.
  7. Avisar se `%USERPROFILE%\.claude\.credentials.json` não existir (precisa de `claude login`).
- **`claude-usebar.ps1`**: sem mudanças estruturais; remove-se apenas o bloco de primeira execução que adota `Desktop\cruzeiro_2.jpg` como fundo (referência pessoal; o recurso `backgroundImage` permanece via config).
- **`.gitignore`**: exclui `claude-usebar-launcher.vbs` (gerado, com caminhos da máquina) e `.claude/`.
- **`README.md`**: nova seção "Instalação" no topo com o comando de uma linha; seção "Uso" vira uso manual/desenvolvimento.

## Tratamento de erros (instalador)

- winget ausente → mensagem orientando instalar o "Instalador de Aplicativo" da Microsoft Store e parar.
- Falha de download → mensagem clara com a URL; nada é sobrescrito parcialmente (baixa para arquivo temporário e move).
- Sem credenciais do Claude → instala mesmo assim e avisa que o ícone mostrará `?` até o `claude login`.

## Verificação

1. `pwsh -File .\claude-usebar.ps1 -Once` após a limpeza.
2. `irm <raw>/install.ps1 | iex` em PS 5.1 na máquina do autor — instala, para instância antiga, recria atalho, widget volta à bandeja.
3. Reexecução do comando valida o fluxo de atualização.
4. URL raw responde sem autenticação; `.vbs` não versionado.
