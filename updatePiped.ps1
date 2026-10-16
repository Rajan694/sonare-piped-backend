# PowerShell version of updatePiped.sh: pull, then .\runPiped.ps1 up (rebuilds the image only
# when the Piped source changed). With Tailscale Funnel set up (COMPOSE_PROFILES=funnel in .env)
# it goes through .\funnel.ps1 up, so the gate and the Funnel ports come back too.

Push-Location $PSScriptRoot
$ProgressPreference = 'SilentlyContinue'
try {

function Show-Usage {
    Write-Host "Usage: .\updatePiped.ps1 [--no-run]"
    Write-Host ""
    Write-Host "  Pull, then start Piped (and republish it with Funnel when that is set up)."
    Write-Host "  --no-run  Stop after pulling (..\update.ps1 starts things itself)"
    Write-Host ""
    Write-Host "Refuses to pull over uncommitted changes."
    exit 1
}

$Run = $true
foreach ($a in $args) {
    switch ("$a") {
        '--no-run' { $Run = $false }
        default { Show-Usage }
    }
}

if (-not (Test-Path .env) -or -not (Test-Path config.properties)) {
    Write-Host ".env or config.properties missing - run .\installPiped.ps1 first."
    exit 1
}

if (git status --porcelain --untracked-files=no) {
    Write-Host "Uncommitted changes here - commit or stash them before updating:"
    git status --short --untracked-files=no
    exit 1
}
$Branch = git rev-parse --abbrev-ref HEAD
if ($Branch -eq 'HEAD') { Write-Host 'Detached HEAD - check out a branch first.'; exit 1 }
Write-Host "=== Pulling $Branch ==="
git pull --ff-only
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $Run) {
    Write-Host ""
    Write-Host "Piped updated ($(git log -1 --format='%h %s'))."
    exit 0
}

Write-Host ""
$tailscale = (Get-Command tailscale.exe, tailscale -CommandType Application -ErrorAction SilentlyContinue) -or
    ($env:ProgramFiles -and (Test-Path (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')))
if ((Select-String -Path .env -Pattern '^COMPOSE_PROFILES=funnel$' -CaseSensitive -Quiet) -and $tailscale) {
    & .\funnel.ps1 up
} else {
    & .\runPiped.ps1 up
}
exit $LASTEXITCODE

} finally {
    Pop-Location
}
