#!/bin/bash

# Copies the Piped settings saved on the Sonare admin page (/admin > Configuration, stored in
# the backend's system_configuration table) into this directory, so the next build/start
# uses them:
#
#   piped.extractorCommit -> the NewPipeExtractor pin in build.gradle. That changes the
#                            source hash, so ./runPiped.sh rebuilds the image.
#   piped.proxyUrl        -> PROXY_PART in config.properties, read when Piped starts.
#
# A setting left empty on the admin page leaves its file alone. This never fails the
# caller: without psql or the database it says so and changes nothing.
#
# The database comes from SONARE_DATABASE_URL, or DATABASE_URL in ../sonare-backend/.env.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Applying admin settings ==="

DB_URL="${SONARE_DATABASE_URL:-}"
if [ -z "$DB_URL" ] && [ -f ../sonare-backend/.env ]; then
    DB_URL="$(grep -E '^DATABASE_URL=' ../sonare-backend/.env | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']$//")"
fi
if [ -z "$DB_URL" ]; then
    echo "  skipped: no DATABASE_URL (set SONARE_DATABASE_URL or ../sonare-backend/.env)"
    exit 0
fi
if ! command -v psql >/dev/null 2>&1; then
    echo "  skipped: psql is not installed"
    exit 0
fi

# key<TAB>value, for settings that have a value. The value column is jsonb (a JSON string).
if ! ROWS="$(psql "$DB_URL" -X -q -t -A -F $'\t' -v ON_ERROR_STOP=1 -c \
    "SELECT key, value #>> '{}' FROM system_configuration
     WHERE key IN ('piped.extractorCommit', 'piped.proxyUrl') AND coalesce(value #>> '{}', '') <> ''" 2>&1)"; then
    echo "  skipped: could not read system_configuration ($(echo "$ROWS" | head -1))"
    exit 0
fi

setting() {
    printf '%s\n' "$ROWS" | awk -F '\t' -v k="$1" '$1 == k { print $2; exit }'
}

COMMIT="$(setting piped.extractorCommit)"
PROXY="$(setting piped.proxyUrl)"
CHANGED=0

if [ -n "$COMMIT" ]; then
    CURRENT="$(grep -oE 'NewPipeExtractor:[0-9a-f]{7,40}' build.gradle | head -1 | cut -d: -f2)"
    if ! [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
        echo "  build.gradle: ignoring saved commit '$COMMIT' - not a 40-character hash"
    elif [ -z "$CURRENT" ]; then
        echo "  build.gradle: no NewPipeExtractor pin found - left unchanged"
    elif [ "$CURRENT" != "$COMMIT" ]; then
        sed -i -E "s/(NewPipeExtractor:)[0-9a-f]{7,40}/\1$COMMIT/" build.gradle
        echo "  build.gradle: NewPipeExtractor ${CURRENT:0:12} -> ${COMMIT:0:12} (the image will rebuild)"
        echo "                build.gradle now differs from git - commit it to keep the change."
        CHANGED=1
    fi
fi

if [ -n "$PROXY" ]; then
    CURRENT="$(grep -E '^PROXY_PART:' config.properties 2>/dev/null | head -1 | cut -d: -f2- | xargs)"
    if ! [[ "$PROXY" =~ ^https?://[^[:space:]]+$ ]]; then
        echo "  config.properties: ignoring saved proxy URL '$PROXY' - not an http(s) URL"
    elif [ ! -f config.properties ]; then
        echo "  config.properties: missing - run ./installPiped.sh first"
    elif [ "$CURRENT" != "$PROXY" ]; then
        # ENVIRON, not -v: awk would read backslashes in the value as escapes. Written back
        # in place, keeping the inode docker has bind-mounted.
        TMP="$(mktemp)"
        NEW="$PROXY" awk '/^PROXY_PART:/ { if (!done) print "PROXY_PART:" ENVIRON["NEW"]; done = 1; next } { print }
            END { if (!done) print "PROXY_PART:" ENVIRON["NEW"] }' config.properties > "$TMP" \
            && cat "$TMP" > config.properties
        rm -f "$TMP"
        echo "  config.properties: PROXY_PART ${CURRENT:-(unset)} -> $PROXY"
        CHANGED=1
    fi
fi

[ "$CHANGED" = "0" ] && echo "  nothing to change"
exit 0
