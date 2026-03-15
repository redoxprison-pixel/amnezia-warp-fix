#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/amnezia-warp-menu}"
CONFIG_PATH="${CONFIG_PATH:-/etc/amnezia-warp.conf}"
LOG_FILE="${LOG_FILE:-/var/log/amnezia-warp-tun2socks.log}"

PORT="${PORT:-40000}"
WARP_TUN="${WARP_TUN:-tun-warp}"
TABLE_ID="${TABLE_ID:-51820}"
MARK_ID="${MARK_ID:-51820}"
RULE_PRIORITY="${RULE_PRIORITY:-10020}"
CLIENT_IF="${CLIENT_IF:-awg0}"
CLIENT_SUBNET="${CLIENT_SUBNET:-}"
CHAIN_NAME="${CHAIN_NAME:-AMNEZIA_WARP}"

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

autodetect_client_if() {
    local candidate=""

    for candidate in awg0 amneziawg0 wg0; do
        if ip link show "$candidate" >/dev/null 2>&1; then
            echo "$candidate"
            return
        fi
    done

    candidate="$(ip -o link show | awk -F': ' '$2 ~ /^(awg|amneziawg|wg)[0-9]+$/ {print $2; exit}')"
    if [ -n "$candidate" ]; then
        echo "$candidate"
    fi
}

load_config() {
    if [ -f "$CONFIG_PATH" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_PATH"
    fi

    if [ -z "${CLIENT_IF:-}" ] || ! ip link show "$CLIENT_IF" >/dev/null 2>&1; then
        CLIENT_IF="$(autodetect_client_if || true)"
        CLIENT_IF="${CLIENT_IF:-awg0}"
    fi
}

save_config() {
    install -d -m 755 "$(dirname "$CONFIG_PATH")"
    cat >"$CONFIG_PATH" <<EOF
PORT="${PORT}"
WARP_TUN="${WARP_TUN}"
TABLE_ID="${TABLE_ID}"
MARK_ID="${MARK_ID}"
RULE_PRIORITY="${RULE_PRIORITY}"
CLIENT_IF="${CLIENT_IF}"
CLIENT_SUBNET="${CLIENT_SUBNET}"
CHAIN_NAME="${CHAIN_NAME}"
LOG_FILE="${LOG_FILE}"
EOF
}

detect_client_subnet() {
    if [ -n "$CLIENT_SUBNET" ]; then
        return
    fi

    CLIENT_SUBNET="$(ip -4 -o addr show dev "$CLIENT_IF" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    [ -n "$CLIENT_SUBNET" ] || die "set CLIENT_SUBNET in $CONFIG_PATH or assign IPv4 to $CLIENT_IF"
}

try_detect_client_subnet() {
    if [ -z "${CLIENT_IF:-}" ]; then
        return 1
    fi

    CLIENT_SUBNET="$(ip -4 -o addr show dev "$CLIENT_IF" 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    [ -n "$CLIENT_SUBNET" ]
}

find_tun2socks() {
    if command -v tun2socks >/dev/null 2>&1; then
        TUN2SOCKS_BIN="$(command -v tun2socks)"
        TUN2SOCKS_MODE="xjasonlyu"
        return
    fi

    if [ -x /usr/local/bin/tun2socks ]; then
        TUN2SOCKS_BIN="/usr/local/bin/tun2socks"
        TUN2SOCKS_MODE="xjasonlyu"
        return
    fi

    if command -v badvpn-tun2socks >/dev/null 2>&1; then
        TUN2SOCKS_BIN="$(command -v badvpn-tun2socks)"
        TUN2SOCKS_MODE="badvpn"
        return
    fi

    die "tun2socks not found; install tun2socks or badvpn-tun2socks"
}

proxy_listening() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$PORT$"
}

warp_status_text() {
    warp-cli --accept-tos status 2>/dev/null || true
}

ensure_warp_proxy() {
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    sleep 2

    warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1
    warp-cli --accept-tos set-proxy-port "$PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1

    local attempts=12
    while [ "$attempts" -gt 0 ]; do
        if proxy_listening; then
            return
        fi
        attempts=$((attempts - 1))
        sleep 1
    done

    die "warp proxy on 127.0.0.1:$PORT did not start"
}

start_tun2socks() {
    find_tun2socks

    pkill -x tun2socks >/dev/null 2>&1 || true
    pkill -x badvpn-tun2socks >/dev/null 2>&1 || true
    ip link delete "$WARP_TUN" >/dev/null 2>&1 || true

    ip tuntap add dev "$WARP_TUN" mode tun
    ip addr add 198.18.0.1/30 dev "$WARP_TUN"
    ip link set "$WARP_TUN" up

    if [ "$TUN2SOCKS_MODE" = "badvpn" ]; then
        nohup "$TUN2SOCKS_BIN" --tundev "$WARP_TUN" --netif-ipaddr 198.18.0.2 --netif-netmask 255.255.255.252 --socks-server-addr 127.0.0.1:"$PORT" >"$LOG_FILE" 2>&1 &
    else
        nohup "$TUN2SOCKS_BIN" -device "$WARP_TUN" -proxy "socks5://127.0.0.1:$PORT" >"$LOG_FILE" 2>&1 &
        sleep 2
        if ! pgrep -f "$TUN2SOCKS_BIN" >/dev/null 2>&1; then
            nohup "$TUN2SOCKS_BIN" -interface "$WARP_TUN" -proxy "socks5://127.0.0.1:$PORT" >"$LOG_FILE" 2>&1 &
        fi
    fi

    sleep 2
    pgrep -f "$TUN2SOCKS_BIN" >/dev/null 2>&1 || die "tun2socks failed to start, see $LOG_FILE"
}

apply_sysctls() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null
    sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
    sysctl -w "net.ipv4.conf.${CLIENT_IF}.rp_filter=0" >/dev/null 2>&1 || true
    sysctl -w "net.ipv4.conf.${WARP_TUN}.rp_filter=0" >/dev/null 2>&1 || true
}

setup_routing() {
    ip route replace default dev "$WARP_TUN" table "$TABLE_ID"
    ip route replace 127.0.0.0/8 dev lo table "$TABLE_ID"
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" priority "$RULE_PRIORITY" >/dev/null 2>&1 || true
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID" priority "$RULE_PRIORITY"
}

setup_iptables() {
    iptables -t mangle -N "$CHAIN_NAME" >/dev/null 2>&1 || true
    iptables -t mangle -F "$CHAIN_NAME"
    iptables -t mangle -D PREROUTING -j "$CHAIN_NAME" >/dev/null 2>&1 || true
    iptables -t mangle -A PREROUTING -j "$CHAIN_NAME"
    iptables -t mangle -A "$CHAIN_NAME" -m addrtype --dst-type LOCAL -j RETURN
    iptables -t mangle -A "$CHAIN_NAME" -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A "$CHAIN_NAME" -i "$CLIENT_IF" -s "$CLIENT_SUBNET" -j MARK --set-mark "$MARK_ID"
}

cleanup_iptables() {
    iptables -t mangle -D PREROUTING -j "$CHAIN_NAME" >/dev/null 2>&1 || true
    iptables -t mangle -F "$CHAIN_NAME" >/dev/null 2>&1 || true
    iptables -t mangle -X "$CHAIN_NAME" >/dev/null 2>&1 || true
}

proxy_ip() {
    if proxy_listening; then
        curl -4s --max-time 8 --proxy "socks5h://127.0.0.1:$PORT" https://ifconfig.me 2>/dev/null || echo "error"
    else
        echo "N/A"
    fi
}

overlay_active() {
    ip rule show 2>/dev/null | grep -Eq "lookup ${TABLE_ID}($| )"
}

legacy_process_hint() {
    local proc_line=""
    proc_line="$(pgrep -af 'tun2socks|badvpn-tun2socks' 2>/dev/null | head -n1 || true)"
    if [ -n "$proc_line" ] && [[ "$proc_line" != *"$WARP_TUN"* ]]; then
        echo "legacy tun2socks process detected"
    fi
}

status_cmd() {
    load_config

    echo -e "${CYAN}WARP${NC}"
    warp_status_text
    echo
    echo -e "${CYAN}CONFIG${NC}"
    echo "CLIENT_IF=$CLIENT_IF"
    echo "CLIENT_SUBNET=$CLIENT_SUBNET"
    echo "PORT=$PORT"
    echo
    echo -e "${CYAN}ROUTING${NC}"
    if overlay_active; then
        ip rule show 2>/dev/null | grep -E "lookup ${TABLE_ID}($| )" || true
        ip route show table "$TABLE_ID" 2>/dev/null || true
    else
        echo "overlay inactive"
    fi
    echo
    echo -e "${CYAN}PROXY IP${NC}"
    proxy_ip
    echo
    echo -e "${CYAN}PROCESS${NC}"
    pgrep -af 'tun2socks|badvpn-tun2socks' || echo "not running"
    if [ -n "$(legacy_process_hint)" ]; then
        echo
        echo -e "${YELLOW}NOTE:${NC} $(legacy_process_hint)"
        echo "Run 'warp down' once, then 'warp up' from this menu."
    fi
}

up_cmd() {
    need_root
    need_cmd ip
    need_cmd iptables
    need_cmd curl
    need_cmd ss
    need_cmd warp-cli
    load_config
    detect_client_subnet
    save_config
    apply_sysctls
    ensure_warp_proxy
    start_tun2socks
    setup_routing
    setup_iptables

    echo -e "${GREEN}OK:${NC} traffic from ${CLIENT_SUBNET} on ${CLIENT_IF} goes through WARP"
    echo "Proxy IP: $(proxy_ip)"
}

down_cmd() {
    need_root
    load_config
    cleanup_iptables
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" priority "$RULE_PRIORITY" >/dev/null 2>&1 || true
    ip route flush table "$TABLE_ID" >/dev/null 2>&1 || true
    pkill -x tun2socks >/dev/null 2>&1 || true
    pkill -x badvpn-tun2socks >/dev/null 2>&1 || true
    ip link delete "$WARP_TUN" >/dev/null 2>&1 || true
    echo -e "${GREEN}OK:${NC} overlay disabled"
}

logs_cmd() {
    tail -n 50 "$LOG_FILE"
}

configure_cmd() {
    need_root
    load_config
    try_detect_client_subnet || true

    local input=""
    read -r -p "Amnezia interface [$CLIENT_IF]: " input
    CLIENT_IF="${input:-$CLIENT_IF}"

    try_detect_client_subnet || true
    read -r -p "Amnezia subnet [$CLIENT_SUBNET]: " input
    CLIENT_SUBNET="${input:-$CLIENT_SUBNET}"

    read -r -p "WARP SOCKS port [$PORT]: " input
    PORT="${input:-$PORT}"

    save_config
    echo -e "${GREEN}OK:${NC} saved to $CONFIG_PATH"
}

auto_configure_cmd() {
    need_root
    load_config
    detect_client_subnet
    save_config
    echo -e "${GREEN}OK:${NC} auto-detected config saved"
    echo "CLIENT_IF=$CLIENT_IF"
    echo "CLIENT_SUBNET=$CLIENT_SUBNET"
    echo "PORT=$PORT"
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
    echo -e " Interface: ${GREEN}${CLIENT_IF}${NC}"
    echo -e " Subnet:    ${GREEN}${CLIENT_SUBNET:-auto}${NC}"
    echo -e " Proxy IP:  ${GREEN}$(proxy_ip)${NC}"
    echo -e "${CYAN}────────────────────────────────────────────${NC}"
    echo " 1) Configure"
    echo " 2) Auto-configure"
    echo " 3) Enable WARP overlay"
    echo " 4) Disable WARP overlay"
    echo " 5) Status"
    echo " 6) Logs"
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
            2) auto_configure_cmd ;;
            3) up_cmd ;;
            4) down_cmd ;;
            5) status_cmd ;;
            6) logs_cmd ;;
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
  $0 up
  $0 down
  $0 status
  $0 logs
  $0 configure
  $0 auto-configure
  $0 update
EOF
}

case "${1:-menu}" in
    up) up_cmd ;;
    down) down_cmd ;;
    status) status_cmd ;;
    logs) logs_cmd ;;
    configure) configure_cmd ;;
    auto-configure) auto_configure_cmd ;;
    update) update_cmd ;;
    menu) interactive_menu ;;
    *) usage; exit 1 ;;
esac
