#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: ./runPiped.sh [up|down|logs|status]"
    echo ""
    echo "  up       Start the stack and wait for the API to answer (default)"
    echo "  down     Stop and remove the containers"
    echo "  logs     Follow the piped container logs"
    echo "  status   Show container state and whether the API is healthy"
    echo ""
    echo "Ports: piped 8090, piped-proxy 8091. bg-helper and postgres stay internal."
    exit 1
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
    up) ;;
    *) usage ;;
esac

if [ ! -f config.properties ]; then
    echo "config.properties missing - run ./installPiped.sh first."
    exit 1
fi

# Settings saved on the Sonare admin page: the extractor commit (build.gradle, so it rebuilds
# below) and the proxy URL (config.properties, which Piped only reads at startup).
CONFIG_BEFORE="$(sha256sum config.properties)"
./syncAdminConfig.sh
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

# What goes into the piped image. Only a change here rebuilds it: even a fully cached build
# asks Docker Hub about the eclipse-temurin base images, and with no network (or DNS down)
# that fails after a long timeout and takes the whole start with it.
src_hash() {
    find src gradle build.gradle settings.gradle gradlew VERSION Dockerfile .dockerignore \
        hotspot-entrypoint.sh docker-healthcheck.sh -type f -print0 \
        | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16
}

echo "=== Starting Piped (docker) ==="
IMAGE=sonare-piped:local
# docker-compose.yml stamps the image with this, so the next start can compare.
export PIPED_SRC_HASH="$(src_hash)"
if BUILT_HASH="$(docker image inspect -f '{{index .Config.Labels "sonare.src-hash"}}' "$IMAGE" 2>/dev/null)"; then
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
        echo "The first build needs Docker Hub - check the network and DNS, then retry."
        exit 1
    fi
    echo "WARNING: rebuilding $IMAGE failed (is Docker Hub reachable?)."
    echo "  Starting the previous build, which does not have your latest changes to the Piped source."
    docker compose up -d --no-build || exit 1
fi

if [ "$CONFIG_CHANGED" = "1" ]; then
    echo "config.properties changed - restarting piped to load it."
    docker compose restart piped || exit 1
fi

echo "=== Waiting for the API ==="
for i in $(seq 1 30); do
    if curl -sf --max-time 3 http://127.0.0.1:8090/healthcheck >/dev/null 2>&1; then
        echo "Piped is healthy on http://127.0.0.1:8090"
        # Without bg-helper supplying PoTokens, YouTube returns no adaptive audio
        # formats and playback silently falls back to a muxed video stream.
        if ! docker compose ps --status running 2>/dev/null | grep -q bg-helper; then
            echo "WARNING: bg-helper is not running - expect empty audioStreams."
        fi
        exit 0
    fi
    sleep 2
done

echo "Piped did not become healthy in 60s. Check: ./runPiped.sh logs"
exit 1
