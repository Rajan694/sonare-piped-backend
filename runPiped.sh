#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: ./runPiped.sh [up|down|logs|status|check|bump]"
    echo ""
    echo "  up       Start the stack and wait for the API to answer (default)"
    echo "  down     Stop and remove the containers"
    echo "  logs     Follow the piped container logs"
    echo "  status   Show container state and whether the API is healthy"
    echo "  check    Smoke-test search, albums, streams and audio (checkPiped.sh)"
    echo "  bump [<commit>]"
    echo "           Move NewPipeExtractor to <commit> (default: the newest on its dev"
    echo "           branch), rebuild, check, and roll back if the check fails."
    echo "  bump --bg-helper"
    echo "           Pin bg-helper to its newest image, check, roll back on failure"
    echo "           (for \"not a bot\" / PoToken breakage)."
    echo ""
    echo "Ports: piped 8090, piped-proxy 8091. bg-helper and postgres stay internal."
    exit 1
}

IMAGE=sonare-piped:local
# The last image that started healthy. Building needs JitPack (the extractor) and Docker
# Hub; if the image is gone (pruned, new machine) this restores it without either.
BACKUP_DIR="$SCRIPT_DIR/image-backup"
BACKUP="$BACKUP_DIR/sonare-piped.tar.gz"
EXTRACTOR_REPO=https://github.com/TeamNewPipe/NewPipeExtractor
BG_HELPER_REPO=1337kavin/bg-helper-server

# What goes into the piped image. Only a change here rebuilds it: even a fully cached build
# asks Docker Hub about the eclipse-temurin base images, and with no network (or DNS down)
# that fails after a long timeout and takes the whole start with it.
src_hash() {
    find src gradle build.gradle settings.gradle gradlew VERSION Dockerfile .dockerignore \
        hotspot-entrypoint.sh docker-healthcheck.sh -type f -print0 \
        | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16
}

built_hash() {
    docker image inspect -f '{{index .Config.Labels "sonare.src-hash"}}' "$IMAGE" 2>/dev/null
}

# Saves the image once it has started healthy, only when it differs from the saved one.
backup_image() {
    local id
    id="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)" || return 0
    [ "$id" = "$(cat "$BACKUP_DIR/image-id" 2>/dev/null)" ] && return 0
    echo "Saving this build to image-backup/ (a fallback if jitpack.io or Docker Hub is down)..."
    mkdir -p "$BACKUP_DIR"
    if docker save "$IMAGE" | gzip -1 > "$BACKUP.tmp"; then
        mv "$BACKUP.tmp" "$BACKUP" && echo "$id" > "$BACKUP_DIR/image-id"
    else
        rm -f "$BACKUP.tmp"
        echo "WARNING: could not save the image backup."
    fi
}

wait_healthy() {
    for i in $(seq 1 30); do
        curl -sf --max-time 3 http://127.0.0.1:8090/healthcheck >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

extractor_pin() {
    grep -oE 'NewPipeExtractor:[0-9a-f]{7,40}' build.gradle | head -1 | cut -d: -f2
}

set_extractor_pin() {
    sed -i -E "s/(NewPipeExtractor:)[0-9a-f]{7,40}/\1$1/" build.gradle
}

bg_helper_pin() {
    grep -oE "$BG_HELPER_REPO@sha256:[0-9a-f]{64}" docker-compose.yml | head -1
}

# Moves NewPipeExtractor to $1, rebuilds and checks; on failure puts the old commit and
# the backed-up image back. Returns non-zero if it rolled back.
bump_extractor() {
    local new="$1" old
    old="$(extractor_pin)"
    if [ -z "$new" ]; then
        new="$(git ls-remote "$EXTRACTOR_REPO" refs/heads/dev 2>/dev/null | cut -f1)"
        if [ -z "$new" ]; then
            echo "Could not read the newest commit from $EXTRACTOR_REPO (is GitHub reachable?)."
            return 1
        fi
    fi
    echo "=== NewPipeExtractor ${old:0:12} -> ${new:0:12} ==="
    if [ "$new" = "$old" ]; then
        echo "Already on that commit."
        return 0
    fi

    # Rolling back needs a backup of the build that is running now, from this source.
    if [ "$(built_hash)" != "$(src_hash)" ]; then
        echo "The current image wasn't built from this source, so there's nothing safe to roll"
        echo "back to. Run ./runPiped.sh up first, then bump."
        return 1
    fi
    backup_image

    set_extractor_pin "$new"
    export PIPED_SRC_HASH="$(src_hash)"
    echo "Building (Gradle fetches the extractor from jitpack.io; the first build of a commit"
    echo "can take a few minutes while JitPack compiles it)..."
    if ! docker compose build piped; then
        echo "Build failed - keeping ${old:0:12}. The running Piped is untouched."
        set_extractor_pin "$old"
        return 1
    fi
    docker compose up -d --no-build piped || return 1

    if wait_healthy && ./checkPiped.sh; then
        ./syncEnvConfig.sh --set-commit "$new"
        backup_image
        echo "NewPipeExtractor is now ${new:0:12}. Commit build.gradle to keep it."
        return 0
    fi

    echo "=== Rolling back to ${old:0:12} ==="
    local failed_id
    failed_id="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)"
    set_extractor_pin "$old"
    export PIPED_SRC_HASH="$(src_hash)"
    gunzip -c "$BACKUP" | docker load || { echo "Could not load $BACKUP."; return 1; }
    # The failed build is left untagged by the load; nothing needs it.
    [ -n "$failed_id" ] && docker rmi "$failed_id" >/dev/null 2>&1
    docker compose up -d --no-build piped && wait_healthy \
        && echo "Rolled back: Piped runs ${old:0:12} again." \
        || echo "Rolled back the files, but Piped isn't healthy - check ./runPiped.sh logs."
    return 1
}

# Pins bg-helper to whatever :latest is now, checks, and restores the old pin on failure.
bump_bg_helper() {
    local old new
    old="$(bg_helper_pin)"
    echo "=== bg-helper ==="
    docker pull -q "$BG_HELPER_REPO:latest" >/dev/null || { echo "Could not pull $BG_HELPER_REPO:latest."; return 1; }
    new="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$BG_HELPER_REPO:latest" \
        | grep -m1 "^$BG_HELPER_REPO@")"
    echo "${old#*@} -> ${new#*@}"
    if [ "$new" = "$old" ]; then
        echo "Already on the newest image."
        return 0
    fi
    sed -i "s|$old|$new|" docker-compose.yml
    docker compose up -d --no-build bg-helper || return 1
    sleep 5
    if ./checkPiped.sh; then
        echo "bg-helper is now pinned to ${new#*@}. Commit docker-compose.yml to keep it."
        return 0
    fi
    echo "=== Rolling back bg-helper ==="
    sed -i "s|$new|$old|" docker-compose.yml
    docker compose up -d --no-build bg-helper
    return 1
}

MODE="${1:-up}"

case "$MODE" in
    down)
        exec docker compose down
        ;;
    logs)
        exec docker compose logs -f piped
        ;;
    status)
        docker compose ps
        if curl -sf --max-time 3 http://127.0.0.1:8090/healthcheck >/dev/null 2>&1; then
            echo "API: healthy on 8090"
        else
            echo "API: not answering on 8090"
        fi
        exit 0
        ;;
    check)
        exec ./checkPiped.sh
        ;;
    bump)
        shift
        COMMIT=""
        BG_HELPER=0
        for arg in "$@"; do
            case "$arg" in
                --bg-helper) BG_HELPER=1 ;;
                *)
                    [[ "$arg" =~ ^[0-9a-f]{40}$ ]] || { echo "Not a 40-character commit hash: $arg"; usage; }
                    COMMIT="$arg"
                    ;;
            esac
        done
        if ! curl -sf --max-time 3 http://127.0.0.1:8090/healthcheck >/dev/null 2>&1; then
            echo "Piped isn't running - start it with ./runPiped.sh up first."
            exit 1
        fi
        STATUS=0
        if [ "$BG_HELPER" = "0" ] || [ -n "$COMMIT" ]; then
            bump_extractor "$COMMIT" || STATUS=1
        fi
        if [ "$BG_HELPER" = "1" ]; then
            bump_bg_helper || STATUS=1
        fi
        exit $STATUS
        ;;
    up) ;;
    *) usage ;;
esac

if [ ! -f config.properties ]; then
    echo "config.properties missing - run ./installPiped.sh first."
    exit 1
fi

# Settings in .env: the extractor commit (build.gradle, so it rebuilds below) and the proxy
# URL (config.properties, which Piped only reads at startup).
CONFIG_BEFORE="$(sha256sum config.properties)"
./syncEnvConfig.sh
[ "$CONFIG_BEFORE" != "$(sha256sum config.properties)" ] && CONFIG_CHANGED=1 || CONFIG_CHANGED=0
echo ""

# 8091 is the proxy port. A stale compose project from elsewhere holding it is a
# common cause of a confusing bind failure, so name that possibility up front.
if ss -ltn 2>/dev/null | grep -q ':8091 '; then
    if ! docker compose ps --status running 2>/dev/null | grep -q piped-proxy; then
        echo "Port 8091 is in use by something that is not this stack."
        echo "  Another Piped compose project may be running - stop it first."
        exit 1
    fi
fi

echo "=== Starting Piped (docker) ==="
# docker-compose.yml stamps the image with this, so the next start can compare.
export PIPED_SRC_HASH="$(src_hash)"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1 && [ -f "$BACKUP" ]; then
    echo "No $IMAGE image - restoring the last good build from image-backup/"
    gunzip -c "$BACKUP" | docker load || echo "WARNING: could not load $BACKUP"
fi
if BUILT_HASH="$(built_hash)"; then
    HAVE_IMAGE=1
else
    HAVE_IMAGE=0
fi

if [ "$HAVE_IMAGE" = "1" ] && [ "$BUILT_HASH" = "$PIPED_SRC_HASH" ]; then
    docker compose up -d --no-build || exit 1
elif ! docker compose up -d --build; then
    # The first build takes a few minutes (Gradle) and needs Docker Hub.
    if [ "$HAVE_IMAGE" != "1" ]; then
        echo "Could not build $IMAGE, and there is no earlier build to fall back to."
        echo "The first build needs Docker Hub and jitpack.io - check the network and DNS, then retry."
        exit 1
    fi
    echo "WARNING: rebuilding $IMAGE failed (are Docker Hub and jitpack.io reachable?)."
    echo "  Starting the previous build, which does not have your latest changes to the Piped source."
    docker compose up -d --no-build || exit 1
fi

if [ "$CONFIG_CHANGED" = "1" ]; then
    echo "config.properties changed - restarting piped to load it."
    docker compose restart piped || exit 1
fi

echo "=== Waiting for the API ==="
if wait_healthy; then
    echo "Piped is healthy on http://127.0.0.1:8090"
    # Without bg-helper supplying PoTokens, YouTube returns no adaptive audio
    # formats and playback silently falls back to a muxed video stream.
    if ! docker compose ps --status running 2>/dev/null | grep -q bg-helper; then
        echo "WARNING: bg-helper is not running - expect empty audioStreams."
    fi
    backup_image
    exit 0
fi

echo "Piped did not become healthy in 60s. Check: ./runPiped.sh logs"
exit 1
