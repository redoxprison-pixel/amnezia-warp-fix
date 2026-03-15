#!/usr/bin/env bash

set -Eeuo pipefail

RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/amnezia-warp-menu}"
CONFIG_PATH="${CONFIG_PATH:-/etc/amnezia-warp.conf}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

die() {
    echo -e "${RED}ERROR:${NC} $*" >&2
    exit 1
}

need_root() {
    [ "${EUID}" -eq 0 ] || die "run as root"
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        return
    fi
    die "only Debian/Ubuntu with apt-get are supported"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates gnupg lsb-release iproute2 iptables procps badvpn || true
}

install_warp_repo() {
    if command -v warp-cli >/dev/null 2>&1; then
        return
    fi

    install -d -m 755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" >/etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
}

install_menu() {
    local tmp
    tmp="$(mktemp)"
    curl -fsSL "$RAW_BASE/menu.sh" -o "$tmp"
    install -m 755 "$tmp" "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" /usr/local/bin/warp
    rm -f "$tmp"
}

write_default_config() {
    if [ -f "$CONFIG_PATH" ]; then
        return
    fi

    cat >"$CONFIG_PATH" <<'EOF'
PORT="40000"
WARP_TUN="tun-warp"
TABLE_ID="51820"
MARK_ID="51820"
RULE_PRIORITY="10020"
CLIENT_IF="awg0"
CLIENT_SUBNET=""
CHAIN_NAME="AMNEZIA_WARP"
LOG_FILE="/var/log/amnezia-warp-tun2socks.log"
EOF
}

post_checks() {
    if ! command -v tun2socks >/dev/null 2>&1 && ! command -v badvpn-tun2socks >/dev/null 2>&1 && [ ! -x /usr/local/bin/tun2socks ]; then
        echo -e "${YELLOW}WARN:${NC} tun2socks not found. Install tun2socks manually or ensure badvpn-tun2socks is available."
    fi
}

main() {
    need_root
    detect_pkg_manager
    install_packages
    install_warp_repo
    install_menu
    write_default_config
    post_checks

    echo -e "${GREEN}OK:${NC} installed"
    echo "Config: $CONFIG_PATH"
    echo "Run:"
    echo "  sudo warp"
    echo "  sudo warp configure"
}

main "$@"
