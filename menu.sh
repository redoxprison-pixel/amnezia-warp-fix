#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/amnezia-warp-menu}"
CONFIG_PATH="${CONFIG_PATH:-/etc/amnezia-warp.conf}"

PORT="${PORT:-40000}"
LOG_FILE="${LOG_FILE:-/var/log/amnezia-warp.log}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

die() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}

need_root() {
    [ "${EUID}" -eq 0 ] || die "run as root"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

load_config() {
    if [ -f "$CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_PATH"
    fi
}

save_config() {
    install -d -m 755 "$(dirname "$CONFIG_PATH")"
    cat >"$CONFIG_PATH" <<EOF
PORT="${PORT}"
LOG_FILE="${LOG_FILE}"
EOF
}

proxy_listening() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$PORT$"
}

warp_status_text() {
    warp-cli --accept-tos status 2>/dev/null || true
}

proxy_ip() {
    if proxy_listening; then
        curl -4s --max-time 8 --proxy "socks5h://127.0.0.1:$PORT" https://ifconfig.co 2>/dev/null || echo "error"
    else
        echo "N/A"
    fi
}

enable_proxy_cmd() {
    need_root
    need_cmd warp-cli
    need_cmd systemctl
    need_cmd ss
    load_config
    save_config

    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    sleep 2

    warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos set-proxy-port "$PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1

    local attempts=12
    while [ "$attempts" -gt 0 ]; do
        if proxy_listening; then
            echo -e "${GREEN}OK:${NC} WARP SOCKS5 is listening on 127.0.0.1:${PORT}"
            echo "WARP IP: $(proxy_ip)"
            return
        fi
        attempts=$((attempts - 1))
        sleep 1
    done

    die "warp proxy on 127.0.0.1:$PORT did not start"
}

disable_proxy_cmd() {
    need_root
    need_cmd warp-cli
    warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
    echo -e "${GREEN}OK:${NC} WARP proxy disconnected"
}

status_cmd() {
    load_config
    echo -e "${CYAN}WARP${NC}"
    warp_status_text
    echo
    echo -e "${CYAN}CONFIG${NC}"
    echo "PORT=$PORT"
    echo
    echo -e "${CYAN}PROXY${NC}"
    if proxy_listening; then
        echo "127.0.0.1:$PORT"
    else
        echo "not listening"
    fi
    echo
    echo -e "${CYAN}WARP IP${NC}"
    proxy_ip
}

logs_cmd() {
    journalctl -u warp-svc -n 50 --no-pager 2>/dev/null || tail -n 50 "$LOG_FILE" 2>/dev/null || true
}

configure_cmd() {
    need_root
    load_config
    local input=""
    read -r -p "WARP SOCKS port [$PORT]: " input
    PORT="${input:-$PORT}"
    save_config
    echo -e "${GREEN}OK:${NC} saved to $CONFIG_PATH"
}

print_3xui_cmd() {
    load_config
    cat <<EOF
3X-UI / Xray outbound template:

{
  "tag": "warp-out",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${PORT}
      }
    ]
  }
}

Routing idea:
- traffic you want through WARP -> outboundTag "warp-out"
- default traffic -> your regular outbound

Notes:
- This WARP proxy is TCP-oriented.
- UDP-heavy traffic will not work correctly through warp-cli proxy mode.
- For Telegram, web, and most browser traffic this is usually fine if Xray routes TCP through this outbound.
EOF
}

update_cmd() {
    need_root
    need_cmd curl
    local tmp
    tmp="$(mktemp)"
    curl -fsSL "$RAW_BASE/menu.sh" -o "$tmp"
    install -m 755 "$tmp" "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" /usr/local/bin/warp
    rm -f "$tmp"
    echo -e "${GREEN}OK:${NC} updated from $RAW_BASE/menu.sh"
}

render_menu() {
    clear
    load_config
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e " ${WHITE}Amnezia WARP Menu v${SCRIPT_VERSION}${NC}"
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e " Mode:      ${GREEN}3x-ui SOCKS5 outbound${NC}"
    echo -e " Port:      ${GREEN}${PORT}${NC}"
    echo -e " Proxy IP:  ${GREEN}$(proxy_ip)${NC}"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo " 1) Configure port"
    echo " 2) Enable WARP proxy"
    echo " 3) Disable WARP proxy"
    echo " 4) Status"
    echo " 5) Logs"
    echo " 6) Show 3x-ui config"
    echo " 7) Update menu"
    echo " 0) Exit"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
}

interactive_menu() {
    while true; do
        render_menu
        read -r -p "Choice: " choice
        case "${choice:-}" in
            1) configure_cmd ;;
            2) enable_proxy_cmd ;;
            3) disable_proxy_cmd ;;
            4) status_cmd ;;
            5) logs_cmd ;;
            6) print_3xui_cmd ;;
            7) update_cmd ;;
            0) exit 0 ;;
            *) echo "Unknown choice" ;;
        esac
        echo
        read -r -p "Press Enter..."
    done
}

usage() {
    cat <<EOF
Usage:
  $0
  $0 configure
  $0 enable
  $0 disable
  $0 status
  $0 logs
  $0 3x-ui
  $0 update
EOF
}

case "${1:-menu}" in
    configure) configure_cmd ;;
    enable) enable_proxy_cmd ;;
    disable) disable_proxy_cmd ;;
    status) status_cmd ;;
    logs) logs_cmd ;;
    3x-ui) print_3xui_cmd ;;
    update) update_cmd ;;
    menu) interactive_menu ;;
    *) usage; exit 1 ;;
esac
