#!/bin/bash

# Smoke test for the things YouTube changes break: search, album/playlist contents, stream
# extraction (adaptive audio needs bg-helper's PoTokens) and reading audio past the first
# ~1 MB (some client URLs serve only that much, then 403). Exits non-zero if any fail.
#
#   ./checkPiped.sh                    against http://127.0.0.1:8090
#   PIPED_URL=http://host:8090 ./checkPiped.sh
#
# runPiped.sh runs it as `./runPiped.sh check`, and after every `./runPiped.sh bump`.

PIPED_URL="${PIPED_URL:-http://127.0.0.1:8090}"

if ! command -v jq >/dev/null 2>&1; then
    echo "checkPiped.sh needs jq (apt install jq)."
    exit 2
fi

FAILED=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=$((FAILED + 1)); }

# GET a Piped path; the JSON body on stdout, nothing on HTTP or network errors.
api() {
    curl -sf --max-time 60 "$PIPED_URL$1" 2>/dev/null
}

echo "=== Checking Piped at $PIPED_URL ==="

if ! curl -sf --max-time 5 "$PIPED_URL/healthcheck" >/dev/null 2>&1; then
    fail "healthcheck: Piped is not answering"
    exit 1
fi

# 1. Search. A well-known song, so an empty result means extraction broke, not bad luck.
SEARCH="$(api "/search?q=Coldplay%20Yellow&filter=music_songs")"
VIDEO_ID="$(jq -r '[.items[]? | select(.url | startswith("/watch")) | .url][0] // empty | sub("^/watch\\?v="; "")' <<<"$SEARCH" 2>/dev/null)"
if [ -n "$VIDEO_ID" ]; then
    pass "search: found songs (first: $VIDEO_ID)"
else
    fail "search: no songs for \"Coldplay Yellow\""
fi

# 2. Album contents (the lockupViewModel change once emptied every playlist and album).
ALBUMS="$(api "/search?q=Coldplay%20Parachutes&filter=music_albums")"
LIST_ID="$(jq -r '[.items[]? | select(.url | startswith("/playlist")) | .url][0] // empty | sub("^/playlist\\?list="; "")' <<<"$ALBUMS" 2>/dev/null)"
if [ -z "$LIST_ID" ]; then
    fail "album: search found no albums for \"Coldplay Parachutes\""
else
    TRACKS="$(api "/playlists/$LIST_ID" | jq -r '.relatedStreams | length' 2>/dev/null)"
    if [ "${TRACKS:-0}" -gt 0 ] 2>/dev/null; then
        pass "album: $TRACKS tracks in $LIST_ID"
    else
        fail "album: $LIST_ID came back with no tracks"
    fi
fi

# 3. Stream extraction, and 4. audio past the first megabyte.
if [ -n "$VIDEO_ID" ]; then
    STREAMS="$(api "/streams/$VIDEO_ID")"
    AUDIO_COUNT="$(jq -r '[.audioStreams[]? | select(.mimeType | startswith("audio/"))] | length' <<<"$STREAMS" 2>/dev/null)"
    if [ "${AUDIO_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        pass "streams: $AUDIO_COUNT audio formats for $VIDEO_ID"
        # The largest-bitrate audio, the one playback picks.
        AUDIO_URL="$(jq -r '[.audioStreams[] | select(.mimeType | startswith("audio/"))] | sort_by(-.bitrate) | .[0].url' <<<"$STREAMS")"
        CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -r 1048576-1049599 "$AUDIO_URL")"
        if [ "$CODE" = "206" ] || [ "$CODE" = "200" ]; then
            pass "audio: bytes past 1 MB load (HTTP $CODE)"
        else
            fail "audio: bytes past 1 MB answered HTTP $CODE (the stream URL works only for the start)"
        fi
    elif [ -n "$STREAMS" ]; then
        if [ "$(jq -r '.videoStreams | length' <<<"$STREAMS" 2>/dev/null)" -gt 0 ] 2>/dev/null; then
            fail "streams: no audio-only formats, only muxed video (bg-helper / PoToken trouble?)"
        else
            fail "streams: no formats at all for $VIDEO_ID"
        fi
    else
        # Piped's error body says why (e.g. "Sign in to confirm you're not a bot").
        REASON="$(curl -s --max-time 60 "$PIPED_URL/streams/$VIDEO_ID" | jq -r '.message // .error // empty' 2>/dev/null | head -c 160)"
        fail "streams: /streams/$VIDEO_ID failed${REASON:+: $REASON}"
    fi
else
    fail "streams: skipped, search found no song to try"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "All checks passed."
    exit 0
fi
echo "$FAILED check(s) failed."
exit 1
