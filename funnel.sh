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
# Runs `./funnel.sh check` every 5 minutes while Funnel is on (installed by `up`).
CHECK=sonare-funnel-check
CHECK_DIR="$HOME/.config/systemd/user"
# When `check` last restarted tailscaled; it waits 30 minutes before doing it again.
LAST_HEAL="$TS_HOME/last-heal"

usage() {
    echo "Usage: ./funnel.sh <install|up|down|status|check>"
    echo ""
    echo "  install  Download Tailscale into $TS_HOME, run tailscaled as the"
    echo "           user service $UNIT, and sign this machine in (opens a login link)"
    echo "  up       Generate PIPED_KEY if needed, point Piped's proxy URL at the Funnel address,"
    echo "           start Piped with the gate, publish it with Funnel, check every relay"
    echo "           address, and start the $CHECK timer"
    echo "  down     Stop publishing, stop the gate and the timer, and put Piped's proxy URL"
    echo "           back to $LOCAL_PROXY"
    echo "  status   Tailscale, Funnel, gate and timer state, and each relay address's answer"
    echo "  check    Check each relay address and restart $UNIT if one gets no answer"
    echo "           (what the timer runs)"
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

# The Funnel name resolves to several relay (ingress) addresses, and each client uses
# whichever one its resolver hands out. One can lose its link to this machine while the
# others work: on 2026-10-15 one of two reset every connection, so Render got ECONNRESET
# while a check from here passed. So each address is checked on its own. A public resolver
# is asked too: some local ones answer *.ts.net with IPv6 only, or not at all.
relay_ips() {
    {
        getent ahostsv4 "$1" | awk '{ print $1 }'
        command -v dig >/dev/null && dig +short "$1" @1.1.1.1
    } | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u
}

# HTTP status of https://$DNS:<port><path> through relay <ip>; 000 is no HTTP answer at all.
via_relay() {
    local ip="$1" port="$2" path="$3"
    shift 3
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$DNS:$port:$ip" "$@" \
        "https://$DNS:$port$path" || true
}

# One pass over the relay addresses. Sets RELAYS (how many), DEAD (no answer on a port: that
# relay can't reach this machine), WRONG (answered, but not 403 without the key and 200 with
# it - the gate or Piped, not the relay) and REPORT (a line per address).
check_relays() {
    local key="$1" ip api_no api_key media_no verdict
    RELAYS=0 DEAD=0 WRONG=0 REPORT=""
    for ip in $(relay_ips "$DNS"); do
        RELAYS=$((RELAYS + 1))
        api_no="$(via_relay "$ip" 443 /healthcheck)"
        api_key="$(via_relay "$ip" 443 /healthcheck -H "X-Sonare-Key: $key")"
        media_no="$(via_relay "$ip" 8443 /)"
        if [ "$api_no" = 000 ] || [ "$api_key" = 000 ] || [ "$media_no" = 000 ]; then
            DEAD=$((DEAD + 1)) verdict="NO ANSWER"
        elif [ "$api_no" != 403 ] || [ "$api_key" != 200 ] || [ "$media_no" != 403 ]; then
            WRONG=$((WRONG + 1)) verdict="unexpected"
        else
            verdict="ok"
        fi
        REPORT+="$(printf '  %-15s  API: %s without the key, %s with it   media: %s without   %s' \
            "$ip" "$api_no" "$api_key" "$media_no" "$verdict")"$'\n'
    done
    [ "$RELAYS" -gt 0 ] || REPORT="  $DNS doesn't resolve to any IPv4 address (yet)."$'\n'
}

# check_relays until every address is fine, for up to <seconds>. Returns 1 if they aren't.
wait_relays() {
    local key="$1" deadline=$((SECONDS + $2))
    while :; do
        check_relays "$key"
        [ "$RELAYS" -gt 0 ] && [ "$DEAD" -eq 0 ] && [ "$WRONG" -eq 0 ] && return 0
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 10
    done
}

# Checks every relay address, waiting up to <seconds> for them to come good (a new certificate
# takes a minute). If a relay still gets no answer while the gate does answer here, restarting
# tailscaled brings it back: it reconnects to the relays. <cooldown> seconds since the last
# such restart skips it, so a relay that stays broken doesn't restart it every few minutes.
heal() {
    local key="$1" wait="$2" cooldown="${3:-0}" gate last
    wait_relays "$key" "$wait" || true
    if [ "$RELAYS" -gt 0 ] && [ "$DEAD" -gt 0 ]; then
        gate="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8092/healthcheck || true)"
        last="$(cat "$LAST_HEAL" 2>/dev/null || echo 0)"
        if [ "$gate" != 403 ]; then
            printf '%s' "$REPORT"
            echo "The gate isn't answering on 127.0.0.1:8092 ($gate), so restarting Tailscale won't help."
            echo "  Start Piped and the gate with ./runPiped.sh up (COMPOSE_PROFILES=funnel in .env)."
            return 1
        elif [ $(($(date +%s) - last)) -lt "$cooldown" ]; then
            printf '%s' "$REPORT"
            echo "$DEAD of $RELAYS relay addresses get no answer; $UNIT was restarted less than $((cooldown / 60)) minutes ago, so not again yet."
            return 1
        fi
        printf '%s' "$REPORT"
        echo "$DEAD of $RELAYS relay addresses get no answer - restarting $UNIT so it reconnects to them."
        date +%s > "$LAST_HEAL"
        systemctl --user restart "$UNIT"
        sleep 5
        wait_relays "$key" 120 || true
    fi
    printf '%s' "$REPORT"
    if [ "$RELAYS" -gt 0 ] && [ "$DEAD" -eq 0 ] && [ "$WRONG" -eq 0 ]; then
        echo "Every relay address answers as it should (403 without the key, 200 with it)."
        return 0
    fi
    [ "$DEAD" -gt 0 ] && echo "Still no answer from $DEAD relay address(es); clients sent there get ECONNRESET."
    [ "$WRONG" -gt 0 ] && echo "Unexpected answers: check the gate's key (PIPED_KEY in .env) and Piped (./runPiped.sh check)."
    return 1
}

install_check_timer() {
    mkdir -p "$CHECK_DIR"
    cat > "$CHECK_DIR/$CHECK.service" <<UNIT
[Unit]
Description=Check each relay address of Sonare's Piped Funnel, restart tailscaled if one is dead

[Service]
Type=oneshot
ExecStart="$SCRIPT_DIR/funnel.sh" check
UNIT
    cat > "$CHECK_DIR/$CHECK.timer" <<UNIT
[Unit]
Description=Check Sonare's Piped Funnel every 5 minutes

[Timer]
OnActiveSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now "$CHECK.timer" >/dev/null 2>&1
}

cmd_install() {
    mkdir -p "$TS_BIN" "$TS_HOME/state" "$(dirname "$UNIT_FILE")"
    if [ ! -x "$TS_BIN/tailscaled" ]; then
        local tgz tmp arch
        case "$(uname -m)" in
            x86_64) arch=amd64 ;;
            aarch64 | arm64) arch=arm64 ;;
            armv6l | armv7l) arch=arm ;;
            i386 | i686) arch=386 ;;
            *) echo "No Tailscale build for $(uname -m)."; exit 1 ;;
        esac
        tgz="$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' \
            | python3 -c 'import json, sys; print(json.load(sys.stdin)["Tarballs"][sys.argv[1]])' "$arch")"
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
    echo "=== Checking each relay address from the internet side (the first certificate can take a minute) ==="
    DNS="$dns"
    heal "$key" 90 || true
    install_check_timer
    echo "The $CHECK timer checks them every 5 minutes from now on (journalctl --user -u $CHECK)."

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
    systemctl --user disable --now "$CHECK.timer" >/dev/null 2>&1 || true
    rm -f "$CHECK_DIR/$CHECK.timer" "$CHECK_DIR/$CHECK.service"
    systemctl --user daemon-reload 2>/dev/null || true
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
    echo ""
    echo "$CHECK timer: $(systemctl --user is-active "$CHECK.timer" 2>/dev/null || true)"
    if [ -n "$(get_env PIPED_KEY)" ] && [ -x "$TS_BIN/tailscale" ] && ts status >/dev/null 2>&1; then
        DNS="$(dns_name)"
        echo "Relay addresses of $DNS:"
        check_relays "$(get_env PIPED_KEY)"
        printf '%s' "$REPORT"
    fi
}

# What the timer runs: re-checks a dead relay for 30 s before restarting tailscaled (a single
# miss can be a blip), and restarts it at most every 30 minutes.
cmd_check() {
    local key
    key="$(get_env PIPED_KEY)"
    if [ -z "$key" ]; then
        echo "No PIPED_KEY in .env - Funnel isn't set up (./funnel.sh up)."
        exit 1
    fi
    need_tailscaled
    DNS="$(dns_name)"
    heal "$key" 30 1800
}

case "${1:-}" in
    install) cmd_install ;;
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    check) cmd_check ;;
    *) usage ;;
esac
