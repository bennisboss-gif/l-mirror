# ACTIVER-LB.ps1 -- geste unique d'ouverture de la passerelle LB (bpc/MSI).
# AUTONOME : zero token, zero clone, zero chemin deduit. Recupere par irm|iex.
# Fait : rebind LiteLLM 0.0.0.0 + pare-feu tailnet-only + master key connue + restart + health.
$ErrorActionPreference = 'SilentlyContinue'
$LiteLLMDir = 'C:\LiteLLM'
$MK = '[REDACTED:sk-key]'   # master key connue de Claude (tailnet-isolee, rotation V2)
function Ok  ($m){ Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray  }
function Warn($m){ Write-Host "[!!]   $m" -ForegroundColor Yellow}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "[STOP] Ouvre un PowerShell EN ADMINISTRATEUR (clic droit > Executer en tant qu'administrateur), puis recolle." -ForegroundColor Red; return }
Write-Host "=== ACTIVATION PASSERELLE LB (geste unique) ===" -ForegroundColor White

# 1. REBIND compose -> 0.0.0.0 (couvre le port mapping ET le --host de LiteLLM)
$compose = Get-ChildItem $LiteLLMDir -Filter 'docker-compose*.y*ml' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $compose) {
    Warn "docker-compose introuvable dans $LiteLLMDir."
    Write-Host ">> Colle-moi la sortie de : Get-ChildItem C:\LiteLLM -Recurse -Depth 2 | Select-Object FullName" -ForegroundColor Cyan
    return
}
$raw = Get-Content $compose.FullName -Raw
Copy-Item $compose.FullName ("{0}.bak" -f $compose.FullName) -Force
$new = $raw -replace '127\.0\.0\.1:4000:4000','0.0.0.0:4000:4000' `
            -replace '127\.0\.0\.1:11434:11434','0.0.0.0:11434:11434' `
            -replace '--host["\s,]+127\.0\.0\.1','--host 0.0.0.0' `
            -replace 'host:\s*127\.0\.0\.1','host: 0.0.0.0'
if ($new -ne $raw) { Set-Content $compose.FullName -Value $new -Encoding UTF8; Ok "Passerelle rebindee 0.0.0.0 (compose .bak sauvegarde)." }
else { Info "Compose deja 0.0.0.0 (ou publie sans 127.0.0.1) : inchange." }

# 2. PARE-FEU tailnet-only (4000 + 11434 depuis 100.64.0.0/10 ; jamais de Block)
foreach ($p in 4000,11434) {
    $n = "SocleNode-Allow-$p-Tailnet"
    if (Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue) { Set-NetFirewallRule -DisplayName $n -RemoteAddress '100.64.0.0/10' -Action Allow -Enabled True | Out-Null }
    else { New-NetFirewallRule -DisplayName $n -Direction Inbound -Action Allow -Protocol TCP -LocalPort $p -RemoteAddress '100.64.0.0/10' -Profile Any | Out-Null }
    Ok "Pare-feu $p : ALLOW restreint au tailnet."
}

# 3. MASTER KEY connue (aligne .env sur la valeur que Claude connait)
$envf = Join-Path $LiteLLMDir '.env'; $cur = ''
if (Test-Path $envf) { $cur = Get-Content $envf -Raw }
if ($cur -match 'LITELLM_MASTER_KEY\s*=\s*(\S+)') {
    if ($Matches[1] -ne $MK) { $cur = $cur -replace 'LITELLM_MASTER_KEY\s*=\s*\S+', "LITELLM_MASTER_KEY=$MK"; Set-Content $envf -Value $cur -Encoding UTF8; Warn "Master key alignee sur la valeur connue de Claude." }
    else { Ok "Master key deja alignee." }
} else { Add-Content $envf "`nLITELLM_MASTER_KEY=$MK"; Ok "Master key posee (connue de Claude)." }

# 4. (RE)DEMARRAGE du conteneur
$up = $false
try { docker info *> $null; $up = ($LASTEXITCODE -eq 0) } catch { }
if (-not $up) { $dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'; if (Test-Path $dd) { Start-Process $dd; Info "Docker etait eteint -> demarrage, patience ~45s."; Start-Sleep 45 } else { Warn "Docker Desktop introuvable." } }
Push-Location $compose.Directory
docker compose up -d 2>&1 | Out-Host
Pop-Location

# 5. HEALTH + inventaire modeles (local sur LB)
$live = $false
foreach ($i in 1..20) { try { Invoke-RestMethod 'http://127.0.0.1:4000/health/liveliness' -TimeoutSec 3 *> $null; $live = $true; break } catch { }; Start-Sleep 3 }
$mc = 0
if ($live) { try { $r = Invoke-RestMethod 'http://127.0.0.1:4000/v1/models' -Headers @{ Authorization = "Bearer $MK" } -TimeoutSec 6; $mc = @($r.data).Count } catch { } }

# VERDICT
Write-Host "`n=====================================================" -ForegroundColor White
if ($live) {
    Ok ("PASSERELLE LB OUVERTE sur 0.0.0.0:4000 -- {0} modele(s) present(s)." -f $mc)
    Write-Host ">> Dis a Claude : 'LB canal ouvert'" -ForegroundColor Cyan
} else {
    Warn "Passerelle PAS encore joignable en local. Diagnostic :"
    docker ps -a --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | Out-Host
    Write-Host "--- lignes ports/host du compose ---" -ForegroundColor Gray
    (Get-Content $compose.FullName | Select-String -Pattern '4000|11434|host|ports') 2>&1 | Out-Host
    Write-Host ">> Colle-moi tout ce bloc et je corrige au coup d'apres." -ForegroundColor Cyan
}
Write-Host "=====================================================" -ForegroundColor White
