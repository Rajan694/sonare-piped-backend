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
# --build: the piped service is built from this source tree. Docker's layer cache makes
# this a no-op when nothing changed; the first build takes a few minutes (Gradle).
docker compose up -d --build

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
