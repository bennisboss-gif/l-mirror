# ACTIVER-LB.ps1  (v3) -- geste unique + AUTO-DIAGNOSTIC-ET-REPARE.
# Le script OBSERVE LB (il tourne dessus) et s'adapte ; il n'y a rien a deviner cote Claude.
# Recupere par : irm 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/ACTIVER-LB.ps1' | iex
$selfUrl = 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/ACTIVER-LB.ps1'
$ErrorActionPreference = 'SilentlyContinue'
$LiteLLMDir = 'C:\LiteLLM'
$MK = '[REDACTED:sk-key]'
function Ok  ($m){ Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray  }
function Warn($m){ Write-Host "[!!]   $m" -ForegroundColor Yellow}

# --- AUTO-ELEVATION : si pas admin, se relancer en admin (accepte le UAC) ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Warn "Pas administrateur -> relance elevee (accepte la fenetre UAC qui s'ouvre)."
    Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-Command',"irm '$selfUrl' | iex"
    return
}
Write-Host "=== ACTIVATION + DIAGNOSTIC PASSERELLE LB (v3) ===" -ForegroundColor White

# --- 1. REBIND compose -> 0.0.0.0 ---
$compose = Get-ChildItem $LiteLLMDir -Filter 'docker-compose*.y*ml' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($compose) {
    $raw = Get-Content $compose.FullName -Raw
    Copy-Item $compose.FullName ("{0}.bak" -f $compose.FullName) -Force
    $new = $raw -replace '127\.0\.0\.1:4000:4000','0.0.0.0:4000:4000' `
                -replace '127\.0\.0\.1:11434:11434','0.0.0.0:11434:11434' `
                -replace '--host["\s,]+127\.0\.0\.1','--host 0.0.0.0' `
                -replace 'host:\s*127\.0\.0\.1','host: 0.0.0.0'
    if ($new -ne $raw) { Set-Content $compose.FullName -Value $new -Encoding UTF8; Ok "compose rebinde 0.0.0.0 (.bak sauvegarde)." }
    else { Info "compose deja 0.0.0.0 / sans 127.0.0.1 explicite." }
} else { Warn "compose introuvable dans $LiteLLMDir." }

# --- 2. MASTER KEY connue ---
$envf = Join-Path $LiteLLMDir '.env'; $cur = ''
if (Test-Path $envf) { $cur = Get-Content $envf -Raw }
if ($cur -match 'LITELLM_MASTER_KEY\s*=\s*(\S+)') { if ($Matches[1] -ne $MK) { $cur = $cur -replace 'LITELLM_MASTER_KEY\s*=\s*\S+', "LITELLM_MASTER_KEY=$MK"; Set-Content $envf -Value $cur -Encoding UTF8; Info "master key alignee." } }
elseif (Test-Path $envf) { Add-Content $envf "`nLITELLM_MASTER_KEY=$MK"; Info "master key posee." }

# --- 3. PARE-FEU Defender tailnet-only ---
foreach ($p in 4000,11434) {
    $n = "SocleNode-Allow-$p-Tailnet"
    if (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue) { Set-NetFirewallRule -DisplayName $n -RemoteAddress '100.64.0.0/10' -Action Allow -Enabled True | Out-Null }
    else { New-NetFirewallRule -DisplayName $n -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null }
    Ok "pare-feu Defender $p tailnet-only."
}

# --- 4. RECREER le conteneur (down+up force la prise en compte du nouveau compose/env) ---
if ($compose) {
    $up = $false; try { docker info *> $null; $up = ($LASTEXITCODE -eq 0) } catch { }
    if (-not $up) { $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'; if (Test-Path $dd) { Start-Process $dd; Info "Docker etait eteint -> demarrage, patience ~60s."; Start-Sleep 60 } else { Warn "Docker Desktop introuvable." } }
    Push-Location $compose.Directory
    Info "docker compose down puis up -d (recreation)..."
    docker compose down 2>&1 | Out-Host
    docker compose up -d 2>&1 | Out-Host
    Pop-Location
    Start-Sleep 8
}

# ===================== DIAGNOSTIC (le script observe LB) =====================
Write-Host "`n----------------- DIAGNOSTIC (colle ce bloc a Claude) -----------------" -ForegroundColor Magenta
Write-Host "[A. netstat :4000/:11434 -- QUI ecoute et sur quelle IP (127.0.0.1 = local, 0.0.0.0 = ouvert)]" -ForegroundColor Gray
(netstat -ano | Select-String ':4000\s|:11434\s') 2>&1 | Out-Host
Write-Host "[B. docker ps]" -ForegroundColor Gray
docker ps -a --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | Out-Host
Write-Host "[C. regles pare-feu SocleNode]" -ForegroundColor Gray
(Get-NetFirewallRule -DisplayName 'SocleNode-Allow-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName + '  Enabled=' + $_.Enabled }) 2>&1 | Out-Host
Write-Host "[D. compose : lignes cles]" -ForegroundColor Gray
if ($compose) { (Get-Content $compose.FullName | Select-String '4000|11434|host|ports|image') 2>&1 | Out-Host } else { Write-Host "  (pas de compose)" }
Write-Host "[E. test LOCAL http://127.0.0.1:4000]" -ForegroundColor Gray
$live = $false; try { Invoke-RestMethod 'http://127.0.0.1:4000/health/liveliness' -TimeoutSec 5 *> $null; $live = $true } catch { }
if ($live) { Write-Host "  LOCAL:4000 = REPOND (LiteLLM tourne)" -ForegroundColor Green } else { Write-Host "  LOCAL:4000 = muet (conteneur pas up)" -ForegroundColor Yellow }
Write-Host "-----------------------------------------------------------------------" -ForegroundColor Magenta

Write-Host "`n=====================================================" -ForegroundColor White
if ($live) { Ok "LiteLLM repond en LOCAL sur LB." ; Write-Host ">> Dis a Claude 'LB canal ouvert' + COLLE-LUI le bloc DIAGNOSTIC (A-E) ci-dessus." -ForegroundColor Cyan }
else { Warn "LiteLLM ne repond pas en local -> conteneur pas up (voir A/B)." ; Write-Host ">> COLLE-MOI le bloc DIAGNOSTIC (A-E) et je corrige au coup d'apres." -ForegroundColor Cyan }
Write-Host "=====================================================" -ForegroundColor White
