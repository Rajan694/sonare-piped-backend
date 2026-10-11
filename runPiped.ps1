# PowerShell version of runPiped.sh.

$ScriptDir = $PSScriptRoot
Push-Location $ScriptDir
$ProgressPreference = 'SilentlyContinue'
try {

function Show-Usage {
    Write-Host "Usage: .\runPiped.ps1 [up|down|logs|status|check|bump]"
    Write-Host ""
    Write-Host "  up       Start the stack and wait for the API to answer (default)"
    Write-Host "  down     Stop and remove the containers"
    Write-Host "  logs     Follow the piped container logs"
    Write-Host "  status   Show container state and whether the API is healthy"
    Write-Host "  check    Smoke-test search, albums, streams and audio (checkPiped.ps1)"
    Write-Host "  bump [<commit>]"
    Write-Host "           Move NewPipeExtractor to <commit> (default: the newest on its dev"
    Write-Host "           branch), rebuild, check, and roll back if the check fails."
    Write-Host "  bump --bg-helper"
    Write-Host "           Pin bg-helper to its newest image, check, roll back on failure"
    Write-Host "           (for `"not a bot`" / PoToken breakage)."
    Write-Host ""
    Write-Host "Ports: piped 8090, piped-proxy 8091. bg-helper and postgres stay internal."
    exit 1
}

$Image = 'sonare-piped:local'
# The last image that started healthy. Building needs JitPack (the extractor) and Docker
# Hub; if the image is gone (pruned, new machine) this restores it without either.
$BackupDir = Join-Path $ScriptDir 'image-backup'
$Backup = Join-Path $BackupDir 'sonare-piped.tar.gz'
$ExtractorRepo = 'https://github.com/TeamNewPipe/NewPipeExtractor'
$BgHelperRepo = '1337kavin/bg-helper-server'

function Read-Text($Path) { [IO.File]::ReadAllText((Resolve-Path $Path).ProviderPath) }
function Write-Text($Path, $Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path).ProviderPath, $Text, (New-Object Text.UTF8Encoding $false))
}
function Short($Sha) { if ($Sha.Length -gt 12) { $Sha.Substring(0, 12) } else { $Sha } }

function Test-Url([string]$Url, [int]$TimeoutSec = 3) {
    try { $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec; $true } catch { $false }
}

function Test-Port([int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { $client.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $client.Connected } catch { $false } finally { $client.Dispose() }
}

# What goes into the piped image. Only a change here rebuilds it: even a fully cached build
# asks Docker Hub about the eclipse-temurin base images, and with no network (or DNS down)
# that fails after a long timeout and takes the whole start with it.
# (Files are sorted byte-wise here and by locale in runPiped.sh, so the two hash differently:
# switching between them rebuilds the image once.)
function Get-SrcHash {
    $roots = 'src', 'gradle', 'build.gradle', 'settings.gradle', 'gradlew', 'VERSION', 'Dockerfile',
        '.dockerignore', 'hotspot-entrypoint.sh', 'docker-healthcheck.sh'
    $files = foreach ($r in $roots) {
        if (Test-Path $r -PathType Container) { Get-ChildItem $r -Recurse -File -Force }
        elseif (Test-Path $r) { Get-Item $r -Force }
    }
    [string[]]$paths = $files | ForEach-Object { $_.FullName.Substring($ScriptDir.Length + 1) -replace '\\', '/' }
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    $list = New-Object Text.StringBuilder
    foreach ($p in $paths) {
        [void]$list.Append("$((Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower())  $p`n")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($list.ToString()))
    (-join ($digest | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

function Test-Image {
    docker image inspect $Image *> $null
    $LASTEXITCODE -eq 0
}

# The source hash the current image was built from ('' if none).
function Get-BuiltHash {
    $json = docker image inspect --format '{{json .Config.Labels}}' $Image 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return '' }
    $labels = ($json | Out-String) | ConvertFrom-Json
    if ($labels -and $labels.'sonare.src-hash') { "$($labels.'sonare.src-hash')" } else { '' }
}

function Get-ImageId {
    $id = docker image inspect --format '{{.Id}}' $Image 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    "$id".Trim()
}

# Saves the image once it has started healthy, only when it differs from the saved one.
function Save-ImageBackup {
    $id = Get-ImageId
    if (-not $id) { return }
    $idFile = Join-Path $BackupDir 'image-id'
    if ((Test-Path $idFile) -and ((Get-Content $idFile -Raw).Trim() -eq $id)) { return }
    Write-Host "Saving this build to image-backup/ (a fallback if jitpack.io or Docker Hub is down)..."
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $tar = "$Backup.tar"
    $ok = $false
    docker save -o $tar $Image
    if ($LASTEXITCODE -eq 0) {
        $in = $null; $out = $null; $gz = $null
        try {
            $in = [IO.File]::OpenRead($tar)
            $out = [IO.File]::Create("$Backup.tmp")
            $gz = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionLevel]::Fastest)
            $in.CopyTo($gz)
            $ok = $true
        } catch {
        } finally {
            if ($gz) { $gz.Dispose() }
            if ($out) { $out.Dispose() }
            if ($in) { $in.Dispose() }
        }
    }
    Remove-Item $tar -Force -ErrorAction SilentlyContinue
    if ($ok) {
        Move-Item -Force "$Backup.tmp" $Backup
        [IO.File]::WriteAllText($idFile, "$id`n")
    } else {
        Remove-Item "$Backup.tmp" -Force -ErrorAction SilentlyContinue
        Write-Host "WARNING: could not save the image backup."
    }
}

function Wait-Healthy {
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-Url 'http://127.0.0.1:8090/healthcheck') { return $true }
        Start-Sleep -Seconds 2
    }
    $false
}

function Invoke-Check {
    & ./checkPiped.ps1
    $LASTEXITCODE -eq 0
}

function Get-ExtractorPin {
    $m = [regex]::Match((Read-Text build.gradle), 'NewPipeExtractor:([0-9a-f]{7,40})')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}

function Set-ExtractorPin($Sha) {
    Write-Text build.gradle ([regex]::Replace((Read-Text build.gradle), '(NewPipeExtractor:)[0-9a-f]{7,40}', "`${1}$Sha"))
}

function Get-BgHelperPin {
    $m = [regex]::Match((Read-Text docker-compose.yml), "$([regex]::Escape($BgHelperRepo))@sha256:[0-9a-f]{64}")
    if ($m.Success) { $m.Value } else { '' }
}

# Moves NewPipeExtractor to $New, rebuilds and checks; on failure puts the old commit and
# the backed-up image back. Returns $false if it rolled back.
function Update-Extractor([string]$New) {
    $old = Get-ExtractorPin
    if (-not $New) {
        $line = git ls-remote $ExtractorRepo refs/heads/dev 2>$null | Select-Object -First 1
        if ($line) { $New = ($line -split "`t")[0] }
        if (-not $New) {
            Write-Host "Could not read the newest commit from $ExtractorRepo (is GitHub reachable?)."
            return $false
        }
    }
    Write-Host "=== NewPipeExtractor $(Short $old) -> $(Short $New) ==="
    if ($New -eq $old) {
        Write-Host "Already on that commit."
        return $true
    }

    # Rolling back needs a backup of the build that is running now, from this source.
    if ((Get-BuiltHash) -ne (Get-SrcHash)) {
        Write-Host "The current image wasn't built from this source, so there's nothing safe to roll"
        Write-Host "back to. Run .\runPiped.ps1 up first, then bump."
        return $false
    }
    Save-ImageBackup

    Set-ExtractorPin $New
    $env:PIPED_SRC_HASH = Get-SrcHash
    Write-Host "Building (Gradle fetches the extractor from jitpack.io; the first build of a commit"
    Write-Host "can take a few minutes while JitPack compiles it)..."
    docker compose build piped | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Build failed - keeping $(Short $old). The running Piped is untouched."
        Set-ExtractorPin $old
        return $false
    }
    docker compose up -d --no-build piped | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }

    if ((Wait-Healthy) -and (Invoke-Check)) {
        & ./syncEnvConfig.ps1 --set-commit $New | Out-Host
        Save-ImageBackup
        Write-Host "NewPipeExtractor is now $(Short $New). Commit build.gradle to keep it."
        return $true
    }

    Write-Host "=== Rolling back to $(Short $old) ==="
    $failedId = Get-ImageId
    Set-ExtractorPin $old
    $env:PIPED_SRC_HASH = Get-SrcHash
    docker load -i $Backup | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Host "Could not load $Backup."; return $false }
    # The failed build is left untagged by the load; nothing needs it.
    if ($failedId) { docker rmi $failedId *> $null }
    docker compose up -d --no-build piped | Out-Host
    if ($LASTEXITCODE -eq 0 -and (Wait-Healthy)) {
        Write-Host "Rolled back: Piped runs $(Short $old) again."
    } else {
        Write-Host "Rolled back the files, but Piped isn't healthy - check .\runPiped.ps1 logs."
    }
    $false
}

# Pins bg-helper to whatever :latest is now, checks, and restores the old pin on failure.
function Update-BgHelper {
    $old = Get-BgHelperPin
    Write-Host "=== bg-helper ==="
    docker pull -q "${BgHelperRepo}:latest" *> $null
    if ($LASTEXITCODE -ne 0) { Write-Host "Could not pull ${BgHelperRepo}:latest."; return $false }
    $digests = (docker image inspect --format '{{json .RepoDigests}}' "${BgHelperRepo}:latest" | Out-String) | ConvertFrom-Json
    $new = @($digests | Where-Object { $_.StartsWith("$BgHelperRepo@") })[0]
    Write-Host "$(($old -split '@')[-1]) -> $(("$new" -split '@')[-1])"
    if ($new -eq $old) {
        Write-Host "Already on the newest image."
        return $true
    }
    Write-Text docker-compose.yml ((Read-Text docker-compose.yml).Replace($old, $new))
    docker compose up -d --no-build bg-helper | Out-Host
    if ($LASTEXITCODE -ne 0) { return $false }
    Start-Sleep -Seconds 5
    if (Invoke-Check) {
        Write-Host "bg-helper is now pinned to $(($new -split '@')[-1]). Commit docker-compose.yml to keep it."
        return $true
    }
    Write-Host "=== Rolling back bg-helper ==="
    Write-Text docker-compose.yml ((Read-Text docker-compose.yml).Replace($new, $old))
    docker compose up -d --no-build bg-helper | Out-Host
    $false
}

$Mode = if ($args.Count -gt 0) { "$($args[0])" } else { 'up' }

switch ($Mode) {
    'down' {
        docker compose down
        exit $LASTEXITCODE
    }
    'logs' {
        docker compose logs -f piped
        exit $LASTEXITCODE
    }
    'status' {
        docker compose ps
        if (Test-Url 'http://127.0.0.1:8090/healthcheck') {
            Write-Host "API: healthy on 8090"
        } else {
            Write-Host "API: not answering on 8090"
        }
        exit 0
    }
    'check' {
        & ./checkPiped.ps1
        exit $LASTEXITCODE
    }
    'bump' {
        $commit = ''
        $bgHelper = $false
        foreach ($arg in ($args | Select-Object -Skip 1)) {
            if ($arg -eq '--bg-helper') {
                $bgHelper = $true
            } elseif ("$arg" -cmatch '^[0-9a-f]{40}$') {
                $commit = "$arg"
            } else {
                Write-Host "Not a 40-character commit hash: $arg"
                Show-Usage
            }
        }
        if (-not (Test-Url 'http://127.0.0.1:8090/healthcheck')) {
            Write-Host "Piped isn't running - start it with .\runPiped.ps1 up first."
            exit 1
        }
        $status = 0
        if (-not $bgHelper -or $commit) {
            if (-not (Update-Extractor $commit)) { $status = 1 }
        }
        if ($bgHelper) {
            if (-not (Update-BgHelper)) { $status = 1 }
        }
        exit $status
    }
    'up' { }
    default { Show-Usage }
}

if (-not (Test-Path config.properties)) {
    Write-Host "config.properties missing - run .\installPiped.ps1 first."
    exit 1
}

# Settings in .env: the extractor commit (build.gradle, so it rebuilds below) and the proxy
# URL (config.properties, which Piped only reads at startup).
$configBefore = (Get-FileHash config.properties).Hash
& ./syncEnvConfig.ps1
$configChanged = $configBefore -ne (Get-FileHash config.properties).Hash
Write-Host ""

# 8091 is the proxy port. A stale compose project from elsewhere holding it is a
# common cause of a confusing bind failure, so name that possibility up front.
if (Test-Port 8091) {
    if (-not ((docker compose ps --status running 2>$null) -match 'piped-proxy')) {
        Write-Host "Port 8091 is in use by something that is not this stack."
        Write-Host "  Another Piped compose project may be running - stop it first."
        exit 1
    }
}

Write-Host "=== Starting Piped (docker) ==="
# docker-compose.yml stamps the image with this, so the next start can compare.
$env:PIPED_SRC_HASH = Get-SrcHash
if (-not (Test-Image) -and (Test-Path $Backup)) {
    Write-Host "No $Image image - restoring the last good build from image-backup/"
    docker load -i $Backup
    if ($LASTEXITCODE -ne 0) { Write-Host "WARNING: could not load $Backup" }
}
$haveImage = Test-Image
$builtHash = if ($haveImage) { Get-BuiltHash } else { '' }

if ($haveImage -and $builtHash -eq $env:PIPED_SRC_HASH) {
    docker compose up -d --no-build
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) {
        # The first build takes a few minutes (Gradle) and needs Docker Hub.
        if (-not $haveImage) {
            Write-Host "Could not build $Image, and there is no earlier build to fall back to."
            Write-Host "The first build needs Docker Hub and jitpack.io - check the network and DNS, then retry."
            exit 1
        }
        Write-Host "WARNING: rebuilding $Image failed (are Docker Hub and jitpack.io reachable?)."
        Write-Host "  Starting the previous build, which does not have your latest changes to the Piped source."
        docker compose up -d --no-build
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
}

if ($configChanged) {
    Write-Host "config.properties changed - restarting piped to load it."
    docker compose restart piped
    if ($LASTEXITCODE -ne 0) { exit 1 }
}

Write-Host "=== Waiting for the API ==="
if (Wait-Healthy) {
    Write-Host "Piped is healthy on http://127.0.0.1:8090"
    # Without bg-helper supplying PoTokens, YouTube returns no adaptive audio
    # formats and playback silently falls back to a muxed video stream.
    if (-not ((docker compose ps --status running 2>$null) -match 'bg-helper')) {
        Write-Host "WARNING: bg-helper is not running - expect empty audioStreams."
    }
    Save-ImageBackup
    exit 0
}

Write-Host "Piped did not become healthy in 60s. Check: .\runPiped.ps1 logs"
exit 1

} catch {
    # A missing command throws here instead of setting $LASTEXITCODE.
    Write-Host ($_ | Out-String)
    exit 1
} finally { Pop-Location }
