#!/bin/bash
set -e

# Publishes this machine's Piped through Tailscale Funnel, for a Sonare backend hosted
# elsewhere (Render). YouTube then sees this machine's home IP instead of a datacenter's.
#
#   https://<machine>.<tailnet>.ts.net        -> gate :8092 -> piped        (the API)
#   https://<machine>.<tailnet>.ts.net:8443   -> gate :8093 -> piped-proxy  (the media)
#
# The gate (docker-compose.yml, profile "funnel") passes only requests carrying PIPED_KEY,
# which the backend sends as X-Sonare-Key. No sudo needed: tailscaled runs in userspace
# networking mode as a systemd user service, with its own socket and state.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TS_HOME="$HOME/.local/share/sonare-tailscale"
TS_BIN="$TS_HOME/bin"
TS_SOCK="${XDG_RUNTIME_DIR:-$TS_HOME}/sonare-tailscaled.sock"
UNIT=sonare-tailscaled.service
UNIT_FILE="$HOME/.config/systemd/user/$UNIT"
HOSTNAME_TS=sonare-piped
LOCAL_PROXY=http://localhost:8091

usage() {
    echo "Usage: ./funnel.sh <install|up|down|status>"
    echo ""
    echo "  install  Download Tailscale into $TS_HOME, run tailscaled as the"
    echo "           user service $UNIT, and sign this machine in (opens a login link)"
    echo "  up       Generate PIPED_KEY if needed, point Piped's proxy URL at the Funnel address,"
    echo "           start Piped with the gate, and publish it with Funnel"
    echo "  down     Stop publishing, stop the gate, and put Piped's proxy URL back to $LOCAL_PROXY"
    echo "  status   Tailscale, Funnel and gate state"
    exit 1
}

ts() { "$TS_BIN/tailscale" --socket="$TS_SOCK" "$@"; }

# KEY=value in .env: replaced when present, appended otherwise.
set_env() {
    local key="$1" value="$2"
    [ -f .env ] || cp .env.example .env
    if grep -q "^$key=" .env; then
        KEY="$key" VALUE="$value" awk 'BEGIN { k = ENVIRON["KEY"] "=" } index($0, k) == 1 { print k ENVIRON["VALUE"]; next } { print }' \
            .env > .env.tmp && mv .env.tmp .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

get_env() { [ -f .env ] && sed -n "s/^$1=//p" .env | tail -1 | tr -d '"' || true; }

need_tailscaled() {
    if [ ! -x "$TS_BIN/tailscale" ]; then
        echo "Tailscale isn't installed for Sonare yet - run ./funnel.sh install first."
        exit 1
    fi
    if ! ts status >/dev/null 2>&1; then
        systemctl --user start "$UNIT" 2>/dev/null || true
        sleep 2
        if ! ts status >/dev/null 2>&1; then
            echo "tailscaled isn't running or this machine isn't signed in."
            echo "  Check: systemctl --user status $UNIT, then ./funnel.sh install to sign in."
            exit 1
        fi
    fi
}

dns_name() {
    ts status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
}

cmd_install() {
    mkdir -p "$TS_BIN" "$TS_HOME/state" "$(dirname "$UNIT_FILE")"
    if [ ! -x "$TS_BIN/tailscaled" ]; then
        local tgz tmp
        tgz="$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' \
            | python3 -c 'import json, sys; print(json.load(sys.stdin)["Tarballs"]["amd64"])')"
        echo "Downloading $tgz from pkgs.tailscale.com"
        tmp="$(mktemp -d)"
        curl -fsSL "https://pkgs.tailscale.com/stable/$tgz" | tar -xz -C "$tmp"
        install -m 755 "$tmp"/tailscale_*/tailscale "$tmp"/tailscale_*/tailscaled "$TS_BIN/"
        rm -rf "$tmp"
    fi
    "$TS_BIN/tailscale" version | head -1

    cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Tailscale for Sonare's Piped (userspace networking, publishes it with Funnel)
After=network-online.target

[Service]
ExecStart=$TS_BIN/tailscaled --tun=userspace-networking --socket=$TS_SOCK --statedir=$TS_HOME/state
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now "$UNIT"
    sleep 2

    echo ""
    echo "Signing this machine in to Tailscale as '$HOSTNAME_TS' (open the link it prints)."
    ts up --hostname="$HOSTNAME_TS"
    echo ""
    echo "Signed in as $(dns_name)."
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
        echo "Note: user services stop when you log out. To keep Funnel up without a session:"
        echo "  loginctl enable-linger $USER"
    fi
    echo "Next: ./funnel.sh up"
}

cmd_up() {
    need_tailscaled
    local dns key
    dns="$(dns_name)"

    key="$(get_env PIPED_KEY)"
    if [ -z "$key" ]; then
        key="$(openssl rand -hex 32)"
        set_env PIPED_KEY "$key"
        echo "Generated PIPED_KEY in .env"
    fi
    set_env COMPOSE_PROFILES funnel
    set_env PIPED_PROXY_URL "https://$dns:8443"

    # Syncs PROXY_PART into config.properties, starts the gate, restarts piped on a change.
    ./runPiped.sh up

    echo ""
    echo "=== Publishing with Tailscale Funnel ==="
    if ! ts funnel --bg --https=443 http://127.0.0.1:8092 || ! ts funnel --bg --https=8443 http://127.0.0.1:8093; then
        echo ""
        echo "Funnel was refused. The first time, HTTPS certificates and Funnel have to be allowed"
        echo "for the tailnet: open the link above (or https://login.tailscale.com/admin/dns and"
        echo "https://login.tailscale.com/admin/acls), then run ./funnel.sh up again."
        exit 1
    fi

    echo ""
    echo "=== Checking from the internet side (the first certificate can take a minute) ==="
    local without with ip resolve=()
    # An IPv4 address: some resolvers answer *.ts.net with IPv6 only, or not at all (this
    # machine's did both), so ask a public one when the local one has no IPv4 answer.
    ip="$(getent ahostsv4 "$dns" | awk '{ print $1; exit }')"
    if [ -z "$ip" ] && command -v dig >/dev/null; then
        ip="$(dig +short "$dns" @1.1.1.1 | grep -E '^[0-9.]+$' | head -1)"
    fi
    [ -n "$ip" ] && resolve=(--resolve "$dns:443:$ip")
    without="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${resolve[@]}" "https://$dns/healthcheck" || true)"
    with="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "${resolve[@]}" -H "X-Sonare-Key: $key" "https://$dns/healthcheck" || true)"
    echo "  without the key: $without (want 403)   with the key: $with (want 200)"

    echo ""
    echo "Piped is published. On the hosted backend (Render's environment) set:"
    echo "  PIPED_API_URL=https://$dns"
    echo "  PIPED_KEY=<PIPED_KEY from sonare-piped-backend/.env>"
    echo "(and the admin page's Piped URL, if one is saved there)."
    echo "A backend on this machine keeps PIPED_API_URL=http://localhost:8090 and adds"
    echo "  PIPED_LOCAL_PROXY_URL=http://localhost:8091"
    echo "so it plays the Funnel stream urls from the local proxy."
}

cmd_down() {
    if [ -x "$TS_BIN/tailscale" ] && ts status >/dev/null 2>&1; then
        ts funnel --https=443 off 2>/dev/null || true
        ts funnel --https=8443 off 2>/dev/null || true
        echo "Funnel stopped."
    fi
    docker compose --profile funnel stop gate >/dev/null 2>&1 || true
    docker compose --profile funnel rm -f gate >/dev/null 2>&1 || true
    set_env COMPOSE_PROFILES ""
    set_env PIPED_PROXY_URL "$LOCAL_PROXY"
    ./runPiped.sh up
    echo "Piped is local only again ($LOCAL_PROXY). A backend on this machine needs no change:"
    echo "its stream urls already point at the local proxy, PIPED_LOCAL_PROXY_URL or not."
}

cmd_status() {
    if [ ! -x "$TS_BIN/tailscale" ]; then
        echo "Tailscale: not installed (./funnel.sh install)"
    else
        systemctl --user --no-pager --lines=0 status "$UNIT" 2>/dev/null | head -3 || true
        ts status 2>&1 | head -5 || true
        echo ""
        ts funnel status 2>&1 || true
    fi
    echo ""
    docker compose --profile funnel ps gate 2>/dev/null || true
    echo "PIPED_PROXY_URL=$(get_env PIPED_PROXY_URL)"
}

case "${1:-}" in
    install) cmd_install ;;
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    *) usage ;;
esac
