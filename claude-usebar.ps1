#requires -Version 7.4
<#
.SYNOPSIS
  claude-usebar — widget de bandeja do Windows que mostra o consumo de uso do Claude Code.
  Port do claudebar (Waybar/Linux, https://github.com/mryll/claudebar) para a notification area.

.DESCRIPTION
  Lê as credenciais OAuth do Claude CLI (%USERPROFILE%\.claude\.credentials.json), renova o
  access token quando necessário, consulta o endpoint de uso da Anthropic e desenha o % de uso
  num ícone da bandeja, com popup detalhado (janelas 5h / 7d / Sonnet 7d), contagem regressiva
  até o reset e indicador de ritmo (pacing).

.PARAMETER Install
  Gera o launcher .vbs e cria um atalho na pasta Inicializar para subir no logon (sem console).

.PARAMETER Uninstall
  Remove o atalho de autostart (mantém config e cache).

.PARAMETER Foreground
  Roda mantendo o console visível (para depuração).

.PARAMETER Once
  Faz uma única consulta e imprime o resultado em JSON no stdout (diagnóstico, sem UI).
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Foreground,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

#region Paths/Const ----------------------------------------------------------------
$script:CredPath     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:AppDir       = Join-Path $env:LOCALAPPDATA 'claude-usebar'
$script:ConfigPath   = Join-Path $script:AppDir 'config.json'
$script:CachePath    = Join-Path $script:AppDir 'cache.json'

$script:ClientId     = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
$script:UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'
$script:TokenUrl     = 'https://platform.claude.com/v1/oauth/token'
$script:BetaHeader   = 'oauth-2025-04-20'
$script:UserAgent    = 'claude-cli/1.0'

$script:Win5h        = 18000     # 5 horas em segundos
$script:Win7d        = 604800    # 7 dias em segundos
$script:RefreshBufMs = 300000    # renova o token se faltar < 5 min para expirar
$script:FetchFloorSec= 300       # piso de fetch ao servidor (endpoint com rate limit agressivo)
$script:HttpTimeout  = 15

# Estado compartilhado da UI
$script:State        = 'Init'
$script:Usage        = $null
$script:Sub          = $null
$script:Tier         = $null
$script:Note         = $null
$script:PopupHiddenAt= 0
$script:ModelName    = $null     # nome amigável do modelo em uso (ex.: "Fable 5")
$script:ModelCheckedAt = 0       # última checagem do modelo (ms epoch)
$script:NextTickAt   = 0         # próxima atualização agendada do uso (ms epoch)
$script:BgBitmap     = $null     # bitmap de fundo cacheado
$script:BgStream     = $null     # stream do bitmap (GDI+ exige que viva junto)
$script:BgPath       = $null
#endregion

#region Helpers --------------------------------------------------------------------
function Get-NowMs  { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Get-NowSec { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Format-Duration {
    param([long]$Seconds)
    if ($Seconds -le 0) { return 'agora' }
    $d = [math]::Floor($Seconds / 86400)
    $h = [math]::Floor(($Seconds % 86400) / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    if ($d -ge 1) { return "${d}d ${h}h" }
    if ($h -ge 1) { return "${h}h ${m}m" }
    return "${m}m"
}
#endregion

#region Config ---------------------------------------------------------------------
function Get-DefaultConfig {
    @{
        intervalSec        = 300
        pacingTolerancePct = 5
        mode               = '5h'       # 5h | 7d | max  (qual % aparece no ícone) — padrão: sessão
        showRemaining      = $true
        iconStyle          = 'pct'
        colorTheme         = 'vermelho' # vermelho | roxo | azul | verde | laranja
        notifications      = $false     # balões de aviso (desligados por padrão)
        soundEnabled       = $true       # toca cruzeiro-radio-globo.mp3 ao clicar "Atualizar agora"
        pinned             = $false      # popup fixado (não some ao perder o foco)
        popupWidth         = $null       # $null = tamanho automático
        popupHeight        = $null
        popupX             = $null       # $null = ancora no canto inferior direito
        popupY             = $null
        backgroundImage    = $null       # caminho de imagem de fundo do popup ($null = fundo sólido)
        backgroundDarken   = 0.75        # véu escuro sobre a imagem (0 = sem véu, 0.95 = quase preto)
        colors             = @{ low = '#7f1010'; mid = '#b71c1c'; high = '#e53935'; critical = '#ff1744' }   # resolvido a partir de colorTheme
    }
}

# Paletas dos 5 temas (gradiente escuro → vivo: low/mid/high/critical).
function Get-ColorThemes {
    @{
        vermelho = @{ low = '#7f1010'; mid = '#b71c1c'; high = '#e53935'; critical = '#ff1744' }
        roxo     = @{ low = '#4a148c'; mid = '#6a1b9a'; high = '#8e24aa'; critical = '#aa00ff' }
        azul     = @{ low = '#0d47a1'; mid = '#1565c0'; high = '#1e88e5'; critical = '#2979ff' }
        verde    = @{ low = '#1b5e20'; mid = '#2e7d32'; high = '#43a047'; critical = '#00e676' }
        laranja  = @{ low = '#e65100'; mid = '#ef6c00'; high = '#fb8c00'; critical = '#ff9100' }
    }
}

# Copia a paleta do tema selecionado para $Cfg.colors (fallback: vermelho).
function Resolve-ThemeColors {
    param($Cfg)
    $themes = Get-ColorThemes
    $name = [string]$Cfg.colorTheme
    if (-not $themes.ContainsKey($name)) { $name = 'vermelho'; $Cfg.colorTheme = 'vermelho' }
    $Cfg.colors = @{}
    foreach ($k in $themes[$name].Keys) { $Cfg.colors[$k] = $themes[$name][$k] }
}

function Load-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $loaded = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            foreach ($k in $loaded.Keys) {
                if ($k -eq 'colors' -and $loaded[$k] -is [hashtable]) {
                    foreach ($ck in $loaded[$k].Keys) { $cfg.colors[$ck] = $loaded[$k][$ck] }
                } else {
                    $cfg[$k] = $loaded[$k]
                }
            }
        } catch { } # config malformado: cai para os defaults
    }
    $cfg.intervalSec        = [int][Math]::Max(300, [int]$cfg.intervalSec)
    $cfg.pacingTolerancePct = [int]$cfg.pacingTolerancePct
    try { $cfg.backgroundDarken = [Math]::Min(0.95, [Math]::Max(0.0, [double]$cfg.backgroundDarken)) }
    catch { $cfg.backgroundDarken = 0.75 }
    if ($cfg.mode -notin @('5h', '7d', 'max')) { $cfg.mode = 'max' }
    Resolve-ThemeColors $cfg
    $script:Config = $cfg
}

function Save-Config {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        $json = $script:Config | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($script:ConfigPath, $json, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}
#endregion

#region Credentials ----------------------------------------------------------------
function Read-Credentials {
    if (-not (Test-Path -LiteralPath $script:CredPath)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $script:CredPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch { return $null }
    if ($null -eq $obj -or -not $obj.ContainsKey('claudeAiOauth')) { return $null }
    return $obj
}

# Regrava o .credentials.json de forma atômica, preservando todos os outros campos.
# Aborta se o refreshToken em disco já mudou (o próprio Claude CLI renovou antes) — anti-corrupção.
function Save-Credentials {
    param(
        [string]$ExpectedOldRefresh,
        [string]$AccessToken,
        [string]$RefreshToken,
        [long]$ExpiresAtMs
    )
    $fresh = Read-Credentials
    if ($null -eq $fresh) { return $false }
    $oauth = $fresh['claudeAiOauth']
    if ([string]$oauth['refreshToken'] -ne $ExpectedOldRefresh) {
        return $false   # CLI já rotacionou o token — não sobrescrever
    }
    $oauth['accessToken']  = $AccessToken
    $oauth['refreshToken'] = $RefreshToken
    $oauth['expiresAt']    = $ExpiresAtMs

    $json = $fresh | ConvertTo-Json -Depth 12
    $tmp  = "$($script:CredPath).tmp"
    $bak  = "$($script:CredPath).bak"
    $enc  = [System.Text.UTF8Encoding]::new($false)   # UTF-8 sem BOM
    for ($i = 0; $i -lt 3; $i++) {
        try {
            [System.IO.File]::WriteAllText($tmp, $json, $enc)
            if (Test-Path -LiteralPath $script:CredPath) {
                [System.IO.File]::Replace($tmp, $script:CredPath, $bak)
            } else {
                [System.IO.File]::Move($tmp, $script:CredPath)
            }
            return $true
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 150   # corrida com o daemon do Claude Code: tenta de novo
        } catch {
            break
        }
    }
    return $false
}
#endregion

#region API ------------------------------------------------------------------------
function Invoke-TokenRefresh {
    param([string]$RefreshToken)
    $body = @{ grant_type = 'refresh_token'; client_id = $script:ClientId; refresh_token = $RefreshToken } | ConvertTo-Json -Compress
    try {
        $resp = Invoke-RestMethod -Uri $script:TokenUrl -Method Post -ContentType 'application/json' `
            -Headers @{ 'anthropic-beta' = $script:BetaHeader } -UserAgent $script:UserAgent `
            -Body $body -TimeoutSec $script:HttpTimeout -SkipHttpErrorCheck -StatusCodeVariable sc
    } catch {
        return @{ ok = $false; status = 0; error = $_.Exception.Message }
    }
    if ($sc -ne 200) { return @{ ok = $false; status = $sc } }
    return @{ ok = $true; status = 200; data = $resp }
}

# Retorna @{ state = 'OK'|'NoCreds'|'RefreshFailed'; token; sub; tier; status }
function Get-AccessToken {
    param([switch]$Force)
    $creds = Read-Credentials
    if ($null -eq $creds) { return @{ state = 'NoCreds' } }
    $oauth   = $creds['claudeAiOauth']
    $access  = [string]$oauth['accessToken']
    $refresh = [string]$oauth['refreshToken']
    $expMs   = [long]($oauth['expiresAt'] ?? 0)
    $nowMs   = Get-NowMs

    $needs = $Force -or (($expMs - $nowMs) -le $script:RefreshBufMs) -or [string]::IsNullOrEmpty($access)
    if (-not $needs) {
        return @{ state = 'OK'; token = $access; sub = $oauth['subscriptionType']; tier = $oauth['rateLimitTier'] }
    }
    if ([string]::IsNullOrEmpty($refresh)) { return @{ state = 'RefreshFailed'; token = $access } }

    $r = Invoke-TokenRefresh -RefreshToken $refresh
    if (-not $r.ok) { return @{ state = 'RefreshFailed'; status = $r.status; token = $access } }

    $newAccess  = [string]$r.data.access_token
    $newRefresh = if ($r.data.refresh_token) { [string]$r.data.refresh_token } else { $refresh }
    $expiresIn  = if ($r.data.expires_in) { [int]$r.data.expires_in } else { 0 }
    $newExpMs   = (Get-NowMs) + ($expiresIn * 1000)
    Save-Credentials -ExpectedOldRefresh $refresh -AccessToken $newAccess -RefreshToken $newRefresh -ExpiresAtMs $newExpMs | Out-Null
    return @{ state = 'OK'; token = $newAccess; sub = $oauth['subscriptionType']; tier = $oauth['rateLimitTier'] }
}

# Retorna @{ ok; status; data }
function Invoke-UsageRequest {
    param([string]$Token)
    try {
        $resp = Invoke-RestMethod -Uri $script:UsageUrl -TimeoutSec $script:HttpTimeout `
            -Headers @{ Authorization = "Bearer $Token"; 'anthropic-beta' = $script:BetaHeader } `
            -SkipHttpErrorCheck -StatusCodeVariable sc
    } catch {
        return @{ ok = $false; status = 0; error = $_.Exception.Message }
    }
    return @{ ok = ($sc -eq 200); status = $sc; data = $resp }
}
#endregion

#region Cache ----------------------------------------------------------------------
function Read-Cache {
    if (-not (Test-Path -LiteralPath $script:CachePath)) { return $null }
    try {
        return Get-Content -LiteralPath $script:CachePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch { return $null }
}

function Write-Cache {
    param($Usage, [long]$FetchedAt)
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
        $obj  = [ordered]@{ fetchedAt = $FetchedAt; usage = $Usage }
        $json = $obj | ConvertTo-Json -Depth 12
        $tmp  = "$($script:CachePath).tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $script:CachePath) { [System.IO.File]::Replace($tmp, $script:CachePath, $null) }
        else { [System.IO.File]::Move($tmp, $script:CachePath) }
    } catch { }
}
#endregion

#region Pacing ---------------------------------------------------------------------
function Get-Severity {
    param([int]$Pct)
    if     ($Pct -ge 90) { 'critical' }
    elseif ($Pct -ge 75) { 'high' }
    elseif ($Pct -ge 50) { 'mid' }
    else                 { 'low' }
}

# Recebe um nó da resposta (.five_hour etc.) e devolve pct, elapsed, seta de pacing, reset e severidade.
function Compute-Window {
    param($Node, [int]$WindowSec, [int]$Tol)
    if ($null -eq $Node) { return $null }
    $pct = [int][math]::Round([double]$Node.utilization)   # utilization já vem em 0-100
    if ($pct -lt 0) { $pct = 0 } elseif ($pct -gt 100) { $pct = 100 }

    $resetsAt  = [string]$Node.resets_at
    $arrow     = '→'
    $elapsed   = $null
    $resetText = ''
    if ($resetsAt) {
        try {
            $resetSec  = ([datetimeoffset]$resetsAt).ToUnixTimeSeconds()
            $remaining = [long]($resetSec - (Get-NowSec))
            if ($remaining -lt 0) { $remaining = 0 }
            $resetText = Format-Duration $remaining
            $elapsed   = [int]((($WindowSec - $remaining) * 100) / $WindowSec)
            if ($elapsed -lt 0) { $elapsed = 0 } elseif ($elapsed -gt 100) { $elapsed = 100 }
            $delta = $pct - $elapsed
            if     ($delta -gt $Tol)  { $arrow = '↑' }
            elseif ($delta -lt -$Tol) { $arrow = '↓' }
            else                      { $arrow = '→' }
        } catch { }
    }
    [pscustomobject]@{
        Pct = $pct; Elapsed = $elapsed; Arrow = $arrow; ResetText = $resetText; Severity = (Get-Severity $pct)
    }
}
#endregion

#region State ----------------------------------------------------------------------
function Get-StateMessage {
    param([string]$S)
    switch ($S) {
        'NoCreds'       { 'Não logado — rode "claude login"' }
        'RefreshFailed' { 'Falha ao renovar o token de acesso' }
        'HttpErr'       { 'Erro ao consultar o uso (HTTP)' }
        'Rate429'       { 'Limite de requisições — exibindo cache' }
        'Offline'       { 'Sem conexão — exibindo cache' }
        default         { $S }
    }
}

function Set-AppState {
    param([string]$S)
    $prev = $script:State
    $script:State = $S
    $hard = @('NoCreds', 'RefreshFailed', 'HttpErr')
    if ($script:NotifyIcon -and $script:Config -and $script:Config.notifications -and ($S -in $hard) -and ($prev -ne $S)) {
        try {
            $script:NotifyIcon.ShowBalloonTip(5000, 'claude-usebar', (Get-StateMessage $S), [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch { }
    }
}
#endregion

#region Modelo em uso --------------------------------------------------------------
# Converte um ID de modelo (ex.: "claude-fable-5[1m]", "claude-opus-4-8",
# "claude-sonnet-4-5-20250929") em nome amigável ("Fable 5", "Opus 4.8", "Sonnet 4.5").
function ConvertTo-ModelName {
    param([string]$Id)
    $id = $Id.ToLowerInvariant() -replace '\[[^\]]*\]$', ''   # sufixo de contexto, ex. [1m]
    $id = $id -replace '-\d{8}$', ''                          # sufixo de data, ex. -20250929
    $ti = (Get-Culture).TextInfo
    foreach ($fam in 'fable', 'opus', 'sonnet', 'haiku') {
        if ($id -match "$fam-(\d+)-(\d+)$") { return ('{0} {1}.{2}' -f $ti.ToTitleCase($fam), $Matches[1], $Matches[2]) }
        if ($id -match "$fam-(\d+)$")       { return ('{0} {1}'     -f $ti.ToTitleCase($fam), $Matches[1]) }
    }
    return $ti.ToTitleCase((($id -replace '^claude-', '') -replace '-', ' '))
}

# Modelo da última resposta do assistant no transcript .jsonl mais recente do Claude Code.
function Get-CurrentModelName {
    try {
        $projDir = Join-Path $env:USERPROFILE '.claude\projects'
        if (-not (Test-Path -LiteralPath $projDir)) { return $null }
        $f = Get-ChildItem -LiteralPath $projDir -Filter *.jsonl -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $f) { return $null }
        $id = $null
        foreach ($l in (Get-Content -LiteralPath $f.FullName -Tail 80 -ErrorAction Stop)) {
            if ($l -match '"model"\s*:\s*"(claude-[^"]+)"') { $id = $Matches[1] }   # exige prefixo claude- (descarta "<synthetic>")
        }
        if ($id) { return ConvertTo-ModelName $id }
    } catch { }
    return $null
}

# Atualiza $script:ModelName no máximo a cada 15 s (chamado no ciclo de uso e ao abrir o popup).
function Update-CurrentModel {
    $now = Get-NowMs
    if (($now - $script:ModelCheckedAt) -lt 15000) { return }
    $script:ModelCheckedAt = $now
    $m = Get-CurrentModelName
    if ($m) { $script:ModelName = $m }
}
#endregion

#region Diagnostic (-Once) ---------------------------------------------------------
function Invoke-Once {
    Load-Config
    $tok = Get-AccessToken
    if ($tok.state -ne 'OK') {
        [ordered]@{ state = $tok.state; status = $tok.status } | ConvertTo-Json
        return
    }
    $u = Invoke-UsageRequest -Token $tok.token
    if (-not $u.ok) {
        [ordered]@{ state = 'HttpErr'; status = $u.status } | ConvertTo-Json
        return
    }
    $tol = [int]$script:Config.pacingTolerancePct
    [ordered]@{
        state            = 'OK'
        subscription     = $tok.sub
        tier             = $tok.tier
        currentModel     = (Get-CurrentModelName)
        five_hour        = (Compute-Window $u.data.five_hour        $script:Win5h $tol)
        seven_day        = (Compute-Window $u.data.seven_day        $script:Win7d $tol)
        seven_day_sonnet = (Compute-Window $u.data.seven_day_sonnet $script:Win7d $tol)
        extra_usage      = $u.data.extra_usage
        raw              = $u.data
    } | ConvertTo-Json -Depth 8
}
#endregion

#region Install --------------------------------------------------------------------
function Install-Autostart {
    $scriptPath = $PSCommandPath
    $projDir    = Split-Path -Parent $scriptPath
    $pwshPath   = Join-Path $PSHOME 'pwsh.exe'
    $vbsPath    = Join-Path $projDir 'claude-usebar-launcher.vbs'

    # O .vbs roda o pwsh oculto desde a criação (modo 0) — sem flash de console no logon.
    $cmd     = '"{0}" -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $pwshPath, $scriptPath
    $vbsCmd  = $cmd -replace '"', '""'
    $vbs = @"
' Gerado por claude-usebar.ps1 -Install. Inicia o widget sem janela de console.
Set s = CreateObject("WScript.Shell")
s.Run "$vbsCmd", 0, False
"@
    [System.IO.File]::WriteAllText($vbsPath, $vbs, [System.Text.UTF8Encoding]::new($false))

    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'claude-usebar.lnk'
    $sh = New-Object -ComObject WScript.Shell
    try {
        $sc = $sh.CreateShortcut($lnkPath)
        $sc.TargetPath       = 'wscript.exe'
        $sc.Arguments        = '"{0}"' -f $vbsPath
        $sc.WorkingDirectory = $projDir
        $sc.WindowStyle      = 7
        $sc.Description      = 'claude-usebar — uso do Claude na bandeja'
        $sc.Save()
    } finally {
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($sh) | Out-Null
    }
    Write-Host "Instalado. Autostart criado em:`n  $lnkPath`nLauncher:`n  $vbsPath"
    Write-Host "Para iniciar agora sem reiniciar a sessão, rode:`n  wscript `"$vbsPath`""
}

function Uninstall-Autostart {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'claude-usebar.lnk'
    if (Test-Path -LiteralPath $lnkPath) {
        Remove-Item -LiteralPath $lnkPath -Force
        Write-Host "Autostart removido: $lnkPath"
    } else {
        Write-Host "Nenhum atalho de autostart encontrado em: $lnkPath"
    }
    Write-Host "Config e cache mantidos em: $($script:AppDir)"
}
#endregion

# ==================================================================================
# Daqui para baixo: somente o modo UI (bandeja). Modos -Install/-Uninstall/-Once já
# retornam antes de carregar WinForms.
# ==================================================================================

#region UI-Bootstrap ---------------------------------------------------------------
function Initialize-WinForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # Referencia todos os assemblies já carregados: Form deriva de Component
    # (System.ComponentModel.Primitives) e outros transitivos não entram no default do Add-Type.
    $refs = [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { -not $_.IsDynamic -and $_.Location } |
        ForEach-Object { $_.Location }
    $cs = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace ClaudeUsebar {
    public static class Native {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool DestroyIcon(IntPtr handle);
        [DllImport("winmm.dll", CharSet = CharSet.Auto)]
        public static extern int mciSendString(string command, System.Text.StringBuilder ret, int retLen, IntPtr hwnd);
        public static void HideConsole() {
            IntPtr h = GetConsoleWindow();
            if (h != IntPtr.Zero) ShowWindow(h, 0); // SW_HIDE
        }
    }
    public class PopupForm : Form {
        public bool Pinned = false;     // fixado: não some ao perder o foco
        public bool Resizing = false;   // em arraste de mover/redimensionar
        const int WM_NCHITTEST = 0x0084;
        const int HTCLIENT = 1, HTCAPTION = 2;
        const int HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13,
                  HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
        const int GRIP = 6;       // espessura da borda para pegar e redimensionar
        const int CAPTION = 28;   // faixa superior arrastável para mover
        public PopupForm() {
            this.DoubleBuffered = true;
            this.FormBorderStyle = FormBorderStyle.None;
            this.ShowInTaskbar = false;
            this.StartPosition = FormStartPosition.Manual;
            this.TopMost = true;
            this.MinimumSize = new System.Drawing.Size(220, 90);
        }
        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x80; // WS_EX_TOOLWINDOW — fora do Alt-Tab
                return cp;
            }
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_NCHITTEST) {
                int lp = m.LParam.ToInt32();
                short sx = (short)(lp & 0xFFFF);   // coords de tela (signed)
                short sy = (short)(lp >> 16);
                System.Drawing.Point p = this.PointToClient(new System.Drawing.Point(sx, sy));
                int x = p.X, y = p.Y, w = this.ClientSize.Width, h = this.ClientSize.Height;
                bool left = x <= GRIP, right = x >= w - GRIP, top = y <= GRIP, bottom = y >= h - GRIP;
                if (top && left)     { m.Result = (IntPtr)HTTOPLEFT;     return; }
                if (top && right)    { m.Result = (IntPtr)HTTOPRIGHT;    return; }
                if (bottom && left)  { m.Result = (IntPtr)HTBOTTOMLEFT;  return; }
                if (bottom && right) { m.Result = (IntPtr)HTBOTTOMRIGHT; return; }
                if (left)            { m.Result = (IntPtr)HTLEFT;        return; }
                if (right)           { m.Result = (IntPtr)HTRIGHT;       return; }
                if (top)             { m.Result = (IntPtr)HTTOP;         return; }
                if (bottom)          { m.Result = (IntPtr)HTBOTTOM;      return; }
                if (y <= CAPTION)    { m.Result = (IntPtr)HTCAPTION;     return; } // arrastar para mover
                m.Result = (IntPtr)HTCLIENT; return;
            }
            base.WndProc(ref m);
        }
    }
}
'@
    if (-not ('ClaudeUsebar.Native' -as [type])) {
        Add-Type -TypeDefinition $cs -ReferencedAssemblies $refs -ErrorAction Stop
    }
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
}
#endregion

#region UI-Fonts -------------------------------------------------------------------
# Resolve as famílias de fonte uma única vez, com fallback para Windows 10.
# - Texto do popup/ícone: Segoe UI Variable (Win11) -> Segoe UI.
# - Glifos (pin): Segoe Fluent Icons (Win11, traço mais leve) -> Segoe MDL2 Assets.
$script:UiFontFamily   = 'Segoe UI'
$script:IconGlyphFamily = 'Segoe MDL2 Assets'
$script:PopupCornerRadius = 14   # raio dos cantos arredondados (px)

function Test-FontFamily {
    param([string]$Name)
    try { $ff = [System.Drawing.FontFamily]::new($Name); $ff.Dispose(); return $true }
    catch { return $false }
}

function Resolve-Fonts {
    foreach ($fam in 'Segoe UI Variable Text', 'Segoe UI Variable', 'Segoe UI') {
        if (Test-FontFamily $fam) { $script:UiFontFamily = $fam; break }
    }
    foreach ($fam in 'Segoe Fluent Icons', 'Segoe MDL2 Assets') {
        if (Test-FontFamily $fam) { $script:IconGlyphFamily = $fam; break }
    }
}

function New-UiFont {
    param(
        [single]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.GraphicsUnit]$Unit = [System.Drawing.GraphicsUnit]::Point
    )
    [System.Drawing.Font]::new($script:UiFontFamily, $Size, $Style, $Unit)
}

# Clareia uma cor em direção ao branco (0..1). Usado no ícone da bandeja: as cores de
# severidade são escuras (feitas para fundo); como número solto precisam de mais luz.
function Lighten-Color {
    param([System.Drawing.Color]$Color, [double]$Amount = 0.35)
    $r = [int][Math]::Round($Color.R + (255 - $Color.R) * $Amount)
    $g = [int][Math]::Round($Color.G + (255 - $Color.G) * $Amount)
    $b = [int][Math]::Round($Color.B + (255 - $Color.B) * $Amount)
    [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}
#endregion

#region UI-Sound -------------------------------------------------------------------
# Som ao clicar "Atualizar agora". Usa MCI (winmm) que toca mp3 nativamente e de forma
# assíncrona (não trava a UI). O arquivo fica ao lado do script (embutido no projeto).
$script:SoundPath = $null
if ($PSCommandPath) {
    $script:SoundPath = Join-Path (Split-Path -Parent $PSCommandPath) 'cruzeiro-radio-globo.mp3'
}

function Play-RefreshSound {
    if (-not $script:Config.soundEnabled) { return }
    if (-not $script:SoundPath -or -not (Test-Path -LiteralPath $script:SoundPath)) { return }
    try {
        $sb = [System.Text.StringBuilder]::new(256)
        # fecha uma reprodução anterior (se houver) e reabre do início a cada clique
        [ClaudeUsebar.Native]::mciSendString('close refreshsnd', $null, 0, [IntPtr]::Zero) | Out-Null
        [ClaudeUsebar.Native]::mciSendString(('open "{0}" alias refreshsnd' -f $script:SoundPath), $null, 0, [IntPtr]::Zero) | Out-Null
        [ClaudeUsebar.Native]::mciSendString('play refreshsnd from 0', $sb, 0, [IntPtr]::Zero) | Out-Null
    } catch { }
}
#endregion

#region UI-Icon --------------------------------------------------------------------
# Ícone minimalista: só o número (sem fundo), na cor da severidade já clareada para
# legibilidade, com um halo escuro fino que mantém contraste em barras claras e escuras.
# $Color = cor do número (severidade/estado).
function Set-TrayIcon {
    param([string]$Text, [System.Drawing.Color]$Color)
    $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize
    $w  = [Math]::Max($sz.Width, 16)
    $h  = [Math]::Max($sz.Height, 16)
    $bmp = [System.Drawing.Bitmap]::new($w, $h)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)

        # número como caminho, para poder contornar (halo) e preencher
        $fontPx = if ($Text.Length -ge 3) { [single][Math]::Floor($h * 0.66) } else { [single][Math]::Floor($h * 0.86) }
        $fmt    = [System.Drawing.StringFormat]::new()
        $fmt.Alignment     = [System.Drawing.StringAlignment]::Center
        $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $ff   = [System.Drawing.FontFamily]::new($script:UiFontFamily)
        $rect = [System.Drawing.RectangleF]::new(0, 0, $w, $h)
        $gp   = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $gp.AddString($Text, $ff, [int][System.Drawing.FontStyle]::Bold, $fontPx, $rect, $fmt)

        # halo escuro (contorno) -> contraste em fundos claros
        $haloPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(170, 0, 0, 0), [single][Math]::Max(2.0, $w * 0.14))
        $haloPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawPath($haloPen, $gp)
        $haloPen.Dispose()

        # preenchimento na cor da severidade (já clareada pelo chamador)
        $fgBrush = [System.Drawing.SolidBrush]::new($Color)
        $g.FillPath($fgBrush, $gp)
        $fgBrush.Dispose()

        $gp.Dispose(); $ff.Dispose(); $fmt.Dispose()
        $g.Dispose()
        $hicon = $bmp.GetHicon()
        try {
            $tmp   = [System.Drawing.Icon]::FromHandle($hicon)
            $clone = [System.Drawing.Icon]$tmp.Clone()   # NotifyIcon fica com cópia gerenciada
            $old   = $script:NotifyIcon.Icon
            $script:NotifyIcon.Icon = $clone
            $tmp.Dispose()
            if ($old) { $old.Dispose() }
        } finally {
            [ClaudeUsebar.Native]::DestroyIcon($hicon) | Out-Null   # crítico: evita vazar GDI handle a cada refresh
        }
    } finally {
        $bmp.Dispose()
    }
}
#endregion

#region UI-Display -----------------------------------------------------------------
# Constrói tudo o que a UI precisa a partir de $script:State + $script:Usage.
function Build-Display {
    $st = $script:State
    $script:DisplayTitle = 'Claude'
    $script:DisplayRows  = @()
    $script:DisplayExtra = $null
    $script:DisplayNote  = $null

    if ($st -eq 'NoCreds') {
        $script:IconText = '?'; $script:IconBg = '#757575'; $script:IconFg = '#ffffff'
        $script:TooltipText = 'claude-usebar: não logado — rode "claude login"'
        $script:DisplayTitle = 'Não logado'
        return
    }

    $u = $script:Usage
    if ($null -eq $u) {
        $map = @{
            RefreshFailed = @('!', '#c62828'); HttpErr = @('x', '#c62828')
            Offline       = @('-', '#757575'); Rate429 = @('·', '#757575')
        }
        $info = $map[$st]; if (-not $info) { $info = @('?', '#757575') }
        $script:IconText = $info[0]; $script:IconBg = $info[1]; $script:IconFg = '#ffffff'
        $msg = Get-StateMessage $st
        $script:TooltipText  = "claude-usebar: $msg"
        $script:DisplayTitle = $msg
        return
    }

    $tol = [int]$script:Config.pacingTolerancePct
    $w5  = Compute-Window $u.five_hour        $script:Win5h $tol
    $w7  = Compute-Window $u.seven_day        $script:Win7d $tol
    $ws  = Compute-Window $u.seven_day_sonnet $script:Win7d $tol

    $rows = @()
    if ($w5) { $rows += [pscustomobject]@{ Name = 'Sessão (5h)';  W = $w5 } }
    if ($w7) { $rows += [pscustomobject]@{ Name = 'Semana (7d)';  W = $w7 } }
    if ($ws) { $rows += [pscustomobject]@{ Name = 'Sonnet (7d)';  W = $ws } }
    $script:DisplayRows = $rows

    if ($u.extra_usage -and $u.extra_usage.is_enabled) {
        $used = [double]$u.extra_usage.used_credits / 100.0
        $lim  = [double]$u.extra_usage.monthly_limit / 100.0
        $script:DisplayExtra = ('Uso extra: ${0:N2} / ${1:N2}' -f $used, $lim)
    }

    $p5 = if ($w5) { $w5.Pct } else { 0 }
    $p7 = if ($w7) { $w7.Pct } else { 0 }
    $iconPct = switch ([string]$script:Config.mode) {
        '5h'    { $p5 }
        '7d'    { $p7 }
        default { [Math]::Max($p5, $p7) }
    }
    $sev = Get-Severity $iconPct
    $script:IconText = if ($iconPct -ge 100) { '99+' } else { "$iconPct" }
    if ($st -eq 'OK') {
        $script:IconBg = [string]$script:Config.colors[$sev]
        $script:IconFg = '#ffffff'
    } else {
        $script:IconBg = '#555555'   # cache/erro brando: esmaecido
        $script:IconFg = '#dddddd'
    }

    $sub = if ($script:Sub) { (Get-Culture).TextInfo.ToTitleCase([string]$script:Sub) } else { '' }
    $title = if ($sub) { "Claude · $sub" } else { 'Claude' }
    if ($script:ModelName) { $title += " · $($script:ModelName)" }
    $script:DisplayTitle = $title

    switch ($st) {
        'Rate429'       { $script:DisplayNote = 'Limite de requisições — exibindo cache' }
        'Offline'       { $script:DisplayNote = 'Sem conexão — exibindo cache' }
        'RefreshFailed' { $script:DisplayNote = 'Falha ao renovar — exibindo cache' }
    }
    if ($script:Note) { $script:DisplayNote = $script:Note }

    $parts = @()
    if ($w5) { $parts += "5h $($w5.Pct)% $($w5.Arrow)" }
    if ($w7) { $parts += "7d $($w7.Pct)% $($w7.Arrow)" }
    $tip = $parts -join ' · '
    if ($w5 -and $w5.ResetText) { $tip += " · reset $($w5.ResetText)" }
    $script:TooltipText = $tip
}

function Update-MenuText {
    if ($script:MiMode) { $script:MiMode.Text = "Ícone: $($script:Config.mode)" }
}

function Render {
    Build-Display
    if ($script:NotifyIcon) {
        # $IconBg carregava a cor de severidade/estado; agora ela vira a cor do número,
        # clareada para legibilidade como número solto (sem fundo).
        $col = Lighten-Color ([System.Drawing.ColorTranslator]::FromHtml($script:IconBg)) 0.35
        Set-TrayIcon -Text $script:IconText -Color $col
        $t = [string]$script:TooltipText
        if ($t.Length -gt 127) { $t = $t.Substring(0, 127) }   # NotifyIcon.Text: limite 127
        $script:NotifyIcon.Text = $t
    }
    Update-MenuText
    if ($script:PopupForm -and $script:PopupForm.Visible) {
        Set-PopupLayout
        $script:PopupForm.Invalidate()
    }
}
#endregion

#region UI-Popup -------------------------------------------------------------------
# Altura do layout em escala 1 (largura base 330) — usada pelo tamanho automático e pela escala.
function Get-PopupBaseHeight {
    $rows = @($script:DisplayRows).Count
    $h = 12 + 28                  # padding topo + título
    $h += $rows * 46              # cada janela
    if ($script:DisplayExtra) { $h += 22 }
    if ($script:DisplayNote)  { $h += 20 }
    $h += 20                      # rodapé: countdown de atualização
    $h += 14                      # padding base
    return [int]$h
}

# Fator de escala do popup: 1.0 no tamanho automático; ao redimensionar, fontes, barras e
# espaçamentos escalam todos por ele (limitado pela menor das duas dimensões).
function Get-PopupScale {
    $kx = $script:PopupForm.ClientSize.Width  / 330.0
    $ky = $script:PopupForm.ClientSize.Height / [double](Get-PopupBaseHeight)
    return [Math]::Max(0.5, [Math]::Min(4.0, [Math]::Min($kx, $ky)))
}

function Set-PopupLayout {
    if ($null -ne $script:Config.popupWidth -and $null -ne $script:Config.popupHeight) {
        # tamanho manual (usuário redimensionou): respeita e não recalcula
        $script:PopupForm.Size = [System.Drawing.Size]::new([int]$script:Config.popupWidth, [int]$script:Config.popupHeight)
    } else {
        $script:PopupForm.Size = [System.Drawing.Size]::new(330, (Get-PopupBaseHeight))
    }
    Set-PinButtonLayout
}

# Alfinete sempre no canto superior direito, escalado com o popup. Chamado também no
# evento Resize do form, para acompanhar o redimensionamento ao vivo.
function Set-PinButtonLayout {
    if (-not $script:PinButton) { return }
    $k  = [Math]::Round((Get-PopupScale), 2)   # arredonda p/ não recriar fonte a cada pixel
    $bw = [int][Math]::Round(22 * $k)
    $script:PinButton.Size = [System.Drawing.Size]::new($bw, $bw)
    if ($script:PinScale -ne $k) {
        $old = $script:PinButton.Font
        # Segoe Fluent Icons (Win11, traço mais leve) com fallback para MDL2 no Win10.
        $script:PinButton.Font = [System.Drawing.Font]::new($script:IconGlyphFamily, [single](9.5 * $k))
        if ($old) { $old.Dispose() }
        $script:PinScale = $k
    }
    # margem maior que o raio do canto, para o alfinete não ser cortado pelo arredondamento
    $m = [int][Math]::Max([Math]::Round(6 * $k), [Math]::Ceiling($script:PopupCornerRadius * 0.8))
    $script:PinButton.Location = [System.Drawing.Point]::new([int]($script:PopupForm.ClientSize.Width - $bw - $m), $m)
}

# Aplica o recorte arredondado à janela (cantos médios). Recalculado a cada Resize.
function Set-PopupRegion {
    if (-not $script:PopupForm) { return }
    $w = $script:PopupForm.Width
    $h = $script:PopupForm.Height
    if ($w -le 0 -or $h -le 0) { return }
    $r = [single][Math]::Min($script:PopupCornerRadius, [Math]::Min($w, $h) / 2.0)
    $d = [single]($r * 2)
    $gp = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $gp.AddArc(0, 0, $d, $d, 180, 90)
    $gp.AddArc($w - $d, 0, $d, $d, 270, 90)
    $gp.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $gp.AddArc(0, $h - $d, $d, $d, 90, 90)
    $gp.CloseFigure()
    $old = $script:PopupForm.Region
    $script:PopupForm.Region = [System.Drawing.Region]::new($gp)
    $gp.Dispose()
    if ($old) { $old.Dispose() }
}

# Bitmap de fundo cacheado; carrega via MemoryStream para não manter lock no arquivo.
function Get-BackgroundBitmap {
    $path = [string]$script:Config.backgroundImage
    if (-not $path) { return $null }
    if ($script:BgBitmap -and $script:BgPath -eq $path) { return $script:BgBitmap }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        if ($script:BgBitmap) { $script:BgBitmap.Dispose(); $script:BgBitmap = $null }
        if ($script:BgStream) { $script:BgStream.Dispose(); $script:BgStream = $null }
        $script:BgStream = [System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes($path))
        $script:BgBitmap = [System.Drawing.Bitmap]::new($script:BgStream)   # GDI+: o stream vive junto do bitmap
        $script:BgPath   = $path
        return $script:BgBitmap
    } catch {
        $script:BgBitmap = $null
        return $null
    }
}

# Descarta o bitmap de fundo cacheado para forçar recarga (ex.: ao trocar a imagem,
# mesmo que o caminho de destino seja reaproveitado).
function Reset-BackgroundCache {
    if ($script:BgBitmap) { try { $script:BgBitmap.Dispose() } catch { }; $script:BgBitmap = $null }
    if ($script:BgStream) { try { $script:BgStream.Dispose() } catch { }; $script:BgStream = $null }
    $script:BgPath = $null
}

# Repinta o popup se estiver aberto (após mudar fundo/véu).
function Refresh-Popup {
    if ($script:PopupForm -and $script:PopupForm.Visible) { $script:PopupForm.Invalidate() }
}

# Abre um seletor de arquivo, copia a imagem escolhida para a pasta local e a adota como fundo.
function Set-BackgroundImage {
    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title  = 'Escolher imagem de fundo'
    $dlg.Filter = 'Imagens|*.jpg;*.jpeg;*.png;*.bmp;*.gif|Todos os arquivos|*.*'
    try {
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $src = $dlg.FileName
        $ext = [System.IO.Path]::GetExtension($src)
        if (-not $ext) { $ext = '.img' }
        $dst = Join-Path $script:AppDir ('background' + $ext.ToLowerInvariant())
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $script:Config.backgroundImage = $dst
        Reset-BackgroundCache
        Save-Config
        Refresh-Popup
    } catch {
    } finally {
        $dlg.Dispose()
    }
}

# Remove o fundo (volta ao fundo sólido).
function Remove-BackgroundImage {
    $script:Config.backgroundImage = $null
    Reset-BackgroundCache
    Save-Config
    Refresh-Popup
}

# Texto do rodapé: contagem regressiva até a próxima atualização do uso.
function Get-CountdownText {
    if ($script:NextTickAt -le 0) { return $null }
    $rem = [int][Math]::Ceiling(($script:NextTickAt - (Get-NowMs)) / 1000.0)
    if ($rem -le 0) { return 'atualizando…' }
    return ('atualiza em {0}:{1:d2}' -f [int][Math]::Floor($rem / 60), ($rem % 60))
}

# Atualiza glifo/cor/tooltip do botão de fixar conforme o estado.
function Update-PinButton {
    if (-not $script:PinButton) { return }
    if ($script:PopupForm.Pinned) {
        $script:PinButton.Text      = [string][char]0xE77A   # UnPin (Segoe MDL2 Assets)
        $script:PinButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#ffd54a')
        if ($script:PinTip) { $script:PinTip.SetToolTip($script:PinButton, 'Desafixar') }
    } else {
        $script:PinButton.Text      = [string][char]0xE718   # Pin (Segoe MDL2 Assets)
        $script:PinButton.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#9aa0a6')
        if ($script:PinTip) { $script:PinTip.SetToolTip($script:PinButton, 'Fixar') }
    }
}

function Draw-PopupContent {
    param([System.Drawing.Graphics]$g)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#1f1f23'))

    $W = $script:PopupForm.ClientSize.Width
    $H = $script:PopupForm.ClientSize.Height
    $k = Get-PopupScale            # tudo abaixo escala por este fator (responsividade)

    # Fundo: imagem em modo "cover" (preenche sem distorcer) + véu escuro para legibilidade
    $bgImg = Get-BackgroundBitmap
    if ($bgImg) {
        $s  = [Math]::Max($W / [double]$bgImg.Width, $H / [double]$bgImg.Height)
        $dw = [single]($bgImg.Width * $s); $dh = [single]($bgImg.Height * $s)
        $g.DrawImage($bgImg, [System.Drawing.RectangleF]::new([single](($W - $dw) / 2), [single](($H - $dh) / 2), $dw, $dh))
        $alpha = [int][Math]::Round(255 * [double]$script:Config.backgroundDarken)
        $veil  = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($alpha, 31, 31, 35))
        $g.FillRectangle($veil, 0, 0, $W, $H)
        $veil.Dispose()
    }

    $pad   = [single](14 * $k)
    $white = [System.Drawing.Color]::White
    $muted = [System.Drawing.ColorTranslator]::FromHtml('#9aa0a6')
    $track = [System.Drawing.ColorTranslator]::FromHtml('#3a3a40')

    $fTitle = New-UiFont ([single](10.5 * $k)) ([System.Drawing.FontStyle]::Bold)
    $fName  = New-UiFont ([single](9.0 * $k))
    $fPct   = New-UiFont ([single](9.0 * $k)) ([System.Drawing.FontStyle]::Bold)
    $fSmall = New-UiFont ([single](8.0 * $k))
    $brW    = [System.Drawing.SolidBrush]::new($white)
    $brM    = [System.Drawing.SolidBrush]::new($muted)
    try {
        $y = [single](12 * $k)
        $g.DrawString($script:DisplayTitle, $fTitle, $brW, $pad, $y)
        $y += 28 * $k

        foreach ($r in @($script:DisplayRows)) {
            $win    = $r.W
            $sevCol = [System.Drawing.ColorTranslator]::FromHtml([string]$script:Config.colors[$win.Severity])

            $g.DrawString($r.Name, $fName, $brM, $pad, $y)
            $pctStr = '{0}% {1}' -f $win.Pct, $win.Arrow
            $psz    = $g.MeasureString($pctStr, $fPct)
            $brS    = [System.Drawing.SolidBrush]::new($sevCol)
            $g.DrawString($pctStr, $fPct, $brS, [single]($W - $pad - $psz.Width), $y)
            $y += 20 * $k

            $barW = $W - 2 * $pad
            $barH = [single](8 * $k)
            $brT  = [System.Drawing.SolidBrush]::new($track)
            $g.FillRectangle($brT, [System.Drawing.RectangleF]::new($pad, $y, $barW, $barH))
            $brT.Dispose()
            $fillW = [single]([Math]::Max(0, [Math]::Min(100, $win.Pct)) / 100.0 * $barW)
            if ($fillW -gt 0) {
                $g.FillRectangle($brS, [System.Drawing.RectangleF]::new($pad, $y, $fillW, $barH))
            }
            if ($null -ne $win.Elapsed) {   # marcador de ritmo (quanto da janela já passou)
                $mx  = [single]($pad + ($win.Elapsed / 100.0 * $barW))
                $pen = [System.Drawing.Pen]::new($white, [single][Math]::Max(1.0, 1.0 * $k))
                $g.DrawLine($pen, $mx, [single]($y - 2 * $k), $mx, [single]($y + $barH + 2 * $k))
                $pen.Dispose()
            }
            $brS.Dispose()
            $y += $barH + 3 * $k
            if ($win.ResetText) {
                $g.DrawString("reset em $($win.ResetText)", $fSmall, $brM, $pad, $y)
            }
            $y += 15 * $k
        }

        if ($script:DisplayExtra) {
            $g.DrawString($script:DisplayExtra, $fSmall, $brM, $pad, $y); $y += 22 * $k
        }
        if ($script:DisplayNote) {
            $brN = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#f0a020'))
            $g.DrawString($script:DisplayNote, $fSmall, $brN, $pad, $y)
            $brN.Dispose()
        }

        # Rodapé ancorado na base: countdown até a próxima atualização (redesenhado a cada 1 s)
        $cd = Get-CountdownText
        if ($cd) {
            $g.DrawString($cd, $fSmall, $brM, $pad, [single]($H - 28 * $k))
        }

        # Borda fina translúcida acompanhando os cantos arredondados (fio sutil + suaviza
        # o serrilhado do recorte por Region, que não é antialiased).
        $r  = [single]$script:PopupCornerRadius
        $d  = [single]($r * 2)
        $bp = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $bp.AddArc(0.5, 0.5, $d, $d, 180, 90)
        $bp.AddArc($W - $d - 1.5, 0.5, $d, $d, 270, 90)
        $bp.AddArc($W - $d - 1.5, $H - $d - 1.5, $d, $d, 0, 90)
        $bp.AddArc(0.5, $H - $d - 1.5, $d, $d, 90, 90)
        $bp.CloseFigure()
        $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(40, 255, 255, 255), 1.0)
        $g.DrawPath($borderPen, $bp)
        $borderPen.Dispose(); $bp.Dispose()
    } finally {
        $fTitle.Dispose(); $fName.Dispose(); $fPct.Dispose(); $fSmall.Dispose(); $brW.Dispose(); $brM.Dispose()
    }
}

function Show-Popup {
    Update-CurrentModel
    Build-Display
    Set-PopupLayout
    if ($null -ne $script:Config.popupX -and $null -ne $script:Config.popupY) {
        # posição lembrada (usuário moveu): usa, mas mantém dentro da tela
        $px = [int]$script:Config.popupX; $py = [int]$script:Config.popupY
        $wa = [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($px, $py)).WorkingArea
        $px = [Math]::Min([Math]::Max($px, $wa.Left), $wa.Right  - $script:PopupForm.Width)
        $py = [Math]::Min([Math]::Max($py, $wa.Top),  $wa.Bottom - $script:PopupForm.Height)
        $script:PopupForm.Location = [System.Drawing.Point]::new($px, $py)
    } else {
        $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
        $x  = $wa.Right  - $script:PopupForm.Width  - 8
        $y  = $wa.Bottom - $script:PopupForm.Height - 8
        $script:PopupForm.Location = [System.Drawing.Point]::new([int]$x, [int]$y)
    }
    Set-PopupRegion                  # cantos arredondados conforme o tamanho atual
    $script:PopupForm.Show()
    $script:PopupForm.Activate()
    $script:PopupForm.BringToFront()
    $script:PopupForm.Invalidate()
    if ($script:UiTimer) { $script:UiTimer.Start() }   # countdown ao vivo enquanto aberto
}
#endregion

#region UI-Update ------------------------------------------------------------------
function Reset-Backoff {
    if ($script:Timer -and $script:Backoff -ne $script:BaseInterval) {
        $script:Backoff = $script:BaseInterval
        $script:Timer.Interval = $script:BaseInterval * 1000
        $script:NextTickAt = (Get-NowMs) + $script:Timer.Interval   # mudar Interval reinicia a contagem
    }
}
function Increase-Backoff {
    if (-not $script:Timer) { return }
    $script:Backoff = [int][Math]::Min($script:Backoff * 2, 3600)
    $script:Timer.Interval = $script:Backoff * 1000
    $script:NextTickAt = (Get-NowMs) + $script:Timer.Interval
}

function Update-State {
    param([switch]$Manual)
    $script:Note = $null
    Update-CurrentModel
    $nowSec = Get-NowSec
    $cache  = Read-Cache
    $cacheAge = if ($cache -and $cache.fetchedAt) { $nowSec - [long]$cache.fetchedAt } else { [long]::MaxValue }

    # Refresh manual respeita o piso de 300s para não tomar 429; ticks agendados já são >= 300s.
    if ($Manual -and $cache -and $cacheAge -lt $script:FetchFloorSec) {
        $script:Usage = $cache.usage
        Set-AppState 'OK'
        $script:Note = 'Aguardando janela de rate limit — exibindo cache'
        Render; return
    }

    $tok = Get-AccessToken
    if ($tok.state -eq 'NoCreds')       { $script:Usage = $null; Set-AppState 'NoCreds'; Render; return }
    if ($tok.state -eq 'RefreshFailed') {
        $script:Usage = if ($cache) { $cache.usage } else { $null }
        Set-AppState 'RefreshFailed'; Render; return
    }
    $script:Sub = $tok.sub; $script:Tier = $tok.tier

    $u = Invoke-UsageRequest -Token $tok.token
    if (-not $u.ok -and $u.status -eq 401) {        # token rejeitado: força um refresh e tenta de novo
        $tok2 = Get-AccessToken -Force
        if ($tok2.state -eq 'OK') { $script:Sub = $tok2.sub; $u = Invoke-UsageRequest -Token $tok2.token }
    }

    if ($u.ok) {
        $script:Usage = $u.data
        Write-Cache -Usage $u.data -FetchedAt $nowSec
        Set-AppState 'OK'
        Reset-Backoff
    } else {
        $script:Usage = if ($cache) { $cache.usage } else { $null }
        switch ($u.status) {
            401     { Set-AppState 'RefreshFailed' }
            429     { Set-AppState 'Rate429'; Increase-Backoff }
            0       { Set-AppState 'Offline' }
            default { Set-AppState 'HttpErr' }
        }
    }
    Render
}
#endregion

#region Main -----------------------------------------------------------------------
# Modos sem UI: resolvem e saem antes de carregar WinForms.
if ($Install)   { Load-Config; Install-Autostart;   return }
if ($Uninstall) { Uninstall-Autostart;              return }
if ($Once)      { Invoke-Once;                       return }

# A UI exige apartment STA; pwsh é MTA por padrão. Relança em STA quando necessário.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $argLine  = '-Sta -NoProfile -File "{0}"' -f $PSCommandPath
    if ($Foreground) { $argLine += ' -Foreground' }
    $wstyle = if ($Foreground) { 'Normal' } else { 'Hidden' }
    Start-Process -FilePath $pwshPath -ArgumentList $argLine -WindowStyle $wstyle
    return
}

# Instância única
$created = $false
$script:Mutex = [System.Threading.Mutex]::new($true, 'Global\claude-usebar', [ref]$created)
if (-not $created) { return }

Initialize-WinForms
Resolve-Fonts            # define as famílias de fonte (Variable/Fluent) com fallback p/ Win10
if (-not $Foreground) { try { [ClaudeUsebar.Native]::HideConsole() } catch { } }

Load-Config
if (-not (Test-Path -LiteralPath $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }

# Menu de contexto
$menu = [System.Windows.Forms.ContextMenuStrip]::new()

$miRefresh = [System.Windows.Forms.ToolStripMenuItem]::new('Atualizar agora')
$miRefresh.add_Click({ Play-RefreshSound; Update-State -Manual }) | Out-Null
$menu.Items.Add($miRefresh) | Out-Null

$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$script:MiMode = [System.Windows.Forms.ToolStripMenuItem]::new("Ícone: $($script:Config.mode)")
$script:MiMode.add_Click({
    $order = @('5h', '7d', 'max')
    $i = [array]::IndexOf($order, [string]$script:Config.mode)
    $script:Config.mode = $order[(($i + 1) % $order.Count)]
    Save-Config
    Render
}) | Out-Null
$menu.Items.Add($script:MiMode) | Out-Null

# Submenu de cor (5 temas)
$script:MiColor = [System.Windows.Forms.ToolStripMenuItem]::new('Cor')
$script:ColorItems = @{}
$colorLabels = [ordered]@{ roxo = 'Roxo'; vermelho = 'Vermelho'; azul = 'Azul'; verde = 'Verde'; laranja = 'Laranja' }
foreach ($key in $colorLabels.Keys) {
    $item = [System.Windows.Forms.ToolStripMenuItem]::new($colorLabels[$key])
    $item.Tag     = $key
    $item.Checked = ([string]$script:Config.colorTheme -eq $key)
    $item.add_Click({
        param($s, $e)
        $script:Config.colorTheme = [string]$s.Tag
        Resolve-ThemeColors $script:Config
        Save-Config
        foreach ($ci in $script:ColorItems.Values) { $ci.Checked = ($ci.Tag -eq $s.Tag) }
        Render
    }) | Out-Null
    $script:ColorItems[$key] = $item
    $script:MiColor.DropDownItems.Add($item) | Out-Null
}
$menu.Items.Add($script:MiColor) | Out-Null

# Liga/desliga o som ao clicar "Atualizar agora"
$script:MiSound = [System.Windows.Forms.ToolStripMenuItem]::new('Som ao atualizar')
$script:MiSound.Checked = [bool]$script:Config.soundEnabled
$script:MiSound.add_Click({
    param($s, $e)
    $script:Config.soundEnabled = -not [bool]$script:Config.soundEnabled
    $s.Checked = [bool]$script:Config.soundEnabled
    Save-Config
}) | Out-Null
$menu.Items.Add($script:MiSound) | Out-Null

# Submenu de fundo: trocar imagem, remover e ajustar o véu escuro
$script:MiBg = [System.Windows.Forms.ToolStripMenuItem]::new('Fundo')

$miBgPick = [System.Windows.Forms.ToolStripMenuItem]::new('Trocar fundo…')
$miBgPick.add_Click({ Set-BackgroundImage }) | Out-Null
$script:MiBg.DropDownItems.Add($miBgPick) | Out-Null

$miBgClear = [System.Windows.Forms.ToolStripMenuItem]::new('Remover fundo')
$miBgClear.add_Click({ Remove-BackgroundImage }) | Out-Null
$script:MiBg.DropDownItems.Add($miBgClear) | Out-Null

$script:MiBg.DropDownItems.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

# Submenu "Escurecer fundo" (intensidade do véu sobre a imagem)
$miDarken = [System.Windows.Forms.ToolStripMenuItem]::new('Escurecer fundo')
$script:DarkenItems = @{}
$darkenLevels = [ordered]@{ 'Claro' = 0.50; 'Médio' = 0.70; 'Escuro' = 0.85 }
foreach ($label in $darkenLevels.Keys) {
    $it = [System.Windows.Forms.ToolStripMenuItem]::new($label)
    $it.Tag = [double]$darkenLevels[$label]
    $it.Checked = ([Math]::Abs([double]$script:Config.backgroundDarken - [double]$it.Tag) -lt 0.08)
    $it.add_Click({
        param($s, $e)
        $script:Config.backgroundDarken = [double]$s.Tag
        foreach ($di in $script:DarkenItems.Values) { $di.Checked = ($di -eq $s) }
        Save-Config
        Refresh-Popup
    }) | Out-Null
    $script:DarkenItems[$label] = $it
    $miDarken.DropDownItems.Add($it) | Out-Null
}
$script:MiBg.DropDownItems.Add($miDarken) | Out-Null
$menu.Items.Add($script:MiBg) | Out-Null

$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$miOpen = [System.Windows.Forms.ToolStripMenuItem]::new('Abrir página de uso')
$miOpen.add_Click({ Start-Process 'https://claude.ai/settings/usage' }) | Out-Null
$menu.Items.Add($miOpen) | Out-Null

$miAbout = [System.Windows.Forms.ToolStripMenuItem]::new('Sobre')
$miAbout.add_Click({
    try { $script:NotifyIcon.ShowBalloonTip(4000, 'claude-usebar', 'Uso do Claude na bandeja — port do claudebar.', [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}) | Out-Null
$menu.Items.Add($miAbout) | Out-Null

$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null

$miExit = [System.Windows.Forms.ToolStripMenuItem]::new('Sair')
$miExit.add_Click({
    try { $script:Timer.Stop() } catch { }
    try { if ($script:UiTimer) { $script:UiTimer.Stop() } } catch { }
    try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { }
    try { if ($script:PopupForm) { $script:PopupForm.Dispose() } } catch { }
    try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch { }
    $script:AppContext.ExitThread()
}) | Out-Null
$menu.Items.Add($miExit) | Out-Null

# NotifyIcon + popup
$script:NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
$script:NotifyIcon.ContextMenuStrip = $menu
$script:NotifyIcon.Text = 'claude-usebar'

$script:PopupForm = [ClaudeUsebar.PopupForm]::new()
if ($null -ne $script:Config.popupWidth -and $null -ne $script:Config.popupHeight) {
    $script:PopupForm.Size = [System.Drawing.Size]::new([int]$script:Config.popupWidth, [int]$script:Config.popupHeight)
}
$script:PopupForm.add_Paint({ param($s, $e) Draw-PopupContent $e.Graphics }) | Out-Null
$script:PopupForm.add_Deactivate({
    if ($script:PopupForm.Pinned -or $script:PopupForm.Resizing) { return }   # fixado/arrastando: não some
    $script:PopupHiddenAt = Get-NowMs
    $script:PopupForm.Hide()
    if ($script:UiTimer) { $script:UiTimer.Stop() }   # popup fechado: sem repaint de countdown
}) | Out-Null
$script:PopupForm.add_Resize({
    Set-PinButtonLayout                 # alfinete acompanha o redimensionamento ao vivo
    Set-PopupRegion                     # cantos arredondados acompanham o novo tamanho
    $script:PopupForm.Invalidate()      # conteúdo re-escala durante o arraste
}) | Out-Null
$script:PopupForm.add_ResizeBegin({ $script:PopupForm.Resizing = $true }) | Out-Null
$script:PopupForm.add_ResizeEnd({
    $script:PopupForm.Resizing = $false
    $script:Config.popupWidth  = [int]$script:PopupForm.Width
    $script:Config.popupHeight = [int]$script:PopupForm.Height
    $script:Config.popupX      = [int]$script:PopupForm.Location.X
    $script:Config.popupY      = [int]$script:PopupForm.Location.Y
    Save-Config
}) | Out-Null

# Botão de alfinete (fixar/desafixar) no canto superior direito do popup
$script:PinButton = [System.Windows.Forms.Label]::new()
$script:PinButton.AutoSize  = $false
$script:PinButton.Size      = [System.Drawing.Size]::new(22, 22)
$script:PinButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#1f1f23')
$script:PinButton.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:PinButton.Font      = [System.Drawing.Font]::new($script:IconGlyphFamily, 9.5)
$script:PinButton.Cursor    = [System.Windows.Forms.Cursors]::Hand
$script:PinTip = [System.Windows.Forms.ToolTip]::new()
$script:PinButton.add_Click({
    $script:PopupForm.Pinned = -not $script:PopupForm.Pinned
    Update-PinButton
    $script:Config.pinned = [bool]$script:PopupForm.Pinned
    Save-Config
}) | Out-Null
$script:PopupForm.Controls.Add($script:PinButton)

$script:NotifyIcon.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if (((Get-NowMs) - $script:PopupHiddenAt) -lt 400) { return }   # acabou de fechar pelo Deactivate
        Show-Popup
    }
}) | Out-Null
$script:NotifyIcon.add_BalloonTipClicked({ Start-Process 'https://claude.ai/settings/usage' }) | Out-Null

# Timer
$script:BaseInterval = [int][Math]::Max(300, [int]$script:Config.intervalSec)
$script:Backoff      = $script:BaseInterval
$script:Timer = [System.Windows.Forms.Timer]::new()
$script:Timer.Interval = $script:BaseInterval * 1000
$script:Timer.add_Tick({
    $script:NextTickAt = (Get-NowMs) + $script:Timer.Interval   # antes do Update-State (backoff pode reajustar)
    Update-State
}) | Out-Null

# Timer de 1 s do countdown — só roda com o popup aberto (ligado no Show-Popup)
$script:UiTimer = [System.Windows.Forms.Timer]::new()
$script:UiTimer.Interval = 1000
$script:UiTimer.add_Tick({
    if ($script:PopupForm -and $script:PopupForm.Visible) { $script:PopupForm.Invalidate() }
    else { $script:UiTimer.Stop() }
}) | Out-Null

$script:NotifyIcon.Visible = $true
Update-State            # primeira carga já, sem esperar o primeiro tick
$script:Timer.Start()
$script:NextTickAt = (Get-NowMs) + $script:Timer.Interval

# Estado de fixado lembrado: reabre o popup já fixado, no tamanho/posição salvos
Update-PinButton
if ($script:Config.pinned) {
    $script:PopupForm.Pinned = $true
    Update-PinButton
    Show-Popup
}

$script:AppContext = [System.Windows.Forms.ApplicationContext]::new()
[System.Windows.Forms.Application]::Run($script:AppContext)

# Limpeza pós message-loop (caso saia sem passar pelo "Sair")
try { if ($script:Mutex) { $script:Mutex.Dispose() } } catch { }
#endregion
