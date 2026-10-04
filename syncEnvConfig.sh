#!/bin/bash

# Copies the Piped settings in .env (next to docker-compose.yml, see .env.example) into the
# files Piped is built and started from:
#
#   PIPED_EXTRACTOR_COMMIT -> the NewPipeExtractor pin in build.gradle. That changes the
#                             source hash, so ./runPiped.sh rebuilds the image.
#   PIPED_PROXY_URL        -> PROXY_PART in config.properties, read when Piped starts.
#
# A setting that is empty or missing leaves its file alone. An exported variable wins over
# .env. This never fails the caller.
#
#   ./syncEnvConfig.sh --set-commit <sha>
#       The other direction, for `./runPiped.sh bump`: if .env pins a commit, replace it
#       with <sha>, so the next start doesn't put the old one back.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# The value of $1 from the environment, else from .env (quotes stripped).
setting() {
    local value="${!1:-}"
    if [ -z "$value" ] && [ -f .env ]; then
        value="$(grep -E "^$1=" .env | tail -1 | cut -d= -f2- | sed -E "s/^[\"']//; s/[\"']$//")"
    fi
    printf '%s' "$value"
}

if [ "${1:-}" = "--set-commit" ]; then
    SHA="${2:-}"
    if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Usage: ./syncEnvConfig.sh --set-commit <40-character commit hash>"
        exit 1
    fi
    # Only a pinned value is replaced: with none, build.gradle alone decides and stays in charge.
    if [ -f .env ] && grep -qE '^PIPED_EXTRACTOR_COMMIT=.+' .env; then
        sed -i -E "s/^PIPED_EXTRACTOR_COMMIT=.*/PIPED_EXTRACTOR_COMMIT=$SHA/" .env
        echo "  .env: PIPED_EXTRACTOR_COMMIT -> ${SHA:0:12}"
    fi
    exit 0
fi

echo "=== Applying .env settings ==="

COMMIT="$(setting PIPED_EXTRACTOR_COMMIT)"
PROXY="$(setting PIPED_PROXY_URL)"
CHANGED=0

if [ -n "$COMMIT" ]; then
    CURRENT="$(grep -oE 'NewPipeExtractor:[0-9a-f]{7,40}' build.gradle | head -1 | cut -d: -f2)"
    if ! [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
        echo "  build.gradle: ignoring PIPED_EXTRACTOR_COMMIT '$COMMIT' - not a 40-character hash"
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
        echo "  config.properties: ignoring PIPED_PROXY_URL '$PROXY' - not an http(s) URL"
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
