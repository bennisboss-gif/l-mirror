# ACTIVER-LB.ps1  (v4) -- ouvre la passerelle + REPARE LE PARE-FEU TAILNET.
# Cause identifiee depuis LS : tailscale ping OK mais TOUT l'inbound TCP de bpc est droppe
# (interface Tailscale en profil Public + Docker Desktop bloque com.docker.backend).
# Recupere par : irm 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/ACTIVER-LB.ps1' | iex
$selfUrl = 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/ACTIVER-LB.ps1'
$ErrorActionPreference = 'SilentlyContinue'
$LiteLLMDir = 'C:\LiteLLM'
$MK = '[REDACTED:sk-key]'
$CGNAT = '100.64.0.0/10'
function Ok  ($m){ Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray  }
function Warn($m){ Write-Host "[!!]   $m" -ForegroundColor Yellow}

# --- AUTO-ELEVATION ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Warn "Pas administrateur -> relance elevee (accepte la fenetre UAC)."
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-Command',"irm '$selfUrl' | iex"
    return
}
Write-Host "=== ACTIVER-LB v4 : passerelle + REPARATION PARE-FEU TAILNET ===" -ForegroundColor White

# --- 1. PROFIL RESEAU Tailscale -> Private (Public bloque tout l'inbound) ---
$tsProfiles = Get-NetConnectionProfile | Where-Object { $_.InterfaceAlias -match 'Tailscale' -or $_.InterfaceAlias -match 'tailscale' }
if ($tsProfiles) {
    foreach ($p in $tsProfiles) {
        Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
        Ok "Interface '$($p.InterfaceAlias)' : profil $($p.NetworkCategory) -> Private."
    }
} else { Info "Interface Tailscale non trouvee par nom (profil non change) - la regle CGNAT couvrira quand meme." }

# --- 2. NEUTRALISER les regles BLOCK inbound qui touchent Docker ou nos ports ---
$targets = @('4000','11434','5678','8000','8888','5985')
$blocks = Get-NetFirewallRule -Direction Inbound -Action Block -Enabled True -ErrorAction SilentlyContinue
$nbDis = 0
foreach ($b in $blocks) {
    $app = ($b | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
    $ports = ($b | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort
    $hit = $false
    if ($app -match 'docker|backend|vpnkit|litellm') { $hit = $true }
    foreach ($t in $targets) { if ($ports -contains $t) { $hit = $true } }
    if ($hit) { Disable-NetFirewallRule -Name $b.Name -ErrorAction SilentlyContinue; Write-Host "  Block desactive : $($b.DisplayName)" -ForegroundColor Yellow; $nbDis++ }
}
Ok "Regles Block neutralisees : $nbDis."

# --- 3. ALLOW LARGE depuis le tailnet (reseau chiffre de confiance : tous ports, tous profils) ---
if (Get-NetFirewallRule -DisplayName 'SocleNode-Allow-Tailnet-ALL' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -DisplayName 'SocleNode-Allow-Tailnet-ALL' -RemoteAddress $CGNAT -Action Allow -Enabled True | Out-Null
} else {
    New-NetFirewallRule -DisplayName 'SocleNode-Allow-Tailnet-ALL' -Direction Inbound -Action Allow -RemoteAddress $CGNAT -Profile Any -Protocol Any | Out-Null
}
Ok "ALLOW inbound tout-port depuis le tailnet ($CGNAT) pose."

# --- 4. ALLOW par programme com.docker.backend (ceinture + bretelles) ---
$db = Get-ChildItem 'C:\Program Files\Docker' -Recurse -Filter 'com.docker.backend.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($db) {
    if (-not (Get-NetFirewallRule -DisplayName 'SocleNode-Allow-DockerBackend' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'SocleNode-Allow-DockerBackend' -Direction Inbound -Action Allow -Program $db.FullName -RemoteAddress $CGNAT -Profile Any | Out-Null
    }
    Ok "ALLOW par programme com.docker.backend pose."
}

# --- 5. Docker up (idempotent, PAS de down -- ne pas casser l'existant) ---
$compose = Get-ChildItem $LiteLLMDir -Filter 'docker-compose*.y*ml' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($compose) { Push-Location $compose.Directory; docker compose up -d 2>&1 | Out-Null; Pop-Location; Info "docker compose up -d (idempotent)." }

# --- 6. DIAGNOSTIC ---
Write-Host "`n----------------- DIAGNOSTIC -----------------" -ForegroundColor Magenta
Write-Host "[profils reseau]" -ForegroundColor Gray
(Get-NetConnectionProfile | ForEach-Object { "  " + $_.InterfaceAlias + " = " + $_.NetworkCategory }) 2>&1 | Out-Host
Write-Host "[regles SocleNode]" -ForegroundColor Gray
(Get-NetFirewallRule -DisplayName 'SocleNode-*' -ErrorAction SilentlyContinue | ForEach-Object { "  " + $_.DisplayName + " Enabled=" + $_.Enabled + " Action=" + $_.Action }) 2>&1 | Out-Host
Write-Host "[test LOCAL :4000]" -ForegroundColor Gray
$live=$false; try { Invoke-RestMethod 'http://127.0.0.1:4000/health/liveliness' -TimeoutSec 5 *> $null; $live=$true } catch {}
if ($live) { Write-Host "  LOCAL:4000 = REPOND" -ForegroundColor Green } else { Write-Host "  LOCAL:4000 = muet" -ForegroundColor Yellow }
Write-Host "----------------------------------------------" -ForegroundColor Magenta

Write-Host "`n=====================================================" -ForegroundColor White
Ok "Pare-feu tailnet ouvert. Claude va re-sonder depuis LS."
Write-Host ">> Dis a Claude : 'LB ouvert' (et si ca ne passe toujours pas, colle-lui le bloc DIAGNOSTIC)." -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor White
