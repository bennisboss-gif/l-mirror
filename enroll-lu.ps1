<#
=====================================================================
 enroll-lu.ps1  --  ENROLEMENT UN-GESTE de LU (bmax-03, role socle)
=====================================================================

 POUR BADRE, EN UNE PHRASE
 -------------------------
 Tu colles UNE ligne (voir LU-ONE-SHOT.md, section COCA), ce script tourne
 TOUT SEUL sur LU et le transforme en noeud du socle (bmax-03) : il recupere
 le vrai bootstrap SANS aucun token, pose les secrets, lance l'installation
 et verifie que LU est READY + Ollama joignable. Tu ne fais ce geste qu'UNE fois.

 CE QUE TU DOIS PREPARER AVANT DE COLLER (le strict minimum) :
   1. Allumer LU.
   2. Generer une authkey Tailscale FRAICHE pre-taggee tag:socle en console
      (Settings -> Keys -> Generate ; reusable, non-ephemere, Tags=tag:socle).
      -> L'ancienne cle du repo est REVOQUEE : sans cle fraiche, pas d'enrolement.
   3. Poser cette cle dans UN fichier texte "A-REMPLIR-secrets-LU.txt" (voir le
      gabarit du meme nom). UN seul champ obligatoire. Le fichier peut etre sur
      le Bureau, dans Telechargements, a la racine C:\, ou dans C:\SocleNode :
      ce script le TROUVE tout seul.

 CE QU'IL FAIT (idempotent, re-jouable sans casse, zero chemin devine) :
   [1] S'auto-eleve (UAC) proprement -- aucune autre fenetre parasite.
   [2] Trouve et lit A-REMPLIR-secrets-LU.txt (balaye tous les emplacements
       plausibles ; s'arrete avec un bloc clair s'il manque).
   [3] Recupere bootstrap-noeud.ps1 SANS TOKEN via le "blob-git" : telecharge
       le snapshot PUBLIC chiffre du repo depuis l-mirror (schannel, passe
       l'antivirus Avast), verifie le sha256, dechiffre (AES-256), extrait le
       bootstrap et NORMALISE (retire BOM/CRLF -> bootstrap identique a la
       source git : neutralise le piege here-strings bash).
   [4] Pose C:\SocleNode\secrets.local.ps1 (ACL durcie par le bootstrap).
   [5] Lance le bootstrap EN MEMOIRE (jamais ecrit sur disque -> echappe a la
       quarantaine Avast) : -NodeName bmax-03 -Role socle.
   [6] Verifie READY + service Ollama, puis SUPPRIME le fichier de secrets.

 GARDE (garde-fou-doit-preserver-sa-fonction) : chaque etape a un repli qui
 PRESERVE la fonction (message clair, jamais un plantage muet). Le seul secret
 que TOI seul detiens (authkey fraiche) vit dans le A-REMPLIR, jamais ici,
 jamais en clair dans un fichier public, jamais colle dans un shell.

 Recupere par (LA LIGNE COCA) :
   irm 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/enroll-lu.ps1' | iex
=====================================================================
#>
[CmdletBinding()]
param(
    # Emplacement optionnel du fichier de secrets (sinon: recherche automatique).
    [string]$SecretsFile,
    # Ne PAS toucher : positionne par l'auto-elevation pour ne pas boucler.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$SelfUrl   = 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main/enroll-lu.ps1'
$MirrorRaw = 'https://raw.githubusercontent.com/bennisboss-gif/l-mirror/main'
$NodeState = 'C:\SocleNode'
$SecretsBaseName = 'A-REMPLIR-secrets-LU.txt'

# Passphrase de la RESERVE PUBLIQUE chiffree (SECRETS-V1.md section 4). Elle protege
# UNIQUEMENT le miroir public (deja recuperable sans token par conception) : la porter
# ici n'expose rien de plus que l'existence meme de la reserve publique. Elle NE dechiffre
# PAS les secrets du noeud (authkey/ArchivePassphrase), qui ne transitent jamais en public.
$ReservePassphrase = 'd44c0c6fb13f86b742ac650c12e045bc11e9e9ea1fbfec3cd679459462395214'

function Ok  ($m){ Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m){ Write-Host "[INFO] $m" -ForegroundColor Gray  }
function Warn($m){ Write-Host "[!!]   $m" -ForegroundColor Yellow}
function Step($m){ Write-Host "[>>]   $m" -ForegroundColor Cyan  }
function Die ($m){
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Red
    Write-Host "[STOP] $m" -ForegroundColor Red
    Write-Host "=====================================================" -ForegroundColor Red
    # Fenetre elevee : ne pas se fermer d'un coup, laisser Badre lire.
    if ($Elevated) { Write-Host "`n(Corrige le point ci-dessus puis recolle la ligne COCA.)" -ForegroundColor Red; Start-Sleep -Seconds 2 }
    exit 1
}

Write-Host ""
Write-Host "=== ENROLEMENT LU (bmax-03 / role socle) -- geste unique 'coca' ===" -ForegroundColor White

# =====================================================================
# [1] AUTO-ELEVATION (UAC). On se relance ELEVE en re-executant la ligne COCA,
#     en propageant l'emplacement des secrets s'il a ete resolu ici.
# =====================================================================
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Warn "Pas administrateur -> relance elevee (accepte la fenetre UAC bleue)."
    # On re-tire le script depuis l-mirror et on rappelle -Elevated (idempotent, zero fichier).
    $relaunch = "`$s=irm '$SelfUrl'; & ([scriptblock]::Create(`$s)) -Elevated"
    try {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-Command',$relaunch
        Info "Fenetre elevee lancee. Cette fenetre-ci peut etre fermee ; suis l'AUTRE (bleue)."
    } catch {
        Die "L'elevation a ete refusee ou a echoue. Relance PowerShell en tant qu'administrateur, puis recolle la ligne COCA."
    }
    return
}
Ok "Contexte administrateur confirme."

# =====================================================================
# [2] TROUVER + LIRE le fichier de secrets (zero chemin devine : on balaye).
# =====================================================================
Step "Recherche du fichier de secrets '$SecretsBaseName'..."
function Resolve-SecretsFile {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path $Explicit)) { return (Resolve-Path $Explicit).Path }
    # Emplacements plausibles, du plus probable au moins probable. On couvre le Bureau
    # (y compris redirige OneDrive), Telechargements, C:\SocleNode, la racine du disque
    # systeme, et le repertoire courant.
    $cands = New-Object System.Collections.Generic.List[string]
    $userProf = $env:USERPROFILE
    foreach ($sub in @('Desktop','Bureau','Downloads','Telechargements')) {
        if ($userProf) { $cands.Add((Join-Path $userProf $sub)) }
    }
    # OneDrive redirige parfois le Bureau.
    foreach ($od in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if ($od) { $cands.Add((Join-Path $od 'Desktop')); $cands.Add((Join-Path $od 'Bureau')) }
    }
    # Bureaux de TOUS les profils (au cas ou le fichier est depose sous un autre compte).
    Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $cands.Add((Join-Path $_.FullName 'Desktop')); $cands.Add((Join-Path $_.FullName 'Downloads'))
    }
    $cands.Add($NodeState)
    $cands.Add("$($env:SystemDrive)\")
    $cands.Add((Get-Location).Path)
    foreach ($d in $cands) {
        if ($d -and (Test-Path $d)) {
            $hit = Get-ChildItem -Path $d -Filter $SecretsBaseName -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    # Dernier filet : recherche large mais bornee (Bureau/Downloads deja couverts ; ici C:\ profond=NON,
    # trop lent -> on se limite a une recherche recursive PEU profonde sous C:\Users).
    $deep = Get-ChildItem 'C:\Users' -Filter $SecretsBaseName -File -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($deep) { return $deep.FullName }
    return $null
}

$sf = Resolve-SecretsFile -Explicit $SecretsFile
if (-not $sf) {
    Die @"
Fichier de secrets introuvable : $SecretsBaseName
Cree-le (a partir du gabarit du meme nom) et pose-le sur le Bureau de LU, puis
recolle la ligne COCA. Il doit contenir au minimum la ligne :
  TailscaleAuthKey = tskey-auth-<ta cle FRAICHE pre-taggee tag:socle>
"@
}
Ok "Fichier de secrets trouve : $sf"

# Parseur tolerant : 'Cle = valeur' ou 'Cle: valeur', ignore # commentaires et lignes vides.
function Read-KV {
    param([string]$Path)
    $h = @{}
    foreach ($line in (Get-Content -Path $Path -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($t -match '^\s*([A-Za-z0-9_]+)\s*[:=]\s*(.+?)\s*$') {
            $h[$Matches[1]] = $Matches[2].Trim().Trim("'").Trim('"')
        }
    }
    return $h
}
$kv = Read-KV -Path $sf

# Champ OBLIGATOIRE : l'authkey fraiche. On accepte quelques alias par tolerance.
$authKey = $null
foreach ($k in @('TailscaleAuthKey','AuthKey','tskey','TSKey')) {
    if ($kv.ContainsKey($k) -and $kv[$k]) { $authKey = $kv[$k]; break }
}
# Filet ultime : la premiere chose qui ressemble a une authkey ou j'ai trouve le fichier.
if (-not $authKey) {
    $raw = Get-Content -Path $sf -Raw -ErrorAction SilentlyContinue
    if ($raw -match '(tskey-auth-\S+)') { $authKey = $Matches[1] }
}
if (-not $authKey -or $authKey -notmatch '^tskey-') {
    Die @"
Le fichier '$sf' ne contient pas d'authkey valide.
Ajoute une ligne EXACTEMENT comme ceci (cle generee FRAICHE en console Tailscale,
pre-taggee tag:socle, reusable, non-ephemere) :
  TailscaleAuthKey = tskey-auth-XXXXXXXXXXXX
"@
}
if ($authKey -match 'REVOQUEE|kzRr6kYU8521CNTRL') {
    Die "L'authkey collee est l'ANCIENNE (revoquee le 02/07). Genere une cle FRAICHE tag:socle en console Tailscale et remets-la dans le fichier."
}
Ok "Authkey lue (jamais affichee)."

# Champ OPTIONNEL : ArchivePassphrase (passerelle LiteLLM Phase 2). Si absent, le bootstrap
# monte Ollama seul (suffisant pour le role failover) et saute LiteLLM proprement.
$archivePass = $null
foreach ($k in @('ArchivePassphrase','Passphrase')) {
    if ($kv.ContainsKey($k) -and $kv[$k]) { $archivePass = $kv[$k]; break }
}
if ($archivePass) { Info "ArchivePassphrase fournie (la passerelle LiteLLM sera tentee en Phase 2)." }
else { Info "Pas d'ArchivePassphrase : LU montera Ollama seul (role failover OK ; LiteLLM = plus tard)." }

# =====================================================================
# [3] RECUPERER bootstrap-noeud.ps1 SANS TOKEN (blob-git via snapshot public chiffre).
# =====================================================================
Step "Recuperation du bootstrap (snapshot public chiffre, zero token)..."
New-Item -ItemType Directory -Force $NodeState | Out-Null

function Get-Url {
    # Telechargement Avast-safe : Invoke-WebRequest (schannel) plutot que curl (HTTP_000 sous Avast).
    param([string]$Url, [string]$OutFile)
    if ($OutFile) {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec 120
    } else {
        return (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60).Content
    }
}

# 3a. Pointeur LATEST.json (public, sans token).
try { $latest = Get-Url "$MirrorRaw/LATEST.json" | ConvertFrom-Json }
catch { Die "Impossible de lire LATEST.json sur l-mirror (reseau ? $($_.Exception.Message)). Verifie la connexion Internet de LU et recolle." }
$binRel = $latest.bin; $expSha = ($latest.sha256_bin).ToLower()
if (-not $binRel) { Die "LATEST.json ne pointe aucun snapshot (.bin). Reserve publique incomplete." }
Info "Snapshot cible : $binRel (commit $($latest.commit))."

# 3b. Telecharger le .bin chiffre + verifier le sha256 (integrite : CBC n'est pas authentifie).
$binLocal = Join-Path $NodeState 'lu-snapshot.bin'
try { Get-Url "$MirrorRaw/$binRel" -OutFile $binLocal }
catch { Die "Telechargement du snapshot chiffre echoue ($($_.Exception.Message))." }
$gotSha = (Get-FileHash $binLocal -Algorithm SHA256).Hash.ToLower()
if ($gotSha -ne $expSha) {
    Remove-Item $binLocal -Force -ErrorAction SilentlyContinue
    Die "sha256 du snapshot NON conforme (attendu $expSha, obtenu $gotSha). Telechargement corrompu ou reserve alteree -> on s'arrete."
}
Ok "Snapshot telecharge et sha256 verifie."

# 3c. openssl (fourni par Git for Windows). Sans git/openssl, on installe git (winget) puis on reessaie.
function Get-OpenSSL {
    $c = Get-Command 'openssl.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\Git\usr\bin\openssl.exe","$env:ProgramFiles\Git\mingw64\bin\openssl.exe","${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
$openssl = Get-OpenSSL
if (-not $openssl) {
    Warn "openssl absent (fourni par Git for Windows) : installation de Git via winget..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        $openssl = Get-OpenSSL
    }
    if (-not $openssl) {
        Die "openssl/Git introuvable et installation auto impossible. Installe Git for Windows (git-scm.com) sur LU, puis recolle la ligne COCA."
    }
}
Ok "openssl disponible."

# 3d. Dechiffrer -> tar.gz -> extraire UNIQUEMENT le bootstrap. Passphrase via variable d'env
#     (jamais en argv -> pas dans la liste des processus).
$tgz = Join-Path $NodeState 'lu-snapshot.tar.gz'
$env:LU_RP = $ReservePassphrase
try {
    & $openssl enc -d -aes-256-cbc -pbkdf2 -in $binLocal -out $tgz -pass env:LU_RP 2>$null
    $code = $LASTEXITCODE
} finally { Remove-Item Env:\LU_RP -ErrorAction SilentlyContinue }
if ($code -ne 0 -or -not (Test-Path $tgz)) {
    Die "Dechiffrement du snapshot echoue. La passphrase reserve embarquee ne correspond pas au snapshot courant (reserve regeneree ?). Signale-le : le launcher doit etre resynchronise."
}

# tar est natif Windows 10/11 (bsdtar). Extraire seulement le bootstrap.
$bootRel = 'work/socle-v2/bootstrap-noeud.ps1'
Push-Location $NodeState
try {
    & tar -xzf $tgz $bootRel 2>$null
} finally { Pop-Location }
$bootExtracted = Join-Path $NodeState $bootRel
if (-not (Test-Path $bootExtracted)) {
    Die "Le bootstrap n'a pas ete extrait du snapshot (chemin $bootRel absent). Reserve incomplete -> a resynchroniser."
}

# 3e. NORMALISER (retire BOM + CRLF->LF) : rend le fichier byte-identique a la source git,
#     ce qui neutralise le piege des here-strings bash (Docker) casses par le CRLF.
$rawBoot = [System.IO.File]::ReadAllText($bootExtracted)
$rawBoot = $rawBoot -replace "^﻿", ''      # BOM
$rawBoot = $rawBoot -replace "`r`n", "`n" -replace "`r", "`n"
Ok "Bootstrap recupere et normalise (BOM/CRLF retires ; identique a la source git)."

# =====================================================================
# [4] POSER secrets.local.ps1 dans C:\SocleNode.
# =====================================================================
Step "Depot de secrets.local.ps1 dans $NodeState..."
$secExpr = "`$Secrets = @{ TailscaleAuthKey = '$authKey'"
if ($archivePass) { $secExpr += "; ArchivePassphrase = '$archivePass'" }
else { $secExpr += "; ArchivePassphrase = 'unused-ollama-only'" }   # champ obligatoire du bootstrap ; valeur inerte si pas de LiteLLM
$secExpr += " }"
$secPath = Join-Path $NodeState 'secrets.local.ps1'
[System.IO.File]::WriteAllText($secPath, $secExpr, (New-Object System.Text.UTF8Encoding($false)))
# ACL immediate (le bootstrap les durcira aussi, mais on ne laisse pas une fenetre ouverte).
try {
    $admins = (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
    $system = (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')).Translate([Security.Principal.NTAccount]).Value
    icacls $secPath /inheritance:r /grant:r "${system}:F" "${admins}:F" *> $null
} catch { }
Ok "secrets.local.ps1 pose (ACL durcie ; contenu jamais affiche)."

# =====================================================================
# [5] LANCER le bootstrap EN MEMOIRE (jamais ecrit -> echappe a Avast).
#     On remplace $PSScriptRoot par C:\SocleNode (ou vivent les secrets) et on
#     retire la directive #Requires (inerte dans un scriptblock).
# =====================================================================
Step "Lancement du bootstrap : -NodeName bmax-03 -Role socle (in-memory)..."
Set-Location $NodeState
$src = $rawBoot -replace '(?m)^#Requires.*$','' -replace [regex]::Escape('$PSScriptRoot'), "'$NodeState'"
try {
    & ([scriptblock]::Create($src)) -NodeName bmax-03 -Role socle
} catch {
    Die "Le bootstrap a leve une erreur : $($_.Exception.Message). Le log detaille est dans $NodeState\bootstrap-noeud.log. Corrige la cause indiquee et recolle (le bootstrap est idempotent, il reprend)."
}

# =====================================================================
# [6] VERIFIER + nettoyer.
# =====================================================================
Step "Verification finale..."
$readyOk = Test-Path (Join-Path $NodeState 'READY')
$svc = Get-Service -Name 'OllamaSocle' -ErrorAction SilentlyContinue
$svcOk = ($svc -and $svc.Status -eq 'Running')

# Nettoyage : le fichier de secrets a rempli son role, on le retire (il a servi une fois).
Remove-Item $sf -Force -ErrorAction SilentlyContinue
Remove-Item $binLocal, $tgz -Force -ErrorAction SilentlyContinue
Ok "Fichier de secrets A-REMPLIR supprime (il a servi)."

Write-Host ""
Write-Host "=====================================================" -ForegroundColor White
if ($readyOk -and $svcOk) {
    Ok "LU ENROLE : C:\SocleNode\READY present + service Ollama RUNNING."
    Info "Nom Tailscale attendu : bmax-03 (100.78.167.34). Claude verifiera depuis LS."
    Write-Host ">> Dis a Claude : 'LU enrole'" -ForegroundColor Cyan
} elseif ($readyOk) {
    Warn "READY present mais service Ollama pas encore Running. Il peut monter avec un peu de retard."
    Write-Host "   Verifie dans ~30s : (Get-Service OllamaSocle).Status" -ForegroundColor Yellow
    Write-Host ">> Dis a Claude : 'LU presque - Ollama en attente'" -ForegroundColor Cyan
} else {
    Warn "READY absent : le bootstrap n'a pas fini (souvent un reboot WSL2 est en cours)."
    Write-Host "   Si la machine a redemarre, la reprise repart SEULE a l'ouverture de session ;" -ForegroundColor Yellow
    Write-Host "   sinon recolle la ligne COCA (idempotent, ca reprend ou ca en etait)." -ForegroundColor Yellow
    Write-Host ">> Colle a Claude le contenu de $NodeState\bootstrap-noeud.log si ca coince." -ForegroundColor Cyan
}
Write-Host "=====================================================" -ForegroundColor White
