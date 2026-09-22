#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# This is the one component that runs in Docker. Postgres, Redis and the Sonare
# backend are all local, so nothing here should be installed on the host.

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found - it is required for the Piped backend."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose (v2) not found - install the compose plugin."
    exit 1
fi

if [ ! -f config.properties ]; then
    echo "=== Creating config.properties from config.properties.example ==="
    cp config.properties.example config.properties
fi

echo "=== Pulling images ==="
docker compose pull

echo ""
echo "Piped ready. Start it with ./runPiped.sh"
