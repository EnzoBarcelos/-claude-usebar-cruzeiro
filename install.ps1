# install.ps1 - instalador de 1 comando do claude-usebar.
#
#   irm https://raw.githubusercontent.com/<usuario>/claude-usebar/main/install.ps1 | iex
#
# Roda no Windows PowerShell 5.1 (nativo do Windows) ou no pwsh 7+. Faz tudo:
#   1. Garante PowerShell 7.4+ (instala via winget se faltar);
#   2. Baixa claude-usebar.ps1 para %LOCALAPPDATA%\claude-usebar\;
#   3. Encerra instancia em execucao (caso de atualizacao);
#   4. Configura o autostart (atalho em shell:startup) e inicia o widget.
#
# Reexecutar o mesmo comando atualiza para a versao mais recente.

$ErrorActionPreference = 'Stop'

$RepoRawBase = 'https://raw.githubusercontent.com/<usuario>/claude-usebar/main'
$MinPwsh     = [version]'7.4'
$AppDir      = Join-Path $env:LOCALAPPDATA 'claude-usebar'
$ScriptDest  = Join-Path $AppDir 'claude-usebar.ps1'

function Write-Step([string]$msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Write-Note([string]$msg)  { Write-Host "    $msg" -ForegroundColor Yellow }

# TLS 1.2 - o PowerShell 5.1 nao o habilita por padrao e o GitHub exige.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- 1. PowerShell 7.4+ -------------------------------------------------------------
function Get-PwshPath {
    $candidates = @()
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    foreach ($p in $candidates) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $v = [version](& $p -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')
            if ($v -ge $MinPwsh) { return $p }
        } catch { }
    }
    return $null
}

Write-Step 'Verificando PowerShell 7.4+...'
$pwsh = Get-PwshPath
if (-not $pwsh) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Host ''
        Write-Host 'PowerShell 7 nao encontrado e o winget nao esta disponivel para instala-lo.' -ForegroundColor Red
        Write-Host 'Instale o "Instalador de Aplicativo" pela Microsoft Store e rode o comando de novo,'
        Write-Host 'ou instale o PowerShell 7 manualmente: https://aka.ms/powershell-release?tag=stable'
        return
    }
    Write-Note 'PowerShell 7 nao encontrado - instalando via winget (pode levar 1-2 min)...'
    winget install --id Microsoft.PowerShell --exact --silent --accept-source-agreements --accept-package-agreements
    $pwsh = Get-PwshPath
    if (-not $pwsh) {
        Write-Host 'A instalacao do PowerShell 7 nao foi concluida. Rode o comando de novo apos instala-lo.' -ForegroundColor Red
        return
    }
}
Write-Ok "PowerShell 7 OK: $pwsh"

# --- 2. Download do widget ----------------------------------------------------------
Write-Step "Baixando o claude-usebar para $AppDir..."
if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
$tmp = Join-Path $AppDir 'claude-usebar.ps1.download'
Invoke-WebRequest -Uri "$RepoRawBase/claude-usebar.ps1" -OutFile $tmp -UseBasicParsing
Move-Item -LiteralPath $tmp -Destination $ScriptDest -Force
Write-Ok 'Download concluido.'

# --- 3. Encerrar instancia em execucao (atualizacao) --------------------------------
$running = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'claude-usebar\.ps1' }
if ($running) {
    Write-Step 'Encerrando a versao em execucao...'
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
}

# --- 4. Autostart + iniciar agora ----------------------------------------------------
Write-Step 'Configurando inicio automatico com o Windows...'
& $pwsh -NoProfile -File $ScriptDest -Install | Out-Null

$vbs = Join-Path $AppDir 'claude-usebar-launcher.vbs'
Write-Step 'Iniciando o widget...'
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"{0}"' -f $vbs)

# --- 5. Resumo -----------------------------------------------------------------------
Write-Host ''
Write-Host 'claude-usebar instalado!' -ForegroundColor Green
Write-Host "  - Script:    $ScriptDest"
Write-Host "  - Config:    $AppDir\config.json"
Write-Host '  - Autostart: pasta Inicializar (shell:startup)'
Write-Host '  - O icone com o % de uso aparece na bandeja, perto do relogio (talvez na setinha ^).'

$creds = Join-Path $env:USERPROFILE '.claude\.credentials.json'
if (-not (Test-Path -LiteralPath $creds)) {
    Write-Host ''
    Write-Note 'Atencao: voce ainda nao esta logado no Claude Code.'
    Write-Note 'O icone vai mostrar "?" ate voce rodar `claude` e fazer login (/login).'
}
Write-Host ''
Write-Host 'Para atualizar no futuro, cole o mesmo comando de instalacao novamente.'
