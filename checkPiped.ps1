# PowerShell version of checkPiped.sh (no jq needed).
#
# Smoke test for the things YouTube changes break: search, album/playlist contents, stream
# extraction (adaptive audio needs bg-helper's PoTokens) and reading audio past the first
# ~1 MB (some client URLs serve only that much, then 403). Exits non-zero if any fail.
#
#   .\checkPiped.ps1                    against http://127.0.0.1:8090
#   $env:PIPED_URL='http://host:8090'; .\checkPiped.ps1
#
# runPiped.ps1 runs it as `.\runPiped.ps1 check`, and after every `.\runPiped.ps1 bump`.

$PipedUrl = if ($env:PIPED_URL) { $env:PIPED_URL } else { 'http://127.0.0.1:8090' }

Add-Type -AssemblyName System.Net.Http
# Windows PowerShell 5.1 still defaults to TLS 1.0, which the stream hosts refuse.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:Failed = 0
function Pass($Msg) { Write-Host "  ok    $Msg" }
function Fail($Msg) { Write-Host "  FAIL  $Msg"; $script:Failed++ }

# GET a URL; the status (0 on a network error) and the body. $From/$To ask for a byte range.
function Invoke-Http([string]$Url, [int]$TimeoutSec, $From = $null, $To = $null) {
    $client = New-Object Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Url)
        if ($null -ne $From) { $req.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new([long]$From, [long]$To) }
        $res = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        [pscustomobject]@{ Status = [int]$res.StatusCode; Ok = $res.IsSuccessStatusCode; Body = $body }
    } catch {
        [pscustomobject]@{ Status = 0; Ok = $false; Body = '' }
    } finally {
        $client.Dispose()
    }
}

# GET a Piped path; the parsed JSON, or $null on HTTP, network or parse errors.
function Get-Api([string]$Path) {
    $res = Invoke-Http "$PipedUrl$Path" 60
    if (-not $res.Ok) { return $null }
    try { $res.Body | ConvertFrom-Json } catch { $null }
}

Write-Host "=== Checking Piped at $PipedUrl ==="

if (-not (Invoke-Http "$PipedUrl/healthcheck" 5).Ok) {
    Fail "healthcheck: Piped is not answering"
    exit 1
}

# 1. Search. A well-known song, so an empty result means extraction broke, not bad luck.
$search = Get-Api '/search?q=Coldplay%20Yellow&filter=music_songs'
$videoId = ''
if ($search) {
    $first = @($search.items | Where-Object { $_.url -and $_.url.StartsWith('/watch') })[0]
    if ($first) { $videoId = $first.url -replace '^/watch\?v=', '' }
}
if ($videoId) {
    Pass "search: found songs (first: $videoId)"
} else {
    Fail 'search: no songs for "Coldplay Yellow"'
}

# 2. Album contents (the lockupViewModel change once emptied every playlist and album).
$albums = Get-Api '/search?q=Coldplay%20Parachutes&filter=music_albums'
$listId = ''
if ($albums) {
    $first = @($albums.items | Where-Object { $_.url -and $_.url.StartsWith('/playlist') })[0]
    if ($first) { $listId = $first.url -replace '^/playlist\?list=', '' }
}
if (-not $listId) {
    Fail 'album: search found no albums for "Coldplay Parachutes"'
} else {
    $playlist = Get-Api "/playlists/$listId"
    $tracks = if ($playlist) { @($playlist.relatedStreams).Count } else { 0 }
    if ($tracks -gt 0) {
        Pass "album: $tracks tracks in $listId"
    } else {
        Fail "album: $listId came back with no tracks"
    }
}

# 3. Stream extraction, and 4. audio past the first megabyte.
if ($videoId) {
    $streams = Get-Api "/streams/$videoId"
    $audio = @()
    if ($streams) { $audio = @($streams.audioStreams | Where-Object { $_.mimeType -and $_.mimeType.StartsWith('audio/') }) }
    if ($audio.Count -gt 0) {
        Pass "streams: $($audio.Count) audio formats for $videoId"
        # The largest-bitrate audio, the one playback picks.
        $audioUrl = ($audio | Sort-Object { [long]$_.bitrate } -Descending | Select-Object -First 1).url
        $code = (Invoke-Http $audioUrl 30 1048576 1049599).Status
        if ($code -eq 206 -or $code -eq 200) {
            Pass "audio: bytes past 1 MB load (HTTP $code)"
        } else {
            Fail "audio: bytes past 1 MB answered HTTP $code (the stream URL works only for the start)"
        }
    } elseif ($streams) {
        if (@($streams.videoStreams).Count -gt 0) {
            Fail "streams: no audio-only formats, only muxed video (bg-helper / PoToken trouble?)"
        } else {
            Fail "streams: no formats at all for $videoId"
        }
    } else {
        # Piped's error body says why (e.g. "Sign in to confirm you're not a bot").
        $reason = ''
        try {
            $err = (Invoke-Http "$PipedUrl/streams/$videoId" 60).Body | ConvertFrom-Json
            $reason = if ($err.message) { "$($err.message)" } elseif ($err.error) { "$($err.error)" } else { '' }
            if ($reason.Length -gt 160) { $reason = $reason.Substring(0, 160) }
        } catch { }
        $suffix = if ($reason) { ": $reason" } else { '' }
        Fail "streams: /streams/$videoId failed$suffix"
    }
} else {
    Fail "streams: skipped, search found no song to try"
}

if ($script:Failed -eq 0) {
    Write-Host "All checks passed."
    exit 0
}
Write-Host "$($script:Failed) check(s) failed."
exit 1
