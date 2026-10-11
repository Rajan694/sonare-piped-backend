# PowerShell version of installPiped.sh.
#
# This is the one component that runs in Docker. Postgres, Redis and the Sonare
# backend are all local, so nothing here should be installed on the host.

Push-Location $PSScriptRoot
try {

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "docker not found - it is required for the Piped backend."
    exit 1
}

docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "docker compose (v2) not found - install the compose plugin."
    exit 1
}

if (-not (Test-Path config.properties)) {
    Write-Host "=== Creating config.properties from config.properties.example ==="
    Copy-Item config.properties.example config.properties
}

if (-not (Test-Path .env)) {
    Write-Host "=== Creating .env from .env.example ==="
    Copy-Item .env.example .env
}

# Settings in .env, so the build below uses them.
& ./syncEnvConfig.ps1
Write-Host ""

# The piped service is built from this directory (sonare-piped:local), so it has
# no registry to pull from - pull the upstream images and build that one.
Write-Host "=== Pulling images ==="
docker compose pull --ignore-buildable
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== Building sonare-piped:local ==="
docker compose build piped
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Piped ready. Start it with .\runPiped.ps1"
exit 0

} catch {
    # A missing command throws here instead of setting $LASTEXITCODE.
    Write-Host ($_ | Out-String)
    exit 1
} finally { Pop-Location }
