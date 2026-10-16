# PowerShell version of funnel.sh: publishes this machine's Piped through Tailscale Funnel, for
# a Sonare backend hosted elsewhere (Render). YouTube then sees this machine's home IP instead
# of a datacenter's.
#
#   https://<machine>.<tailnet>.ts.net        -> gate :8092 -> piped        (the API)
#   https://<machine>.<tailnet>.ts.net:8443   -> gate :8093 -> piped-proxy  (the media)
#
# The gate (docker-compose.yml, profile "funnel") passes only requests carrying PIPED_KEY,
# which the backend sends as X-Sonare-Key. Unlike funnel.sh this uses the regular Tailscale
# app (installed with winget), which runs as a Windows service and puts the whole machine on
# the tailnet; there is no userspace mode on Windows.

$ScriptDir = $PSScriptRoot
Push-Location $ScriptDir
$ProgressPreference = 'SilentlyContinue'
try {

function Show-Usage {
    Write-Host "Usage: .\funnel.ps1 <install|up|down|status|check>"
    Write-Host ""
    Write-Host "  install  Install Tailscale (winget) and sign this machine in (opens a login link)"
    Write-Host "  up       Generate PIPED_KEY if needed, point Piped's proxy URL at the Funnel address,"
    Write-Host "           start Piped with the gate, publish it with Funnel, check every relay"
    Write-Host "           address, and register the $TaskName scheduled task"
    Write-Host "  down     Stop publishing, stop the gate, remove the task, and put Piped's proxy URL"
    Write-Host "           back to $LocalProxy"
    Write-Host "  status   Tailscale, Funnel, gate and task state, and each relay address's answer"
    Write-Host "  check    Check each relay address and reconnect Tailscale if one gets no answer"
    Write-Host "           (what the task runs)"
    exit 1
}

$HostnameTs = 'sonare-piped'
$LocalProxy = 'http://localhost:8091'
# Runs `.\funnel.ps1 check` every 5 minutes while Funnel is on (registered by `up`).
$TaskName = 'sonare-funnel-check'
$StateDir = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $HOME }) 'sonare-tailscale'
# When `check` last reconnected Tailscale; it waits 30 minutes before doing it again.
$LastHeal = Join-Path $StateDir 'last-heal'
# What the task's runs printed (a scheduled task has no console to show it).
$CheckLog = Join-Path $StateDir 'funnel-check.log'
$script:LogFile = $null
# curl.exe ships with Windows 10 and later; `curl` alone is Invoke-WebRequest in Windows PowerShell.
$Curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }
$NullOut = if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { 'NUL' } else { '/dev/null' }
$script:Ts = ''
$script:Dns = ''

function Read-Text($Path) { [IO.File]::ReadAllText((Resolve-Path $Path).ProviderPath) }
function Write-Text($Path, $Text) {
    [IO.File]::WriteAllText((Resolve-Path $Path).ProviderPath, $Text, (New-Object Text.UTF8Encoding $false))
}

# Printed, and also appended to $CheckLog when the scheduled task runs `check`.
function Say([string]$Text) {
    Write-Host $Text
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value "$(Get-Date -Format s)  $Text" }
}

# KEY=value in .env: replaced when present, appended otherwise.
function Set-EnvValue($Name, $Value) {
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    $text = Read-Text .env
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $pattern = "(?m)^$([regex]::Escape($Name))=[^\r\n]*"
    if ($text -cmatch $pattern) {
        $text = [regex]::Replace($text, $pattern, "$Name=$($Value.Replace('$', '$$'))")
    } else {
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += $nl }
        $text += "$Name=$Value$nl"
    }
    Write-Text .env $text
}

function Get-EnvValue($Name) {
    if (-not (Test-Path .env)) { return '' }
    $line = Get-Content .env | Where-Object { $_ -cmatch "^$Name=" } | Select-Object -Last 1
    if ($line) { $line.Substring($Name.Length + 1).Replace('"', '') } else { '' }
}

function New-Key {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Find-Tailscale {
    $cmd = Get-Command tailscale.exe, tailscale -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    # winget doesn't update this session's PATH.
    if ($env:ProgramFiles) {
        $path = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
        if (Test-Path $path) { return $path }
    }
    ''
}

function Get-TsStatus {
    try { (& $script:Ts status --json 2>$null | Out-String) | ConvertFrom-Json } catch { $null }
}

function Test-TsRunning {
    $status = Get-TsStatus
    $status -and $status.BackendState -eq 'Running'
}

function Get-DnsName { (Get-TsStatus).Self.DNSName.TrimEnd('.') }

function Assert-Tailscale {
    $script:Ts = Find-Tailscale
    if (-not $script:Ts) {
        Write-Host "Tailscale isn't installed - run .\funnel.ps1 install first."
        exit 1
    }
    if (-not (Test-TsRunning)) {
        try { Start-Service -Name Tailscale -ErrorAction Stop } catch { }
        Start-Sleep -Seconds 3
        if (-not (Test-TsRunning)) {
            Write-Host "Tailscale isn't running or this machine isn't signed in."
            Write-Host "  Open the Tailscale app (or .\funnel.ps1 install) and sign in."
            exit 1
        }
    }
}

# The Funnel name resolves to several relay (ingress) addresses, and each client uses
# whichever one its resolver hands out. One can lose its link to this machine while the
# others work: on 2026-10-15 one of two reset every connection, so Render got ECONNRESET
# while a check from here passed. So each address is checked on its own. A public resolver
# is asked too: with MagicDNS this machine resolves its own name to its tailnet address
# (100.64.0.0/10), which isn't a relay and is left out.
function Get-RelayIps($Name) {
    $ips = @()
    try {
        $ips += [Net.Dns]::GetHostAddresses($Name) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
    } catch { }
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            $ips += Resolve-DnsName $Name -Type A -Server 1.1.1.1 -DnsOnly -ErrorAction Stop |
                Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }
        } catch { }
    }
    @($ips | Where-Object { $_ -match '^\d+(\.\d+){3}$' -and $_ -notmatch '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' } |
        Sort-Object -Unique)
}

# HTTP status of https://$Dns:<port><path> through relay <ip>; 000 is no HTTP answer at all.
function Get-RelayCode($Ip, $Port, $Path, [string[]]$Extra = @()) {
    $curlArgs = @('-s', '-o', $NullOut, '-w', '%{http_code}', '--max-time', '20',
        '--resolve', "$($script:Dns):${Port}:$Ip") + $Extra + "https://$($script:Dns):$Port$Path"
    $code = & $Curl @curlArgs 2>$null
    if ("$code" -match '^\d{3}$') { "$code" } else { '000' }
}

# One pass over the relay addresses. Sets Relays (how many), Dead (no answer on a port: that
# relay can't reach this machine), Wrong (answered, but not 403 without the key and 200 with
# it - the gate or Piped, not the relay) and Report (a line per address).
function Test-Relays($Key) {
    $script:Relays = 0; $script:Dead = 0; $script:Wrong = 0; $script:Report = @()
    foreach ($ip in (Get-RelayIps $script:Dns)) {
        $script:Relays++
        $apiNo = Get-RelayCode $ip 443 '/healthcheck'
        $apiKey = Get-RelayCode $ip 443 '/healthcheck' @('-H', "X-Sonare-Key: $Key")
        $mediaNo = Get-RelayCode $ip 8443 '/'
        if ($apiNo -eq '000' -or $apiKey -eq '000' -or $mediaNo -eq '000') {
            $script:Dead++; $verdict = 'NO ANSWER'
        } elseif ($apiNo -ne '403' -or $apiKey -ne '200' -or $mediaNo -ne '403') {
            $script:Wrong++; $verdict = 'unexpected'
        } else {
            $verdict = 'ok'
        }
        $script:Report += '  {0,-15}  API: {1} without the key, {2} with it   media: {3} without   {4}' -f `
            $ip, $apiNo, $apiKey, $mediaNo, $verdict
    }
    if ($script:Relays -eq 0) { $script:Report = @("  $($script:Dns) doesn't resolve to any IPv4 address (yet).") }
}

function Test-RelaysOk { $script:Relays -gt 0 -and $script:Dead -eq 0 -and $script:Wrong -eq 0 }

# Test-Relays until every address is fine, for up to <seconds>. False if they aren't.
function Wait-Relays($Key, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        Test-Relays $Key
        if (Test-RelaysOk) { return $true }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 10
    }
}

function Show-Report { foreach ($line in $script:Report) { Say $line } }

# Restarting the service brings a dead relay back (it reconnects to the relays), but needs an
# elevated prompt, which the scheduled task isn't. Then `tailscale down` and `up`, which drops
# and reopens the connection to Tailscale's servers the same way; the Funnel settings stay.
function Restart-Tailscale {
    try {
        Restart-Service -Name Tailscale -ErrorAction Stop
        return
    } catch { }
    & $script:Ts down 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & $script:Ts up 2>&1 | Out-Null
}

# Checks every relay address, waiting up to <seconds> for them to come good (a new certificate
# takes a minute). If a relay still gets no answer while the gate does answer here, Tailscale
# is restarted. <cooldown> seconds since the last such restart skips it, so a relay that stays
# broken doesn't restart it every few minutes.
function Invoke-Heal($Key, [int]$Wait, [int]$Cooldown = 0) {
    $null = Wait-Relays $Key $Wait
    if ($script:Relays -gt 0 -and $script:Dead -gt 0) {
        $gate = & $Curl -s -o $NullOut -w '%{http_code}' --max-time 10 http://127.0.0.1:8092/healthcheck 2>$null
        $last = 0
        if (Test-Path $LastHeal) { [long]::TryParse((Get-Content $LastHeal -Raw).Trim(), [ref]$last) | Out-Null }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ("$gate" -ne '403') {
            Show-Report
            Say "The gate isn't answering on 127.0.0.1:8092 ($gate), so restarting Tailscale won't help."
            Say "  Start Piped and the gate with .\runPiped.ps1 up (COMPOSE_PROFILES=funnel in .env)."
            return $false
        } elseif ($now - $last -lt $Cooldown) {
            Show-Report
            Say "$($script:Dead) of $($script:Relays) relay addresses get no answer; Tailscale was restarted less than $([int]($Cooldown / 60)) minutes ago, so not again yet."
            return $false
        }
        Show-Report
        Say "$($script:Dead) of $($script:Relays) relay addresses get no answer - restarting Tailscale so it reconnects to them."
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        Set-Content -LiteralPath $LastHeal -Value $now
        Restart-Tailscale
        Start-Sleep -Seconds 5
        $null = Wait-Relays $Key 120
    }
    Show-Report
    if (Test-RelaysOk) {
        Say "Every relay address answers as it should (403 without the key, 200 with it)."
        return $true
    }
    if ($script:Dead -gt 0) { Say "Still no answer from $($script:Dead) relay address(es); clients sent there get ECONNRESET." }
    if ($script:Wrong -gt 0) { Say "Unexpected answers: check the gate's key (PIPED_KEY in .env) and Piped (.\runPiped.ps1 check)." }
    $false
}

# The scheduled task runs as you, only while you're signed in to Windows (no stored password).
function Register-CheckTask {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) { return $false }
    $shell = (Get-Process -Id $PID).Path
    $action = New-ScheduledTaskAction -Execute $shell `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" check"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
        -Description "Check each relay address of Sonare's Piped Funnel, restart Tailscale if one is dead" | Out-Null
    $true
}

function Unregister-CheckTask {
    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Invoke-Install {
    $script:Ts = Find-Tailscale
    if (-not $script:Ts) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Write-Host "winget not found - install Tailscale from https://tailscale.com/download/windows,"
            Write-Host "then run .\funnel.ps1 install again."
            exit 1
        }
        Write-Host "=== Installing Tailscale (winget) ==="
        winget install --id Tailscale.Tailscale --exact
        $script:Ts = Find-Tailscale
        if (-not $script:Ts) {
            Write-Host "Tailscale didn't install - install it from https://tailscale.com/download/windows."
            exit 1
        }
    }
    & $script:Ts version | Select-Object -First 1 | Out-Host

    Write-Host ""
    if (Test-TsRunning) {
        # Already on a tailnet: its name works as well as sonare-piped, and `tailscale up` with
        # different flags would refuse rather than quietly change this machine's settings.
        Write-Host "Already signed in as $(Get-DnsName) - keeping that name."
    } else {
        # --unattended keeps Tailscale (and so Funnel) running when you sign out of Windows.
        Write-Host "Signing this machine in to Tailscale as '$HostnameTs' (open the link it prints)."
        & $script:Ts up --unattended "--hostname=$HostnameTs"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        Write-Host ""
        Write-Host "Signed in as $(Get-DnsName)."
    }
    Write-Host "Next: .\funnel.ps1 up"
}

function Invoke-Up {
    Assert-Tailscale
    $dns = Get-DnsName
    $script:Dns = $dns

    $key = Get-EnvValue PIPED_KEY
    if (-not $key) {
        $key = New-Key
        Set-EnvValue PIPED_KEY $key
        Write-Host "Generated PIPED_KEY in .env"
    }
    Set-EnvValue COMPOSE_PROFILES funnel
    Set-EnvValue PIPED_PROXY_URL "https://${dns}:8443"

    # Syncs PROXY_PART into config.properties, starts the gate, restarts piped on a change.
    & (Join-Path $ScriptDir 'runPiped.ps1') up
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host ""
    Write-Host "=== Publishing with Tailscale Funnel ==="
    & $script:Ts funnel --bg --https=443 http://127.0.0.1:8092 | Out-Host
    $ok = $LASTEXITCODE -eq 0
    if ($ok) {
        & $script:Ts funnel --bg --https=8443 http://127.0.0.1:8093 | Out-Host
        $ok = $LASTEXITCODE -eq 0
    }
    if (-not $ok) {
        Write-Host ""
        Write-Host "Funnel was refused. The first time, HTTPS certificates and Funnel have to be allowed"
        Write-Host "for the tailnet: open the link above (or https://login.tailscale.com/admin/dns and"
        Write-Host "https://login.tailscale.com/admin/acls), then run .\funnel.ps1 up again."
        exit 1
    }

    Write-Host ""
    Write-Host "=== Checking each relay address from the internet side (the first certificate can take a minute) ==="
    $null = Invoke-Heal $key 90
    if (Register-CheckTask) {
        Write-Host "The $TaskName task checks them every 5 minutes from now on, while you're signed in"
        Write-Host "to Windows (log: $CheckLog)."
    }

    Write-Host ""
    Write-Host "Piped is published. On the hosted backend (Render's environment) set:"
    Write-Host "  PIPED_API_URL=https://$dns"
    Write-Host "  PIPED_KEY=<PIPED_KEY from sonare-piped-backend\.env>"
    Write-Host "(and the admin page's Piped URL, if one is saved there)."
    Write-Host "A backend on this machine keeps PIPED_API_URL=http://localhost:8090 and adds"
    Write-Host "  PIPED_LOCAL_PROXY_URL=http://localhost:8091"
    Write-Host "so it plays the Funnel stream urls from the local proxy."
}

function Invoke-Down {
    Unregister-CheckTask
    $script:Ts = Find-Tailscale
    if ($script:Ts -and (Test-TsRunning)) {
        & $script:Ts funnel --https=443 off *> $null
        & $script:Ts funnel --https=8443 off *> $null
        Write-Host "Funnel stopped."
    }
    docker compose --profile funnel stop gate *> $null
    docker compose --profile funnel rm -f gate *> $null
    Set-EnvValue COMPOSE_PROFILES ''
    Set-EnvValue PIPED_PROXY_URL $LocalProxy
    & (Join-Path $ScriptDir 'runPiped.ps1') up
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Host "Piped is local only again ($LocalProxy). A backend on this machine needs no change:"
    Write-Host "its stream urls already point at the local proxy, PIPED_LOCAL_PROXY_URL or not."
}

function Invoke-Status {
    $script:Ts = Find-Tailscale
    $running = $false
    if (-not $script:Ts) {
        Write-Host "Tailscale: not installed (.\funnel.ps1 install)"
    } else {
        $service = if (Get-Command Get-Service -ErrorAction SilentlyContinue) { Get-Service -Name Tailscale -ErrorAction SilentlyContinue }
        if ($service) { Write-Host "Tailscale service: $($service.Status)" }
        & $script:Ts status 2>&1 | Select-Object -First 5 | Out-Host
        Write-Host ""
        & $script:Ts funnel status 2>&1 | Out-Host
        $running = Test-TsRunning
    }
    Write-Host ""
    docker compose --profile funnel ps gate 2>$null | Out-Host
    Write-Host "PIPED_PROXY_URL=$(Get-EnvValue PIPED_PROXY_URL)"
    Write-Host ""
    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host "$TaskName task: $(if ($task) { $task.State } else { 'not registered' })"
    }
    $key = Get-EnvValue PIPED_KEY
    if ($key -and $running) {
        $script:Dns = Get-DnsName
        Write-Host "Relay addresses of $($script:Dns):"
        Test-Relays $key
        foreach ($line in $script:Report) { Write-Host $line }
    }
}

# What the task runs: re-checks a dead relay for 30 s before restarting Tailscale (a single
# miss can be a blip), and restarts it at most every 30 minutes.
function Invoke-Check {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    if (Test-Path $CheckLog) {
        $old = @(Get-Content $CheckLog)
        if ($old.Count -gt 2000) { Set-Content -LiteralPath $CheckLog -Value $old[-1000..-1] }
    }
    $script:LogFile = $CheckLog
    $key = Get-EnvValue PIPED_KEY
    if (-not $key) {
        Say "No PIPED_KEY in .env - Funnel isn't set up (.\funnel.ps1 up)."
        exit 1
    }
    Assert-Tailscale
    $script:Dns = Get-DnsName
    if (Invoke-Heal $key 30 1800) { exit 0 } else { exit 1 }
}

$Mode = if ($args.Count -gt 0) { "$($args[0])" } else { '' }
switch ($Mode) {
    'install' { Invoke-Install }
    'up' { Invoke-Up }
    'down' { Invoke-Down }
    'status' { Invoke-Status }
    'check' { Invoke-Check }
    default { Show-Usage }
}
exit 0

} catch {
    # A missing command throws here instead of setting $LASTEXITCODE.
    Write-Host ($_ | Out-String)
    exit 1
} finally { Pop-Location }
