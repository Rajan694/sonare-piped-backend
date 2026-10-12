#!/bin/bash
set -e

# Brings this checkout up to date and starts it: pull, then ./runPiped.sh up, which rebuilds
# the image only when the Piped source changed and syncs .env into the Piped files. With
# Tailscale Funnel set up (COMPOSE_PROFILES=funnel in .env) it goes through ./funnel.sh up,
# so the gate and the Funnel ports come back too.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

usage() {
    echo "Usage: ./updatePiped.sh [--no-run]"
    echo ""
    echo "  Pull, then start Piped (and republish it with Funnel when that is set up)."
    echo "  --no-run  Stop after pulling (../update.sh starts things itself)"
    echo ""
    echo "Refuses to pull over uncommitted changes."
    exit 1
}

RUN=1
for arg in "$@"; do
    case "$arg" in
        --no-run) RUN=0 ;;
        *) usage ;;
    esac
done

if [ ! -f .env ] || [ ! -f config.properties ]; then
    echo ".env or config.properties missing - run ./installPiped.sh first."
    exit 1
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Uncommitted changes here - commit or stash them before updating:"
    git status --short --untracked-files=no
    exit 1
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" != "HEAD" ] || { echo "Detached HEAD - check out a branch first."; exit 1; }
echo "=== Pulling $BRANCH ==="
git pull --ff-only

[ "$RUN" = "1" ] || { echo ""; echo "Piped updated ($(git log -1 --format='%h %s'))."; exit 0; }

echo ""
if grep -qx 'COMPOSE_PROFILES=funnel' .env && [ -x "$HOME/.local/share/sonare-tailscale/bin/tailscale" ]; then
    exec ./funnel.sh up
fi
exec ./runPiped.sh up
