# PowerShell version of syncEnvConfig.sh.
#
# Copies the Piped settings in .env (next to docker-compose.yml, see .env.example) into the
# files Piped is built and started from:
#
#   PIPED_EXTRACTOR_COMMIT -> the NewPipeExtractor pin in build.gradle. That changes the
#                             source hash, so .\runPiped.ps1 rebuilds the image.
#   PIPED_PROXY_URL        -> PROXY_PART in config.properties, read when Piped starts.
#
# A setting that is empty or missing leaves its file alone. An environment variable wins
# over .env. This never fails the caller.
#
#   .\syncEnvConfig.ps1 --set-commit <sha>
#       The other direction, for `.\runPiped.ps1 bump`: if .env pins a commit, replace it
#       with <sha>, so the next start doesn't put the old one back.

Push-Location $PSScriptRoot
try {

# Whole-file reads and writes, so line endings and the bind-mounted file's inode survive.
function Read-Text($Path) { [IO.File]::ReadAllText((Resolve-Path $Path).ProviderPath) }
function Write-Text($Path, $Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path).ProviderPath, $Text, (New-Object Text.UTF8Encoding $false))
}
function Short($Sha) { if ($Sha.Length -gt 12) { $Sha.Substring(0, 12) } else { $Sha } }

# The value of $Name from the environment, else from .env (quotes stripped).
function Get-Setting($Name) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value -and (Test-Path .env)) {
        $line = Get-Content .env | Where-Object { $_ -cmatch "^$Name=" } | Select-Object -Last 1
        if ($line) { $value = $line.Substring($Name.Length + 1) -replace '^["'']', '' -replace '["'']$', '' }
    }
    "$value"
}

if ($args.Count -gt 0 -and $args[0] -eq '--set-commit') {
    $sha = "$($args[1])"
    if ($sha -cnotmatch '^[0-9a-f]{40}$') {
        Write-Host "Usage: .\syncEnvConfig.ps1 --set-commit <40-character commit hash>"
        exit 1
    }
    # Only a pinned value is replaced: with none, build.gradle alone decides and stays in charge.
    if ((Test-Path .env) -and (Select-String -Path .env -Pattern '^PIPED_EXTRACTOR_COMMIT=.+' -CaseSensitive -Quiet)) {
        Write-Text .env ([regex]::Replace((Read-Text .env), '(?m)^PIPED_EXTRACTOR_COMMIT=[^\r\n]*', "PIPED_EXTRACTOR_COMMIT=$sha"))
        Write-Host "  .env: PIPED_EXTRACTOR_COMMIT -> $(Short $sha)"
    }
    exit 0
}

Write-Host "=== Applying .env settings ==="

$commit = Get-Setting PIPED_EXTRACTOR_COMMIT
$proxy = Get-Setting PIPED_PROXY_URL
$changed = $false

if ($commit) {
    $gradle = Read-Text build.gradle
    $m = [regex]::Match($gradle, 'NewPipeExtractor:([0-9a-f]{7,40})')
    $current = if ($m.Success) { $m.Groups[1].Value } else { '' }
    if ($commit -cnotmatch '^[0-9a-f]{40}$') {
        Write-Host "  build.gradle: ignoring PIPED_EXTRACTOR_COMMIT '$commit' - not a 40-character hash"
    } elseif (-not $current) {
        Write-Host "  build.gradle: no NewPipeExtractor pin found - left unchanged"
    } elseif ($current -ne $commit) {
        Write-Text build.gradle ([regex]::Replace($gradle, '(NewPipeExtractor:)[0-9a-f]{7,40}', "`${1}$commit"))
        Write-Host "  build.gradle: NewPipeExtractor $(Short $current) -> $(Short $commit) (the image will rebuild)"
        Write-Host "                build.gradle now differs from git - commit it to keep the change."
        $changed = $true
    }
}

if ($proxy) {
    $current = ''
    if (Test-Path config.properties) {
        $line = Get-Content config.properties | Where-Object { $_ -cmatch '^PROXY_PART:' } | Select-Object -First 1
        if ($line) { $current = $line.Substring('PROXY_PART:'.Length).Trim() }
    }
    if ($proxy -cnotmatch '^https?://\S+$') {
        Write-Host "  config.properties: ignoring PIPED_PROXY_URL '$proxy' - not an http(s) URL"
    } elseif (-not (Test-Path config.properties)) {
        Write-Host "  config.properties: missing - run .\installPiped.ps1 first"
    } elseif ($current -ne $proxy) {
        # Replace the first PROXY_PART line (dropping any repeats), or append one.
        $text = Read-Text config.properties
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = [Collections.Generic.List[string]]($text -split '\r?\n')
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        $done = $false
        $out = foreach ($l in $lines) {
            if ($l -cmatch '^PROXY_PART:') {
                if (-not $done) { "PROXY_PART:$proxy"; $done = $true }
            } else { $l }
        }
        if (-not $done) { $out = @($out) + "PROXY_PART:$proxy" }
        Write-Text config.properties ((@($out) -join $nl) + $nl)
        $shown = if ($current) { $current } else { '(unset)' }
        Write-Host "  config.properties: PROXY_PART $shown -> $proxy"
        $changed = $true
    }
}

if (-not $changed) { Write-Host "  nothing to change" }
exit 0

} catch {
    # A missing command throws here instead of setting $LASTEXITCODE.
    Write-Host ($_ | Out-String)
    exit 1
} finally { Pop-Location }
