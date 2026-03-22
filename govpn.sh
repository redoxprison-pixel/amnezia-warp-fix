#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  GoVPN Manager v4.0
#  Автоопределение режима · WARP мастер · iptables каскад
#  Поддержка: 3X-UI · AmneziaWG · Bridge · Combo
# ══════════════════════════════════════════════════════════════

VERSION="4.0"
SCRIPT_NAME="govpn"
INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"
REPO_URL="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh"

CONF_DIR="/etc/govpn"
CONF_FILE="${CONF_DIR}/config"
BACKUP_DIR="${CONF_DIR}/backups"
ALIASES_FILE="${CONF_DIR}/aliases"
LOG_FILE="/var/log/govpn.log"
MONITOR_PID_FILE="${CONF_DIR}/monitor.pid"

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
BLUE='\033[0;34m'; NC='\033[0m'

# Глобальные переменные
MY_IP=""
IFACE=""
MODE=""           # 3xui | amnezia | combo | bridge
MODE_LABEL=""
WARP_SOCKS_PORT="40000"
AWG_CONTAINER=""  # активный amnezia контейнер

# ═══════════════════════════════════════════════════════════════
#  УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════

log_action() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

check_root() {
    [ "$EUID" -ne 0 ] && { echo -e "${RED}Запустите от root!${NC}"; exit 1; }
}

get_my_ip() {
    local services=("https://api4.ipify.org" "https://ipv4.icanhazip.com" "https://checkip.amazonaws.com")
    for svc in "${services[@]}"; do
        local ip; ip=$(curl -s4 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && MY_IP="$ip" && return
    done
    MY_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' | head -1 || echo "N/A")
}

detect_interface() {
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo "eth0")
}

check_deps() {
    local missing=()
    for cmd in curl python3 iptables; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ ${#missing[@]} -gt 0 ] && {
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y > /dev/null 2>&1
        apt-get install -y "${missing[@]}" iptables-persistent netfilter-persistent wireguard-tools > /dev/null 2>&1
    }
}

init_config() {
    mkdir -p "$CONF_DIR" "$BACKUP_DIR"
    [ -f "$CONF_FILE" ] && source "$CONF_FILE"
    WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"
}

save_config() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF_FILE"
    else
        echo "${key}=\"${val}\"" >> "$CONF_FILE"
    fi
    source "$CONF_FILE"
}

prepare_system() {
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
}

# ═══════════════════════════════════════════════════════════════
#  АВТООПРЕДЕЛЕНИЕ РЕЖИМА
# ═══════════════════════════════════════════════════════════════

detect_mode() {
    local has_3xui=0 has_amnezia=0

    # Проверяем 3X-UI / x-ui
    systemctl is-active x-ui &>/dev/null 2>&1 && has_3xui=1
    [ "$has_3xui" -eq 0 ] && [ -f "/etc/x-ui/x-ui.db" ] && has_3xui=1

    # Проверяем AmneziaWG — ищем контейнер с активными клиентами
    if command -v docker &>/dev/null; then
        local best_ct="" best_peers=0
        while IFS= read -r ct; do
            [ -z "$ct" ] && continue
            local peers
            peers=$(docker exec "$ct" sh -c "wg show 2>/dev/null | grep -c 'latest handshake'" 2>/dev/null || echo "0")
            peers=$(echo "$peers" | tr -d '[:space:]')
            if (( peers > best_peers )); then
                best_peers=$peers
                best_ct=$ct
            fi
        done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg")

        # Если нет активных — берём любой amnezia контейнер
        if [ -z "$best_ct" ]; then
            best_ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg" | head -1)
        fi

        [ -n "$best_ct" ] && has_amnezia=1 && AWG_CONTAINER="$best_ct"
    fi

    # Определяем режим
    if [ "$has_3xui" -eq 1 ] && [ "$has_amnezia" -eq 1 ]; then
        MODE="combo"
        MODE_LABEL="3X-UI + AmneziaWG"
    elif [ "$has_3xui" -eq 1 ]; then
        MODE="3xui"
        MODE_LABEL="3X-UI"
    elif [ "$has_amnezia" -eq 1 ]; then
        MODE="amnezia"
        MODE_LABEL="Amnezia (${AWG_CONTAINER})"
    else
        MODE="bridge"
        MODE_LABEL="Bridge"
    fi
}

is_3xui() { [[ "$MODE" == "3xui" || "$MODE" == "combo" ]]; }
is_amnezia() { [[ "$MODE" == "amnezia" || "$MODE" == "combo" ]]; }
is_bridge() { [[ "$MODE" == "bridge" ]]; }

# ═══════════════════════════════════════════════════════════════
#  WARP — ОБЩИЕ ФУНКЦИИ
# ═══════════════════════════════════════════════════════════════

warp_overall_status() {
    # Возвращает строку статуса для шапки
    local parts=()

    if is_3xui; then
        if command -v warp-cli &>/dev/null; then
            local st; st=$(warp-cli --accept-tos status 2>/dev/null)
            if echo "$st" | grep -qi "connected" && ! echo "$st" | grep -qi "disconnected"; then
                parts+=("${GREEN}3X-UI: ● подключён${NC}")
            else
                parts+=("${RED}3X-UI: ● не подключён${NC}")
            fi
        else
            parts+=("${YELLOW}3X-UI: не установлен${NC}")
        fi
    fi

    if is_amnezia; then
        if docker exec "$AWG_CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null; then
            local wip; wip=$(docker exec "$AWG_CONTAINER" sh -c \
                "curl -s --interface warp --connect-timeout 3 https://api4.ipify.org 2>/dev/null || true")
            parts+=("${GREEN}Amnezia: ● ${wip:-подключён}${NC}")
        else
            parts+=("${YELLOW}Amnezia: ● не настроен${NC}")
        fi
    fi

    [ ${#parts[@]} -eq 0 ] && echo "${YELLOW}WARP: не применимо${NC}" && return
    local IFS=' | '; echo -e "${parts[*]}"
}

# ═══════════════════════════════════════════════════════════════
#  WARP — 3X-UI BACKEND
# ═══════════════════════════════════════════════════════════════

_3xui_warp_installed() { command -v warp-cli &>/dev/null; }

_3xui_warp_running() {
    local st; st=$(warp-cli --accept-tos status 2>/dev/null)
    echo "$st" | grep -qi "connected" && ! echo "$st" | grep -qi "disconnected"
}

_3xui_warp_ip() {
    curl -s4 --max-time 8 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
        https://api4.ipify.org 2>/dev/null | tr -d '[:space:]'
}

_3xui_install_warp() {
    echo -e "\n${CYAN}[3X-UI] Установка Cloudflare WARP...${NC}\n"

    if _3xui_warp_installed; then
        echo -e "${YELLOW}  warp-cli уже установлен${NC}"
    else
        echo -e "${YELLOW}[1/3]${NC} Установка пакета cloudflare-warp..."
        local codename; codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
            gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${codename} main" \
            > /etc/apt/sources.list.d/cloudflare-client.list
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y > /dev/null 2>&1
        apt-get install -y cloudflare-warp > /dev/null 2>&1
        command -v warp-cli &>/dev/null || { echo -e "${RED}  ✗ Не удалось установить${NC}"; return 1; }
        systemctl enable warp-svc > /dev/null 2>&1
        systemctl start warp-svc > /dev/null 2>&1
        sleep 2
        echo -e "${GREEN}  ✓ $(warp-cli --version 2>/dev/null)${NC}"
    fi

    echo -e "${YELLOW}[2/3]${NC} Проверка API и регистрация..."
    # Проверить доступность API
    local api_ok=0
    curl -s --max-time 5 https://api.cloudflareclient.com/v0a4005/reg > /dev/null 2>&1 && api_ok=1

    if [ "$api_ok" -eq 0 ]; then
        echo -e "${RED}  ✗ Cloudflare API недоступен с этого IP (RU сервер?)${NC}"
        echo -e "${WHITE}  WARP можно установить только на exit-ноду (не RU bridge)${NC}"
        return 1
    fi

    if ! _3xui_warp_running; then
        warp-cli --accept-tos registration new > /dev/null 2>&1 || true
        warp-cli --accept-tos mode proxy > /dev/null 2>&1
        warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" > /dev/null 2>&1
        warp-cli --accept-tos connect > /dev/null 2>&1

        local connected=0
        for i in 1 2 3 4 5; do
            sleep 3
            _3xui_warp_running && connected=1 && break
            echo -e "  ${YELLOW}Ожидание... (${i}/5)${NC}"
        done
        [ "$connected" -eq 0 ] && echo -e "${RED}  ✗ Не удалось подключить${NC}" && return 1
    fi

    local wip; wip=$(_3xui_warp_ip)
    echo -e "${GREEN}  ✓ WARP подключён: ${wip}${NC}"

    echo -e "${YELLOW}[3/3]${NC} Применение outbound в xray (через БД)..."
    _3xui_patch_db && echo -e "${GREEN}  ✓ xrayTemplateConfig обновлён${NC}" || \
        echo -e "${YELLOW}  ⚠ БД не найдена — добавьте outbound вручную${NC}"

    log_action "3XUI WARP SETUP: port=${WARP_SOCKS_PORT}, ip=${wip}"
    return 0
}

_3xui_patch_db() {
    local db="/etc/x-ui/x-ui.db"
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 > /dev/null 2>&1
    [ -f "$db" ] || return 1

    # Бэкап БД
    cp "$db" "${BACKUP_DIR}/x-ui.db.bak.$(date +%s)"

    python3 - <<EOF
import json, subprocess, sys

r = subprocess.run(['sqlite3', '${db}',
    "SELECT value FROM settings WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
tmpl_str = r.stdout.strip()
if not tmpl_str:
    sys.exit(1)

cfg = json.loads(tmpl_str)

# Убрать старые warp outbounds
cfg['outbounds'] = [o for o in cfg.get('outbounds', [])
                    if o.get('tag', '').lower() != 'warp']

# Добавить новый
cfg['outbounds'].append({
    "tag": "WARP",
    "protocol": "socks",
    "settings": {
        "servers": [{"address": "127.0.0.1", "port": ${WARP_SOCKS_PORT}, "users": []}]
    }
})

new_tmpl = json.dumps(cfg, ensure_ascii=False, indent=2).replace("'", "''")
r2 = subprocess.run(['sqlite3', '${db}',
    f"UPDATE settings SET value='{new_tmpl}' WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
sys.exit(r2.returncode)
EOF
    local ret=$?
    [ "$ret" -eq 0 ] && systemctl restart x-ui > /dev/null 2>&1 && sleep 3
    return $ret
}

_3xui_warp_status() {
    echo -e "\n${CYAN}━━━ WARP статус (3X-UI) ━━━${NC}\n"
    if ! _3xui_warp_installed; then
        echo -e "  ${RED}warp-cli не установлен${NC}"
        return
    fi
    local st; st=$(warp-cli --accept-tos status 2>/dev/null)
    if echo "$st" | grep -qi "connected" && ! echo "$st" | grep -qi "disconnected"; then
        echo -e "  ${WHITE}Статус:   ${GREEN}● Подключён${NC}"
        echo -e "  ${WHITE}WARP IP:  ${GREEN}$(_3xui_warp_ip)${NC}"
    else
        echo -e "  ${WHITE}Статус:   ${RED}● Не подключён${NC}"
    fi
    echo -e "  ${WHITE}SOCKS5:   ${CYAN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo -e "  ${WHITE}Реальный: ${WHITE}${MY_IP}${NC}"

    # Проверить outbound в xray
    local db="/etc/x-ui/x-ui.db"
    if [ -f "$db" ] && command -v sqlite3 &>/dev/null; then
        local has_warp
        has_warp=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null | \
            python3 -c "import json,sys; cfg=json.load(sys.stdin); \
            outs=[o for o in cfg.get('outbounds',[]) if o.get('tag','').lower()=='warp']; \
            print(len(outs))" 2>/dev/null)
        if [ "${has_warp:-0}" -gt 0 ]; then
            echo -e "  ${WHITE}xray:     ${GREEN}✓ outbound WARP в БД${NC}"
        else
            echo -e "  ${WHITE}xray:     ${YELLOW}⚠ outbound не добавлен${NC}"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
#  WARP — AMNEZIA BACKEND
# ═══════════════════════════════════════════════════════════════

WGCF_VER="2.2.30"
AWG_WARP_DIR="/opt/warp"
AWG_WARP_CONF="${AWG_WARP_DIR}/warp.conf"
AWG_CLIENTS_FILE="${AWG_WARP_DIR}/clients.list"
AWG_MARKER_B="# --- GOVPN WARP BEGIN ---"
AWG_MARKER_E="# --- GOVPN WARP END ---"

_awg_conf() {
    for f in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf /etc/wireguard/wg0.conf; do
        docker exec "$AWG_CONTAINER" sh -c "[ -f '$f' ]" 2>/dev/null && echo "$f" && return
    done
}

_awg_iface() {
    local conf; conf=$(_awg_conf)
    [[ "$conf" == *"awg0"* ]] && echo "awg0" || echo "wg0"
}

_awg_warp_running() {
    docker exec "$AWG_CONTAINER" sh -c "ip addr show warp >/dev/null 2>&1" 2>/dev/null
}

_awg_warp_ip() {
    docker exec "$AWG_CONTAINER" sh -c \
        "curl -s --interface warp --connect-timeout 5 https://api4.ipify.org 2>/dev/null || true"
}

_awg_all_clients() {
    local conf; conf=$(_awg_conf)
    docker exec "$AWG_CONTAINER" sh -c "grep 'AllowedIPs' '$conf'" 2>/dev/null | \
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32' | tr -d '\r'
}

_awg_client_name() {
    local ip="${1%/32}"
    docker exec "$AWG_CONTAINER" sh -c "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" | \
        python3 -c "
import json,sys
try:
    data=json.load(sys.stdin)
    for c in data:
        ud=c.get('userData',{})
        ai=ud.get('allowedIps','')
        if ai.startswith('${ip}') or ai == '${ip}/32':
            print(ud.get('clientName',''))
            break
except: pass
" 2>/dev/null
}

_awg_selected_clients() {
    docker exec "$AWG_CONTAINER" sh -c "cat '${AWG_CLIENTS_FILE}' 2>/dev/null || true" | \
        tr -d '\r' | grep -v '^$'
}

_awg_save_clients() {
    local content=""
    for ip in "$@"; do content+="${ip}"$'\n'; done
    docker exec "$AWG_CONTAINER" sh -c "mkdir -p '${AWG_WARP_DIR}' && printf '%s' '${content}' > '${AWG_CLIENTS_FILE}'"
}

_awg_install_wgcf() {
    # Устанавливаем wgcf внутри контейнера
    local arch; arch=$(docker exec "$AWG_CONTAINER" sh -c "uname -m" 2>/dev/null)
    local wa
    case "$arch" in
        x86_64) wa="amd64" ;; aarch64) wa="arm64" ;; armv7l) wa="armv7" ;;
        *) echo -e "${RED}  ✗ Архитектура не поддерживается: ${arch}${NC}"; return 1 ;;
    esac

    local url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${wa}"
    curl -fsSL "$url" -o /tmp/wgcf_bin 2>/dev/null && [ -s /tmp/wgcf_bin ] || {
        echo -e "${RED}  ✗ Не удалось скачать wgcf${NC}"; return 1
    }
    docker cp /tmp/wgcf_bin "${AWG_CONTAINER}:/usr/local/bin/wgcf" 2>/dev/null
    docker exec "$AWG_CONTAINER" sh -c "chmod +x /usr/local/bin/wgcf" 2>/dev/null
    rm -f /tmp/wgcf_bin
    return 0
}

_awg_create_warp_conf() {
    # Регистрация и генерация профиля внутри контейнера
    docker exec "$AWG_CONTAINER" sh -c "
        cd /tmp
        rm -f wgcf-account.toml wgcf-profile.conf
        yes | wgcf register --accept-tos 2>/dev/null
    " 2>/dev/null

    docker exec "$AWG_CONTAINER" sh -c "[ -f /tmp/wgcf-account.toml ]" 2>/dev/null || return 1

    docker exec "$AWG_CONTAINER" sh -c "
        cd /tmp && yes | wgcf generate 2>/dev/null
    " 2>/dev/null

    docker exec "$AWG_CONTAINER" sh -c "[ -f /tmp/wgcf-profile.conf ]" 2>/dev/null || return 1

    # Адаптируем конфиг: убрать IPv6, DNS, добавить Table=off
    docker exec "$AWG_CONTAINER" sh -c "
        mkdir -p '${AWG_WARP_DIR}'
        cp /tmp/wgcf-profile.conf '${AWG_WARP_CONF}'

        # IPv6 из Address — оставить только первый IPv4
        sed -i 's|^\(Address = [0-9.\/]*\),.*|\1|g' '${AWG_WARP_CONF}'

        # IPv6 из AllowedIPs
        sed -i 's|AllowedIPs = 0\.0\.0\.0/0, ::/0|AllowedIPs = 0.0.0.0/0|g' '${AWG_WARP_CONF}'
        sed -i 's|AllowedIPs = ::/0.*|AllowedIPs = 0.0.0.0/0|g' '${AWG_WARP_CONF}'

        # DNS
        sed -i 's|^DNS = .*|# DNS disabled|g' '${AWG_WARP_CONF}'

        # Table = off
        sed -i '/^\[Interface\]/a Table = off' '${AWG_WARP_CONF}'

        chmod 600 '${AWG_WARP_CONF}'
        mv /tmp/wgcf-account.toml '${AWG_WARP_DIR}/' 2>/dev/null || true
    " 2>/dev/null
    return 0
}

_awg_tunnel_up() {
    # Проверить что wg-quick доступен
    docker exec "$AWG_CONTAINER" sh -c "command -v wg-quick >/dev/null 2>&1" 2>/dev/null || {
        docker exec "$AWG_CONTAINER" sh -c \
            "apt-get update -qq && apt-get install -y -qq wireguard-tools 2>/dev/null || true" > /dev/null 2>&1
    }

    docker exec "$AWG_CONTAINER" sh -c \
        "wg-quick down '${AWG_WARP_CONF}' 2>/dev/null; wg-quick up '${AWG_WARP_CONF}' 2>&1" 2>/dev/null
    sleep 2
    _awg_warp_running
}

_awg_apply_rules() {
    # ip rule внутри контейнера для выбранных клиентов
    local -a selected=("$@")
    local iface; iface=$(_awg_iface)

    # Очистить старые правила
    docker exec "$AWG_CONTAINER" sh -c "
        ip rule list | grep 'lookup 100' | awk '{print \$1}' | sed 's/://' | sort -rn | \
            while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done
        iptables -t mangle -D PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true
        iptables -t nat -S POSTROUTING 2>/dev/null | grep 'o warp -j MASQUERADE' | \
            sed 's/^-A /-D /' | while read -r r; do iptables -t nat \$r 2>/dev/null || true; done
        ip route flush table 100 2>/dev/null || true
    " > /dev/null 2>&1

    [ "${#selected[@]}" -eq 0 ] && return 0

    # Маршрут через warp
    docker exec "$AWG_CONTAINER" sh -c \
        "ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"

    # Маркировка всего трафика с VPN интерфейса + per-client MASQUERADE
    docker exec "$AWG_CONTAINER" sh -c "
        iptables -t mangle -A PREROUTING -i ${iface} -j MARK --set-mark 100
        ip rule add fwmark 100 lookup 100 2>/dev/null || true
    " > /dev/null 2>&1

    for ip in "${selected[@]}"; do
        docker exec "$AWG_CONTAINER" sh -c "
            iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE
        " > /dev/null 2>&1
    done
}

_awg_patch_start_sh() {
    local start_sh="/opt/amnezia/start.sh"
    local iface; iface=$(_awg_iface)
    local -a selected=("$@")

    # Бэкап
    docker exec "$AWG_CONTAINER" sh -c \
        "[ -f /opt/amnezia/start.sh.govpn-backup ] || cp '${start_sh}' /opt/amnezia/start.sh.govpn-backup" 2>/dev/null

    # Собираем блок
    local block="${AWG_MARKER_B}"$'\n'
    block+="if [ -f '${AWG_WARP_CONF}' ]; then"$'\n'
    block+="  wg-quick up '${AWG_WARP_CONF}' 2>/dev/null || true"$'\n'
    block+="  sleep 2"$'\n'
    block+="fi"$'\n'

    if [ "${#selected[@]}" -gt 0 ]; then
        block+="ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
        block+="iptables -t mangle -A PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true"$'\n'
        block+="ip rule add fwmark 100 lookup 100 2>/dev/null || true"$'\n'
        for ip in "${selected[@]}"; do
            block+="iptables -t nat -C POSTROUTING -s ${ip} -o warp -j MASQUERADE 2>/dev/null || \
iptables -t nat -I POSTROUTING 1 -s ${ip} -o warp -j MASQUERADE"$'\n'
        done
    fi
    block+="${AWG_MARKER_E}"

    # Удалить старый блок
    docker exec "$AWG_CONTAINER" sh -c \
        "sed -i '/# --- GOVPN WARP BEGIN ---/,/# --- GOVPN WARP END ---/d' '${start_sh}' 2>/dev/null || true"

    # Вставить перед tail -f /dev/null
    docker exec "$AWG_CONTAINER" bash -c "
if grep -qF 'tail -f /dev/null' '${start_sh}'; then
    tmpf=\$(mktemp)
    while IFS= read -r line; do
        if echo \"\$line\" | grep -qF 'tail -f /dev/null'; then
            printf '%s\n' '${block}'
        fi
        echo \"\$line\"
    done < '${start_sh}' > \"\$tmpf\"
    mv \"\$tmpf\" '${start_sh}'
    chmod +x '${start_sh}'
else
    printf '\n%s\n' '${block}' >> '${start_sh}'
    chmod +x '${start_sh}'
fi
" 2>/dev/null
}

_awg_install_warp() {
    echo -e "\n${CYAN}[Amnezia] Установка WARP в контейнер ${AWG_CONTAINER}...${NC}\n"

    echo -e "${YELLOW}[1/4]${NC} Скачивание wgcf в контейнер..."
    _awg_install_wgcf || { read -p "Enter..."; return 1; }
    echo -e "${GREEN}  ✓ wgcf ${WGCF_VER}${NC}"

    echo -e "${YELLOW}[2/4]${NC} Регистрация WARP аккаунта..."
    _awg_create_warp_conf || {
        echo -e "${RED}  ✗ Регистрация не удалась${NC}"
        read -p "Enter..."; return 1
    }
    echo -e "${GREEN}  ✓ Профиль создан${NC}"

    echo -e "${YELLOW}[3/4]${NC} Поднимаю туннель warp..."
    _awg_tunnel_up || {
        echo -e "${RED}  ✗ Туннель не поднялся${NC}"
        read -p "Enter..."; return 1
    }
    local wip; wip=$(_awg_warp_ip)
    echo -e "${GREEN}  ✓ WARP IP: ${wip}${NC}"

    echo -e "${YELLOW}[4/4]${NC} Включаю WARP для всех клиентов..."
    local -a all_ips=()
    while IFS= read -r ip; do [ -n "$ip" ] && all_ips+=("$ip"); done <<< "$(_awg_all_clients)"

    _awg_save_clients "${all_ips[@]}"
    _awg_apply_rules "${all_ips[@]}"
    _awg_patch_start_sh "${all_ips[@]}"

    echo -e "${GREEN}  ✓ ${#all_ips[@]} клиентов через WARP${NC}"
    log_action "AWG WARP INSTALL: container=${AWG_CONTAINER}, clients=${#all_ips[@]}, ip=${wip}"
    return 0
}

_awg_warp_status() {
    echo -e "\n${CYAN}━━━ WARP статус (Amnezia: ${AWG_CONTAINER}) ━━━${NC}\n"
    local iface; iface=$(_awg_iface)
    echo -e "  ${WHITE}Контейнер: ${CYAN}${AWG_CONTAINER}${NC}  Интерфейс: ${CYAN}${iface}${NC}"

    if _awg_warp_running; then
        local wip; wip=$(_awg_warp_ip)
        echo -e "  ${WHITE}WARP:      ${GREEN}● запущен${NC}  IP: ${GREEN}${wip}${NC}"
    else
        echo -e "  ${WHITE}WARP:      ${RED}● не запущен${NC}"
    fi

    local -a sel=()
    while IFS= read -r ip; do [ -n "$ip" ] && sel+=("$ip"); done <<< "$(_awg_selected_clients)"
    local -a all=()
    while IFS= read -r ip; do [ -n "$ip" ] && all+=("$ip"); done <<< "$(_awg_all_clients)"
    echo -e "  ${WHITE}Клиентов:  ${CYAN}${#sel[@]}${NC} из ${#all[@]} через WARP"

    # Показать ip rule
    local rules; rules=$(docker exec "$AWG_CONTAINER" sh -c "ip rule list | grep 'fwmark\|lookup 100'" 2>/dev/null)
    [ -n "$rules" ] && echo -e "\n  ${CYAN}ip rule:${NC}" && \
        echo "$rules" | while read -r l; do echo -e "  ${WHITE}  $l${NC}"; done
}

# ═══════════════════════════════════════════════════════════════
#  МАСТЕР НАСТРОЙКИ WARP
# ═══════════════════════════════════════════════════════════════

warp_setup_wizard() {
    clear
    echo -e "\n${CYAN}━━━ Настройка WARP ━━━${NC}\n"
    echo -e "${WHITE}Режим: ${CYAN}${MODE_LABEL}${NC}\n"

    local do_3xui=0 do_amnezia=0

    if [ "$MODE" = "combo" ]; then
        echo -e "${WHITE}Обнаружены оба режима. Применить WARP к:${NC}"
        echo -e "  ${YELLOW}[1]${NC} Только 3X-UI"
        echo -e "  ${YELLOW}[2]${NC} Только Amnezia"
        echo -e "  ${YELLOW}[3]${NC} Оба"
        echo -e "  ${YELLOW}[0]${NC} Отмена"
        echo ""
        read -p "Выбор: " combo_choice
        case "$combo_choice" in
            1) do_3xui=1 ;;
            2) do_amnezia=1 ;;
            3) do_3xui=1; do_amnezia=1 ;;
            *) return ;;
        esac
    elif is_3xui; then
        do_3xui=1
    elif is_amnezia; then
        do_amnezia=1
    else
        echo -e "${YELLOW}Bridge режим — WARP не применимо.${NC}"
        echo -e "${WHITE}Используйте iptables проброс (п.4).${NC}"
        read -p "Enter..."; return
    fi

    local ok=0

    if [ "$do_3xui" -eq 1 ]; then
        _3xui_install_warp && ok=1 || true
        echo ""
    fi

    if [ "$do_amnezia" -eq 1 ]; then
        _awg_install_warp && ok=1 || true
        echo ""
    fi

    if [ "$ok" -eq 1 ]; then
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
        echo -e "${GREEN}  WARP успешно настроен!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════${NC}"
    else
        echo -e "${RED}  Настройка не удалась. Проверьте логи.${NC}"
    fi

    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  WARP — ТЕСТ
# ═══════════════════════════════════════════════════════════════

warp_test() {
    clear
    echo -e "\n${CYAN}━━━ Тест WARP ━━━${NC}\n"
    local all_ok=1

    if is_3xui; then
        echo -e "${WHITE}── 3X-UI ──────────────────────────────${NC}"

        echo -ne "  warp-cli демон...      "
        systemctl is-active warp-svc &>/dev/null && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; all_ok=0; }

        echo -ne "  Подключение...         "
        _3xui_warp_running && echo -e "${GREEN}✓ Connected${NC}" || { echo -e "${RED}✗${NC}"; all_ok=0; }

        echo -ne "  Режим proxy...         "
        warp-cli --accept-tos settings 2>/dev/null | grep -qi "warpproxy\|proxy" && \
            echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; all_ok=0; }

        echo -ne "  SOCKS5 порт...         "
        ss -tlnp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT} " && \
            echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; all_ok=0; }

        echo -ne "  HTTP через WARP...     "
        local wip; wip=$(_3xui_warp_ip)
        if [[ "$wip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]]; then
            if [ "$wip" != "$MY_IP" ]; then
                echo -e "${GREEN}✓ ${wip} (Cloudflare)${NC}"
            else
                echo -e "${YELLOW}⚠ IP не изменился${NC}"; all_ok=0
            fi
        else
            echo -e "${RED}✗ нет ответа${NC}"; all_ok=0
        fi

        echo -ne "  outbound в xray...     "
        local db="/etc/x-ui/x-ui.db"
        if [ -f "$db" ] && command -v sqlite3 &>/dev/null; then
            local cnt
            cnt=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null | \
                python3 -c "import json,sys; cfg=json.load(sys.stdin); \
                print(len([o for o in cfg.get('outbounds',[]) if o.get('tag','').lower()=='warp']))" 2>/dev/null)
            [ "${cnt:-0}" -gt 0 ] && echo -e "${GREEN}✓ добавлен${NC}" || \
                { echo -e "${YELLOW}⚠ не добавлен — запустите мастер${NC}"; }
        else
            echo -e "${YELLOW}⚠ БД не найдена${NC}"
        fi
        echo ""
    fi

    if is_amnezia; then
        echo -e "${WHITE}── Amnezia (${AWG_CONTAINER}) ──────────────${NC}"

        echo -ne "  Контейнер...           "
        docker exec "$AWG_CONTAINER" sh -c "true" 2>/dev/null && \
            echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; all_ok=0; }

        echo -ne "  warp туннель...        "
        _awg_warp_running && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗ — запустите мастер${NC}"; all_ok=0; }

        echo -ne "  WARP IP...             "
        local awip; awip=$(_awg_warp_ip)
        if [[ "$awip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]]; then
            echo -e "${GREEN}✓ ${awip}${NC}"
        else
            echo -e "${RED}✗${NC}"; all_ok=0
        fi

        echo -ne "  ip rule (fwmark)...    "
        docker exec "$AWG_CONTAINER" sh -c "ip rule list | grep -q fwmark" 2>/dev/null && \
            echo -e "${GREEN}✓${NC}" || { echo -e "${YELLOW}⚠ — включите клиентов${NC}"; }

        local sel_count
        sel_count=$(docker exec "$AWG_CONTAINER" sh -c \
            "cat '${AWG_CLIENTS_FILE}' 2>/dev/null | grep -c '[0-9]'" 2>/dev/null || echo "0")
        echo -e "  Клиентов через WARP:   ${CYAN}${sel_count}${NC}"
        echo ""
    fi

    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$all_ok" -eq 1 ]; then
        echo -e "  ${GREEN}✅ WARP работает корректно${NC}"
    else
        echo -e "  ${RED}❌ Есть проблемы — запустите мастер (п.1)${NC}"
    fi
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  УПРАВЛЕНИЕ КЛИЕНТАМИ AMNEZIA
# ═══════════════════════════════════════════════════════════════

awg_clients_menu() {
    if ! is_amnezia; then
        echo -e "${YELLOW}Amnezia не обнаружен.${NC}"; read -p "Enter..."; return
    fi

    local -a sel_ips=()
    local sel_loaded=0

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиенты Amnezia → WARP ━━━${NC}\n"

        local iface; iface=$(_awg_iface)
        echo -e "  ${WHITE}Контейнер: ${CYAN}${AWG_CONTAINER}${NC}  Интерфейс: ${CYAN}${iface}${NC}"

        if _awg_warp_running; then
            local wip; wip=$(_awg_warp_ip)
            echo -e "  ${WHITE}WARP:      ${GREEN}● ${wip}${NC}"
        else
            echo -e "  ${WHITE}WARP:      ${RED}● не запущен — сначала настройте (п.1)${NC}"
        fi
        echo ""

        local -a all_ips=()
        while IFS= read -r ip; do [ -n "$ip" ] && all_ips+=("$ip"); done <<< "$(_awg_all_clients)"

        if [ "$sel_loaded" -eq 0 ]; then
            while IFS= read -r ip; do [ -n "$ip" ] && sel_ips+=("$ip"); done <<< "$(_awg_selected_clients)"
            sel_loaded=1
        fi

        echo -e "${WHITE}Клиенты:${NC}"
        for i in "${!all_ips[@]}"; do
            local ip="${all_ips[$i]}"
            local name; name=$(_awg_client_name "$ip")
            local label="${name:-${ip%/32}}"
            local in_warp=0
            for s in "${sel_ips[@]}"; do [ "$s" = "$ip" ] && in_warp=1; done
            if [ "$in_warp" -eq 1 ]; then
                echo -e "  ${YELLOW}[$((i+1))]${NC} ${GREEN}✅${NC} ${WHITE}${label}${NC}  ${ip}"
            else
                echo -e "  ${YELLOW}[$((i+1))]${NC} ${WHITE}☐${NC}  ${WHITE}${label}${NC}  ${ip}"
            fi
        done

        echo ""
        echo -e "  ${YELLOW}[a]${NC}  Все через WARP"
        echo -e "  ${YELLOW}[n]${NC}  Отключить всех"
        echo -e "  ${YELLOW}[s]${NC}  Применить"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch

        case "$ch" in
            [1-9])
                local idx=$((ch-1))
                [ -z "${all_ips[$idx]:-}" ] && continue
                local tip="${all_ips[$idx]}"
                local already=0
                for s in "${sel_ips[@]}"; do [ "$s" = "$tip" ] && already=1; done
                if [ "$already" -eq 1 ]; then
                    local -a tmp=()
                    for s in "${sel_ips[@]}"; do [ -n "$s" ] && [ "$s" != "$tip" ] && tmp+=("$s"); done
                    sel_ips=("${tmp[@]}")
                else
                    sel_ips+=("$tip")
                fi ;;
            a|A) sel_ips=("${all_ips[@]}") ;;
            n|N) sel_ips=() ;;
            s|S)
                echo ""
                echo -e "${YELLOW}[1/3]${NC} Сохраняем..."
                _awg_save_clients "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[2/3]${NC} Применяем правила..."
                _awg_apply_rules "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[3/3]${NC} Патчим start.sh..."
                _awg_patch_start_sh "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                log_action "AWG CLIENTS: ${#sel_ips[@]} через WARP"
                echo -e "\n${GREEN}Применено. Изменения активны.${NC}"
                echo -e "${WHITE}Перезапуск контейнера не нужен — правила применились сразу.${NC}"
                read -p "Нажмите Enter..." ;;
            0|"") return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  IPTABLES ПРОБРОС
# ═══════════════════════════════════════════════════════════════

save_iptables() {
    netfilter-persistent save > /dev/null 2>&1 || \
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

validate_ip() { [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

tcp_ping() {
    local ip="$1" port="$2" tout="${3:-3}"
    local ms
    ms=$(curl -so /dev/null -w '%{time_connect}' --max-time "$tout" \
        --connect-timeout "$tout" "http://${ip}:${port}/" 2>/dev/null)
    [ -z "$ms" ] && return 1
    awk "BEGIN{v=$ms*1000; if(v<0.5) exit 1; printf \"%.1f\", v}" 2>/dev/null || return 1
}

probe_server() {
    local ip="$1" port="$2"
    echo -ne "  ${YELLOW}Проверка ${ip}:${port}...${NC} "
    local ms; ms=$(tcp_ping "$ip" "$port" 5)
    if [ -n "$ms" ]; then
        echo -e "${GREEN}✓ ${ms}ms${NC}"
        return 0
    else
        echo -e "${YELLOW}⚠ недоступен (применим всё равно?)${NC}"
        read -p "  Продолжить? (y/n): " c
        [[ "$c" == "y" ]]
    fi
}

get_alias() {
    local ip="$1"
    grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | cut -d'=' -f2 | cut -d'|' -f1
}

fmt_ip() {
    local ip="$1"
    local name; name=$(get_alias "$ip")
    [ -n "$name" ] && echo "${name} (${ip})" || echo "$ip"
}

get_rules_list() {
    iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | \
        while read -r rule; do
            local proto port dest comment
            proto=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="-p") print $(i+1)}')
            port=$(echo "$rule" | sed 's/.*--dport \([0-9]*\).*/\1/')
            dest=$(echo "$rule" | sed 's/.*--to-destination \([^ ]*\).*/\1/')
            comment=$(echo "$rule" | sed -n 's/.*--comment "\([^"]*\)".*/\1/p')
            [ -n "$port" ] && [ -n "$dest" ] && \
                echo "${proto:-any}|${port}|${dest}|${comment}"
        done
}

get_govpn_rules() {
    iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn:" | \
        while read -r rule; do
            local proto port dest
            proto=$(echo "$rule" | awk '{for(i=1;i<=NF;i++) if($i=="-p") print $(i+1)}')
            port=$(echo "$rule" | sed 's/.*--dport \([0-9]*\).*/\1/')
            dest=$(echo "$rule" | sed 's/.*--to-destination \([^ ]*\).*/\1/')
            [ -n "$port" ] && [ -n "$dest" ] && echo "${proto}|${port}|${dest}"
        done
}

apply_rule() {
    local proto="$1" in_port="$2" out_port="$3" dest_ip="$4" label="$5"
    local comment="govpn:${in_port}:${proto}"

    # Удалить старое если есть
    iptables -t nat -S PREROUTING 2>/dev/null | grep "$comment" | \
        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done

    iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" \
        -j DNAT --to-destination "${dest_ip}:${out_port}" \
        -m comment --comment "$comment" 2>/dev/null
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null

    save_iptables
    log_action "RULE ADD: ${proto} ${in_port}→${dest_ip}:${out_port} (${label})"
    echo -e "${GREEN}  ✓ Правило добавлено${NC}"
}

iptables_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ iptables Проброс ━━━${NC}\n"
        echo -e "  ${WHITE}Этот сервер: ${GREEN}${MY_IP}${NC}\n"

        # Показать все DNAT правила
        local rules; rules=$(get_rules_list)
        if [ -n "$rules" ]; then
            echo -e "${WHITE}Активные правила DNAT:${NC}"
            while IFS='|' read -r proto port dest comment; do
                local dest_ip="${dest%:*}" dest_port="${dest#*:}"
                local dest_label; dest_label=$(fmt_ip "$dest_ip")
                local tag=""
                if echo "$comment" | grep -q "govpn:"; then
                    tag=" ${CYAN}[govpn]${NC}"
                elif [ -n "$comment" ]; then
                    tag=" ${YELLOW}[${comment}]${NC}"
                else
                    tag=" ${YELLOW}[внешнее]${NC}"
                fi
                # Проверяем петлю на себя
                local loop=""
                [ "$dest_ip" = "$MY_IP" ] && loop=" ${YELLOW}← себя${NC}"
                echo -e "  ${GREEN}●${NC} ${proto} :${port} → ${dest_label}:${dest_port}${tag}${loop}"
            done <<< "$rules"
            echo ""
        else
            echo -e "  ${YELLOW}Правил нет${NC}\n"
        fi

        echo -e "  ${YELLOW}[1]${NC}  AmneziaWG / WireGuard (UDP)"
        echo -e "  ${YELLOW}[2]${NC}  VLESS / XRay (TCP)"
        echo -e "  ${YELLOW}[3]${NC}  MTProto (TCP)"
        echo -e "  ${YELLOW}[4]${NC}  Кастомное правило"
        echo -e "  ${YELLOW}[5]${NC}  Удалить правило"
        echo -e "  ${RED}[6]${NC}  Сбросить все"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch

        case "$ch" in
            1) _add_rule "udp" "AmneziaWG/WireGuard" ;;
            2) _add_rule "tcp" "VLESS/XRay" ;;
            3) _add_rule "tcp" "MTProto" ;;
            4) _add_custom_rule ;;
            5) _delete_rule ;;
            6)
                read -p "$(echo -e "${RED}Сбросить все правила govpn? (y/n): ${NC}")" c
                [[ "$c" == "y" ]] && {
                    iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn:" | \
                        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done
                    save_iptables
                    echo -e "${GREEN}Правила govpn сброшены.${NC}"
                    echo -e "${YELLOW}Внешние правила (Amnezia) не затронуты.${NC}"
                    sleep 2
                } ;;
            0|"") return ;;
        esac
    done
}

_read_ip() {
    local prompt="$1" ip
    while true; do
        echo -e "${WHITE}${prompt}${NC}"
        read -p "> " ip
        [ -z "$ip" ] && return 1
        validate_ip "$ip" && echo "$ip" && return 0
        echo -e "${RED}Некорректный IP.${NC}"
    done
}

_read_port() {
    local prompt="$1" hint="${2:-}" port
    while true; do
        echo -e "${WHITE}${prompt}${NC}"
        [ -n "$hint" ] && echo -e "${CYAN}Стандартный: ${hint}${NC}"
        read -p "> " port
        [ -z "$port" ] && return 1
        validate_port "$port" && echo "$port" && return 0
        echo -e "${RED}Некорректный порт (1-65535).${NC}"
    done
}

_add_rule() {
    local proto="$1" label="$2"
    clear
    echo -e "\n${CYAN}━━━ Добавить правило: ${label} ━━━${NC}\n"
    echo -e "${WHITE}Трафик на этот сервер будет перенаправлен на exit-ноду.${NC}\n"

    local dest_ip; dest_ip=$(_read_ip "IP exit-ноды:") || return
    local hint=""
    case "$label" in *WireGuard*|*Amnezia*) hint="51820" ;; *VLESS*) hint="443 или 8443" ;; *MTProto*) hint="8443" ;; esac
    local port; port=$(_read_port "Порт (одинаковый на обоих серверах):" "$hint") || return

    probe_server "$dest_ip" "$port" || return

    echo -e "\n${WHITE}Правило: ${proto} :${port} → ${dest_ip}:${port}${NC}"
    read -p "Применить? (y/n): " c
    [[ "$c" == "y" ]] && apply_rule "$proto" "$port" "$port" "$dest_ip" "$label"
    read -p "Нажмите Enter..."
}

_add_custom_rule() {
    clear
    echo -e "\n${CYAN}━━━ Кастомное правило ━━━${NC}\n"

    local proto
    while true; do
        echo -e "${WHITE}Протокол (tcp/udp):${NC}"
        read -p "> " proto
        [ -z "$proto" ] && return
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] && break
        echo -e "${RED}Введите tcp или udp.${NC}"
    done

    local dest_ip; dest_ip=$(_read_ip "IP exit-ноды:") || return
    local in_port; in_port=$(_read_port "ВХОДЯЩИЙ порт (на этом сервере):") || return
    local out_port; out_port=$(_read_port "ИСХОДЯЩИЙ порт (на exit-ноде):") || return

    probe_server "$dest_ip" "$out_port" || return

    echo -e "\n${WHITE}Правило: ${proto} :${in_port} → ${dest_ip}:${out_port}${NC}"
    read -p "Применить? (y/n): " c
    [[ "$c" == "y" ]] && apply_rule "$proto" "$in_port" "$out_port" "$dest_ip" "Custom"
    read -p "Нажмите Enter..."
}

_delete_rule() {
    local rules; rules=$(get_rules_list)
    [ -z "$rules" ] && echo -e "${YELLOW}Нет правил.${NC}" && read -p "Enter..." && return

    clear
    echo -e "\n${CYAN}━━━ Удалить правило ━━━${NC}\n"
    echo -e "${WHITE}Удалить можно только правила govpn. Внешние правила (Amnezia) удаляются через их приложение.${NC}\n"

    local -a rule_arr=()
    local i=1
    while IFS='|' read -r proto port dest comment; do
        local dest_ip="${dest%:*}" dest_port="${dest#*:}"
        local is_govpn=0
        echo "$comment" | grep -q "govpn:" && is_govpn=1

        if [ "$is_govpn" -eq 1 ]; then
            echo -e "  ${YELLOW}[$i]${NC} ${proto} :${port} → ${dest_ip}:${dest_port} ${CYAN}[govpn]${NC}"
            rule_arr+=("${proto}|${port}|${dest}|${comment}")
            ((i++))
        else
            echo -e "  ${WHITE}    ${proto} :${port} → ${dest_ip}:${dest_port} ${YELLOW}[внешнее — нельзя удалить]${NC}"
        fi
    done <<< "$rules"

    [ ${#rule_arr[@]} -eq 0 ] && echo -e "\n${YELLOW}Нет правил govpn для удаления.${NC}" && \
        read -p "Enter..." && return

    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    read -p "Выбор: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#rule_arr[@]} )) || return

    IFS='|' read -r proto port dest comment <<< "${rule_arr[$((ch-1))]}"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "${comment}" | \
        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done
    save_iptables
    echo -e "${GREEN}  ✓ Удалено.${NC}"
    log_action "RULE DEL: ${proto} :${port} → ${dest}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  ИНСТРУМЕНТЫ
# ═══════════════════════════════════════════════════════════════

tools_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Инструменты ━━━${NC}\n"

        # Быстрый статус серверов из алиасов
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            echo -e "${WHITE}Серверы:${NC}"
            while IFS='=' read -r ip val; do
                [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
                local name; name=$(echo "$val" | cut -d'|' -f1)
                local country; country=$(echo "$val" | cut -d'|' -f3)
                local label="${name:-$ip}"
                [ -n "$country" ] && label="${label} (${country})"
                local is_cur=""
                [ "$ip" = "$MY_IP" ] && is_cur=" ${CYAN}←${NC}"
                # Быстрый TCP пинг
                local port; port=$(grep "govpn:" /proc/net/ip_tables_names 2>/dev/null | head -1)
                local ms; ms=$(tcp_ping "$ip" "443" 2 2>/dev/null)
                if [ -n "$ms" ]; then
                    echo -e "  ${GREEN}●${NC} ${WHITE}${label}${NC}${is_cur}  ${GREEN}${ms}ms${NC}"
                else
                    ms=$(ping -c 1 -W 2 "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
                    [ -n "$ms" ] && echo -e "  ${GREEN}●${NC} ${WHITE}${label}${NC}${is_cur}  ${GREEN}${ms}ms${NC}" || \
                        echo -e "  ${RED}●${NC} ${WHITE}${label}${NC}${is_cur}  ${RED}недоступен${NC}"
                fi
            done < "$ALIASES_FILE"
            echo ""
        fi

        echo -e "  ${YELLOW}[1]${NC}  Тест скорости"
        echo -e "  ${YELLOW}[2]${NC}  Тест цепочки"
        echo -e "  ${YELLOW}[3]${NC}  Проверить сайт"
        echo -e "  ${YELLOW}[4]${NC}  Серверы (добавить/переименовать)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch
        case "$ch" in
            1) _speed_test ;;
            2) _chain_test ;;
            3) _site_check ;;
            4) _servers_menu ;;
            0|"") return ;;
        esac
    done
}

_speed_test() {
    clear
    echo -e "\n${CYAN}━━━ Тест скорости ━━━${NC}\n"

    # Задержка — TCP на WARP порт или SSH
    echo -e "${WHITE}Задержка до этого сервера (10 измерений):${NC}"
    local -a results=() lost=0
    for i in $(seq 1 10); do
        local ms
        ms=$(curl -so /dev/null -w '%{time_connect}' --max-time 2 \
            "http://127.0.0.1:${WARP_SOCKS_PORT}/" 2>/dev/null)
        [ -z "$ms" ] || [ "$ms" = "0.000000" ] && \
            ms=$(curl -so /dev/null -w '%{time_connect}' --max-time 2 \
                "http://127.0.0.1:22/" 2>/dev/null)
        if [ -n "$ms" ] && awk "BEGIN{exit !($ms > 0.0001)}"; then
            local ms_val; ms_val=$(awk "BEGIN{printf \"%.2f\", $ms*1000}")
            results+=("$ms_val")
            local ms_int; ms_int=$(awk "BEGIN{printf \"%d\",$ms_val+0.5}")
            local color="$GREEN"
            (( ms_int > 50 )) && color="$YELLOW"
            printf "  ${WHITE}%2d)${NC}  ${color}%7sms${NC}\n" "$i" "$ms_val"
        else
            ((lost++))
            printf "  ${WHITE}%2d)${NC}  ${RED}<1ms (loopback)${NC}\n" "$i"
            results+=("0.1")
        fi
    done

    if [ ${#results[@]} -gt 0 ]; then
        local stats
        stats=$(printf '%s\n' "${results[@]}" | \
            awk 'BEGIN{mn=999999;mx=0;s=0;n=0} {s+=$1;n++;if($1<mn)mn=$1;if($1>mx)mx=$1} \
                END{printf "%.1f|%.1f|%.1f",mn,mx,s/n}')
        IFS='|' read -r s_min s_max s_avg <<< "$stats"
        echo -e "\n  ${WHITE}Мин: ${GREEN}${s_min}ms${NC}  Макс: ${RED}${s_max}ms${NC}  Сред: ${CYAN}${s_avg}ms${NC}"
    fi

    # Скорость через Cloudflare
    echo -e "\n${WHITE}Скорость скачивания:${NC}"
    local dl
    dl=$(curl -s4 --max-time 10 -o /dev/null -w '%{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=10000000" 2>/dev/null)
    if [ -n "$dl" ] && awk "BEGIN{exit !($dl > 0)}"; then
        local mbps; mbps=$(awk "BEGIN{printf \"%.1f\", $dl/131072}")
        echo -e "  ${GREEN}↓ ${mbps} Мбит/с${NC}"
    else
        echo -e "  ${YELLOW}Не удалось измерить${NC}"
    fi

    if is_3xui && _3xui_warp_running; then
        echo -e "\n${WHITE}Скорость через WARP:${NC}"
        local wdl
        wdl=$(curl -s4 --max-time 10 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
            -o /dev/null -w '%{speed_download}' \
            "https://speed.cloudflare.com/__down?bytes=10000000" 2>/dev/null)
        if [ -n "$wdl" ] && awk "BEGIN{exit !($wdl > 0)}"; then
            local wmbps; wmbps=$(awk "BEGIN{printf \"%.1f\", $wdl/131072}")
            echo -e "  ${GREEN}↓ ${wmbps} Мбит/с${NC} ${CYAN}(через Cloudflare WARP)${NC}"
        fi
    fi

    echo ""
    read -p "Нажмите Enter..."
}

_chain_test() {
    clear
    echo -e "\n${CYAN}━━━ Тест цепочки ━━━${NC}\n"

    # Собираем серверы из алиасов
    local -a chain_ips=() chain_names=()
    if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
        while IFS='=' read -r ip val; do
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
            local name; name=$(echo "$val" | cut -d'|' -f1)
            local country; country=$(echo "$val" | cut -d'|' -f3)
            local label="${name:-$ip}"
            [ -n "$country" ] && label="${label} (${country})"
            chain_ips+=("$ip"); chain_names+=("$label")
        done < "$ALIASES_FILE"
    fi

    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Этот сервер → интернет
    echo -ne "\n${WHITE}Этот сервер → интернет:${NC}  "
    local t_start t_end t_ms
    t_start=$(date +%s%3N)
    curl -s4 --max-time 5 https://api4.ipify.org > /dev/null 2>&1
    t_end=$(date +%s%3N)
    t_ms=$((t_end - t_start))
    local c="$GREEN"; (( t_ms > 200 )) && c="$YELLOW"; (( t_ms > 500 )) && c="$RED"
    echo -e "${c}${t_ms}ms${NC}  ${WHITE}${MY_IP}${NC}"

    # Через WARP
    if is_3xui && _3xui_warp_running; then
        echo -ne "${WHITE}Через WARP:             ${NC}  "
        local wt_start wt_end wt_ms wip
        wt_start=$(date +%s%3N)
        wip=$(curl -s4 --max-time 8 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
            https://api4.ipify.org 2>/dev/null)
        wt_end=$(date +%s%3N)
        wt_ms=$((wt_end - wt_start))
        [ -n "$wip" ] && echo -e "${GREEN}${wt_ms}ms${NC}  ${WHITE}${wip}${NC}" || echo -e "${RED}нет ответа${NC}"
    fi

    # Пинг до каждого сервера
    local step=3
    for i in "${!chain_ips[@]}"; do
        local ip="${chain_ips[$i]}" name="${chain_names[$i]}"
        echo -ne "${WHITE}→ ${name}:${NC}  "
        local ping_ms
        ping_ms=$(ping -c 3 -W 3 "$ip" 2>/dev/null | \
            awk '/rtt/ {gsub(/.*=/, ""); split($1,a,"/"); printf "%.1f", a[2]}')
        if [ -n "$ping_ms" ]; then
            local pc="$GREEN"; (( ${ping_ms%.*} > 80 )) && pc="$YELLOW"
            echo -e "${pc}${ping_ms}ms${NC} (ICMP)"
        else
            local tcp_ms; tcp_ms=$(tcp_ping "$ip" "443" 3 2>/dev/null)
            [ -n "$tcp_ms" ] && echo -e "${GREEN}${tcp_ms}ms${NC} (TCP)" || echo -e "${RED}недоступен${NC}"
        fi
        ((step++))
    done

    echo -e "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

_site_check() {
    clear
    echo -e "\n${CYAN}━━━ Проверить сайт / IP ━━━${NC}\n"
    echo -e "${WHITE}Введите домен или IP:${NC}"
    read -p "> " target
    [ -z "$target" ] && return

    clear
    echo -e "\n${CYAN}━━━ ${target} ━━━${NC}\n"

    # IP
    local tip="$target"
    if ! [[ "$target" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]]; then
        echo -ne "${WHITE}DNS...${NC}  "
        tip=$(python3 -c "import socket; print(socket.gethostbyname('${target}'))" 2>/dev/null)
        [ -n "$tip" ] && echo -e "${GREEN}${tip}${NC}" || { echo -e "${RED}не определён${NC}"; read -p "Enter..."; return; }
    fi

    # GeoIP
    echo -ne "${WHITE}GeoIP...${NC}  "
    local geo; geo=$(curl -s --max-time 5 "http://ip-api.com/json/${tip}?fields=country,city,isp" 2>/dev/null)
    local country city isp
    country=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null)
    city=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null)
    isp=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('isp',''))" 2>/dev/null)
    echo -e "${GREEN}${city}, ${country}${NC}  ${WHITE}${isp}${NC}"

    # Пинг
    echo -ne "${WHITE}Пинг...${NC}   "
    local pms; pms=$(ping -c 3 -W 2 "$tip" 2>/dev/null | \
        awk '/rtt/ {gsub(/.*=/, ""); split($1,a,"/"); printf "%.1f", a[2]}')
    [ -n "$pms" ] && echo -e "${GREEN}${pms}ms${NC}" || \
        { local tms; tms=$(tcp_ping "$tip" "443" 3 2>/dev/null)
          [ -n "$tms" ] && echo -e "${GREEN}${tms}ms${NC} (TCP)" || echo -e "${RED}недоступен${NC}"; }

    # HTTP
    echo -ne "${WHITE}HTTP...${NC}   "
    local hc; hc=$(curl -s4 --max-time 8 -o /dev/null -w '%{http_code}' "https://${target}" 2>/dev/null)
    [ -n "$hc" ] && [ "$hc" != "000" ] && echo -e "${GREEN}${hc}${NC}" || echo -e "${RED}нет ответа${NC}"

    # Через WARP
    if is_3xui && _3xui_warp_running; then
        echo -ne "${WHITE}Через WARP:${NC}  "
        local wt_start wt_end wt_ms wc
        wt_start=$(date +%s%3N)
        wc=$(curl -s4 --max-time 8 --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
            -o /dev/null -w '%{http_code}' "https://${target}" 2>/dev/null)
        wt_end=$(date +%s%3N)
        wt_ms=$((wt_end - wt_start))
        [ -n "$wc" ] && [ "$wc" != "000" ] && \
            echo -e "${GREEN}${wt_ms}ms  HTTP ${wc}${NC}" || echo -e "${YELLOW}нет ответа${NC}"
    fi

    echo ""
    read -p "Нажмите Enter..."
}

_servers_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Серверы ━━━${NC}\n"
        echo -e "${WHITE}Серверы используются в тесте цепочки и мониторинге.${NC}\n"

        local -a ips=()
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            while IFS='=' read -r ip val; do
                [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
                local name; name=$(echo "$val" | cut -d'|' -f1)
                local country; country=$(echo "$val" | cut -d'|' -f3)
                echo -e "  ${YELLOW}[$((${#ips[@]}+1))]${NC} ${WHITE}${name:-$ip}${NC}  ${ip}  ${country}"
                ips+=("$ip")
            done < "$ALIASES_FILE"
        else
            echo -e "  ${YELLOW}Серверов нет${NC}"
        fi

        echo ""
        echo -e "  ${YELLOW}[a]${NC}  Добавить сервер"
        [ ${#ips[@]} -gt 0 ] && echo -e "  ${YELLOW}[номер]${NC}  Переименовать / удалить"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch

        case "$ch" in
            a|A)
                echo -e "\n${WHITE}IP сервера:${NC}"
                read -p "> " new_ip
                [ -z "$new_ip" ] && continue
                validate_ip "$new_ip" || { echo -e "${RED}Некорректный IP.${NC}"; sleep 1; continue; }

                echo -e "${YELLOW}GeoIP...${NC}"
                local geo; geo=$(curl -s --max-time 5 "http://ip-api.com/json/${new_ip}?fields=country,city,isp" 2>/dev/null)
                local nc nc_city nc_isp
                nc=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null)
                nc_city=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null)
                nc_isp=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('isp',''))" 2>/dev/null)
                [ -n "$nc_city" ] && echo -e "${GREEN}${nc_city}, ${nc} (${nc_isp})${NC}"

                echo -e "${WHITE}Имя (например: RU-bridge, AMS):${NC}"
                read -p "> " new_name

                # Сохранить
                if grep -q "^${new_ip}=" "$ALIASES_FILE" 2>/dev/null; then
                    sed -i "s|^${new_ip}=.*|${new_ip}=${new_name:-$new_ip}||${nc}|${nc_isp}|" "$ALIASES_FILE"
                else
                    echo "${new_ip}=${new_name:-$new_ip}||${nc}|${nc_isp}" >> "$ALIASES_FILE"
                fi
                echo -e "${GREEN}[OK] Добавлен.${NC}"; sleep 1
                ;;
            0|"") return ;;
            *)
                [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#ips[@]} )) || continue
                local sel_ip="${ips[$((ch-1))]}"
                echo -e "\n${WHITE}${sel_ip}${NC}"
                echo -e "  ${YELLOW}[1]${NC} Переименовать"
                echo -e "  ${RED}[2]${NC} Удалить"
                echo -e "  ${YELLOW}[0]${NC} Назад"
                read -p "> " sub
                case "$sub" in
                    1)
                        echo -e "${WHITE}Новое имя:${NC}"
                        read -p "> " new_name
                        [ -n "$new_name" ] && \
                            sed -i "s|^${sel_ip}=\([^|]*\)|${sel_ip}=${new_name}|" "$ALIASES_FILE"
                        ;;
                    2)
                        sed -i "/^${sel_ip}=/d" "$ALIASES_FILE"
                        echo -e "${GREEN}Удалён.${NC}"; sleep 1
                        ;;
                esac ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  СИСТЕМА
# ═══════════════════════════════════════════════════════════════

system_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Система ━━━${NC}\n"

        # Системная информация
        local cpu_count load_avg mem_info disk_info uptime_str
        cpu_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
        load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
        mem_info=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB (%.0f%%)", $3, $2, $3/$2*100}')
        disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
        uptime_str=$(uptime -p 2>/dev/null || echo "?")

        echo -e "  ${WHITE}Uptime:${NC}  ${GREEN}${uptime_str}${NC}"
        echo -e "  ${WHITE}CPU:${NC}     ${GREEN}${cpu_count} ядер${NC}  Load: ${GREEN}${load_avg}${NC}"
        echo -e "  ${WHITE}RAM:${NC}     ${GREEN}${mem_info}${NC}"
        echo -e "  ${WHITE}Диск /:${NC} ${GREEN}${disk_info}${NC}"
        echo ""

        # Бэкапы
        local bak_count; bak_count=$(ls "$BACKUP_DIR"/*.bak.* 2>/dev/null | wc -l)
        echo -e "  ${WHITE}Бэкапов:${NC} ${CYAN}${bak_count}${NC} в ${BACKUP_DIR}"
        echo ""

        echo -e "  ${YELLOW}[1]${NC}  Бэкапы и Rollback xray"
        echo -e "  ${YELLOW}[2]${NC}  Проверка конфликтов"
        echo -e "  ${YELLOW}[3]${NC}  Перезапустить x-ui"
        echo -e "  ${YELLOW}[4]${NC}  Перезапустить WARP"
        echo -e "  ${YELLOW}[5]${NC}  Обновить скрипт"
        echo -e "  ${RED}[6]${NC}  Полное удаление"
        echo -e "  ${YELLOW}[r]${NC}  Перезагрузить сервер"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch
        case "$ch" in
            1) _backups_menu ;;
            2) _check_conflicts ;;
            3)
                echo -e "${YELLOW}Перезапуск x-ui...${NC}"
                systemctl restart x-ui 2>/dev/null && echo -e "${GREEN}OK${NC}" || echo -e "${RED}Ошибка${NC}"
                read -p "Enter..." ;;
            4)
                echo -e "${YELLOW}Перезапуск WARP...${NC}"
                systemctl restart warp-svc 2>/dev/null
                sleep 2; warp-cli --accept-tos connect > /dev/null 2>&1
                sleep 3; _3xui_warp_running && echo -e "${GREEN}OK${NC}" || echo -e "${RED}Не подключился${NC}"
                read -p "Enter..." ;;
            5) _self_update ;;
            6) _full_uninstall ;;
            r|R)
                read -p "$(echo -e "${RED}Перезагрузить сервер? (y/n): ${NC}")" c
                [[ "$c" == "y" ]] && reboot ;;
            0|"") return ;;
        esac
    done
}

_backups_menu() {
    clear
    echo -e "\n${CYAN}━━━ Бэкапы и Rollback ━━━${NC}\n"

    local baks; baks=$(ls -t "$BACKUP_DIR"/*.bak.* 2>/dev/null)
    if [ -z "$baks" ]; then
        echo -e "${YELLOW}Бэкапов нет.${NC}"
        read -p "Enter..."; return
    fi

    local -a bak_arr=()
    local i=1
    while IFS= read -r b; do
        local ts; ts=$(basename "$b" | grep -oE '[0-9]{10,}$')
        local dt; dt=$(date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
        local size; size=$(du -sh "$b" 2>/dev/null | cut -f1)
        echo -e "  ${YELLOW}[$i]${NC} ${dt}  ${WHITE}$(basename "$b")${NC}  ${size}"
        bak_arr+=("$b")
        ((i++))
    done <<< "$baks"

    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    read -p "Rollback (номер или 0): " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#bak_arr[@]} )) || return

    local bak="${bak_arr[$((ch-1))]}"
    read -p "$(echo -e "${YELLOW}Восстановить из ${bak}? (y/n): ${NC}")" c
    [[ "$c" != "y" ]] && return

    if [[ "$bak" == *"x-ui.db"* ]]; then
        cp "$bak" /etc/x-ui/x-ui.db
        systemctl restart x-ui > /dev/null 2>&1
        echo -e "${GREEN}[OK] x-ui.db восстановлен.${NC}"
    elif [[ "$bak" == *"config.json"* ]]; then
        local cfg_path="/usr/local/x-ui/bin/config.json"
        [ -f "$cfg_path" ] && cp "$bak" "$cfg_path"
        systemctl restart x-ui > /dev/null 2>&1
        echo -e "${GREEN}[OK] config.json восстановлен.${NC}"
    fi
    log_action "ROLLBACK: $bak"
    read -p "Нажмите Enter..."
}

_check_conflicts() {
    clear
    echo -e "\n${CYAN}━━━ Проверка конфликтов ━━━${NC}\n"

    local has_blocker=0

    # warp-go, amnezia-warp, wireproxy
    for v in warp-go amnezia-warp wireproxy; do
        echo -ne "  ${v}...  "
        command -v "$v" &>/dev/null || systemctl is-active "$v" &>/dev/null 2>&1 && \
            { echo -e "${RED}[BLOCKER] найден${NC}"; has_blocker=1; } || echo -e "${GREEN}✓${NC}"
    done

    # wgcf — только инструмент
    echo -ne "  wgcf...  "
    command -v wgcf &>/dev/null && echo -e "${CYAN}[INFO] CLI утилита${NC}" || echo -e "${GREEN}✓${NC}"

    # Порт WARP
    echo -ne "  Порт ${WARP_SOCKS_PORT}...  "
    if ss -tlnp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT} "; then
        local occ; occ=$(ss -tlnp 2>/dev/null | grep ":${WARP_SOCKS_PORT} " | sed 's/.*users:(("//' | cut -d'"' -f1)
        [ "$occ" = "warp-svc" ] && echo -e "${GREEN}✓ warp-svc${NC}" || \
            { echo -e "${RED}[BLOCKER] занят: ${occ}${NC}"; has_blocker=1; }
    else
        echo -e "${GREEN}✓ свободен${NC}"
    fi

    # Amnezia контейнеры
    if command -v docker &>/dev/null; then
        local amn; amn=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i amnezia)
        if [ -n "$amn" ]; then
            echo -e "\n  ${CYAN}[INFO] Amnezia контейнеры:${NC}"
            echo "$amn" | while read -r c; do
                local ports; ports=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep "^$c" | cut -f2)
                echo -e "         ${WHITE}${c}${NC}  ${ports}"
            done
        fi
    fi

    echo ""
    [ "$has_blocker" -eq 1 ] && \
        echo -e "${RED}Обнаружены конфликты!${NC}" || \
        echo -e "${GREEN}✓ Конфликтов нет${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

_self_update() {
    clear
    echo -e "\n${CYAN}━━━ Обновление govpn ━━━${NC}\n"
    echo -e "${WHITE}Текущая: ${GREEN}v${VERSION}${NC}"
    echo -e "${WHITE}Источник: ${CYAN}${REPO_URL}${NC}\n"

    echo -e "${YELLOW}Загрузка...${NC}"
    local tmp="/tmp/govpn_update.sh"
    curl -fsSL --max-time 30 "$REPO_URL" -o "$tmp" 2>/dev/null || {
        echo -e "${RED}Не удалось загрузить.${NC}"; read -p "Enter..."; return
    }

    head -1 "$tmp" 2>/dev/null | grep -q "#!/bin/bash" || {
        echo -e "${RED}Файл некорректен.${NC}"; rm -f "$tmp"; read -p "Enter..."; return
    }

    local new_ver; new_ver=$(grep '^VERSION=' "$tmp" 2>/dev/null | head -1 | cut -d'"' -f2)
    echo -e "${WHITE}В репо: ${GREEN}v${new_ver:-?}${NC}\n"

    if [ "$new_ver" = "$VERSION" ]; then
        echo -e "${YELLOW}Версия совпадает (v${VERSION}).${NC}"
        echo -e "${WHITE}Принудительно обновить (переустановить)? (y/n):${NC}"
        read -p "> " force
        if [[ "$force" != "y" ]]; then
            rm -f "$tmp"; read -p "Enter..."; return
        fi
    fi

    cp "$INSTALL_PATH" "${BACKUP_DIR}/govpn.bak.$(date +%s)" 2>/dev/null
    cp -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    rm -f "$tmp"
    ln -sf "$INSTALL_PATH" /usr/bin/govpn 2>/dev/null

    echo -e "${GREEN}[OK] Установлена v${new_ver}${NC}"
    log_action "UPDATE: v${VERSION} → v${new_ver}"
    read -p "Нажмите Enter..."
    exec "$INSTALL_PATH"
}

_full_uninstall() {
    clear
    echo -e "\n${RED}━━━ Полное удаление GoVPN ━━━${NC}\n"
    read -p "$(echo -e "${RED}Удалить GoVPN Manager? (y/n): ${NC}")" c1
    [[ "$c1" != "y" ]] && return

    local words=("УДАЛИТЬ" "CONFIRM" "СТЕРЕТЬ")
    local word="${words[$((RANDOM % ${#words[@]}))]}"
    echo -e "${RED}Введите ${WHITE}${word}${RED} для подтверждения:${NC}"
    read -p "> " c2
    [[ "$c2" != "$word" ]] && echo -e "${CYAN}Отменено.${NC}" && read -p "Enter..." && return

    # Удалить правила iptables
    iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn:" | \
        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done
    save_iptables

    rm -rf "$CONF_DIR" "$LOG_FILE"
    rm -f "$INSTALL_PATH" /usr/bin/govpn

    echo -e "${GREEN}GoVPN удалён.${NC}"
    log_action "UNINSTALL"
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  ADGUARD HOME
# ═══════════════════════════════════════════════════════════════

AGH_DIR="/opt/AdGuardHome"
AGH_CONF="${AGH_DIR}/AdGuardHome.yaml"
AGH_CLIENTS_FILE="${CONF_DIR}/adguard_clients.list"
AGH_MARKER_B="# --- GOVPN AGH BEGIN ---"
AGH_MARKER_E="# --- GOVPN AGH END ---"

_agh_running() { systemctl is-active AdGuardHome &>/dev/null 2>&1; }

_agh_installed() { [ -f "${AGH_DIR}/AdGuardHome" ]; }

_agh_port() {
    grep "^  port:" "$AGH_CONF" 2>/dev/null | head -1 | awk '{print $2}' || echo "5335"
}

_agh_check_port() {
    local port="$1"
    ss -tlnup 2>/dev/null | grep -q ":${port} " && return 1 || return 0
}

_agh_ask_port() {
    local default_port="5335"
    # Проверяем 53
    if _agh_check_port 53; then
        default_port="53"
        echo -e "  ${GREEN}✓ Порт 53 свободен${NC}"
    else
        local occupant; occupant=$(ss -tlnup 2>/dev/null | grep ":53 " | \
            sed 's/.*users:(("//' | cut -d'"' -f1 | head -1)
        echo -e "  ${YELLOW}⚠ Порт 53 занят: ${occupant}${NC}"
        echo -e "  ${WHITE}Рекомендуется: ${GREEN}5335${NC}"
    fi

    # Проверяем предложенный порт
    if ! _agh_check_port "$default_port" 2>/dev/null; then
        echo -e "  ${YELLOW}⚠ Порт ${default_port} тоже занят!${NC}"
        default_port="5353"
    fi

    echo -e "\n  ${WHITE}DNS порт для AdGuard Home:${NC}"
    echo -e "  ${CYAN}Enter${NC} — использовать ${GREEN}${default_port}${NC}, или введите свой:"
    read -p "  > " user_port
    if [ -z "$user_port" ]; then
        echo "$default_port"
    else
        validate_port "$user_port" && echo "$user_port" || echo "$default_port"
    fi
}

_agh_install() {
    clear
    echo -e "\n${CYAN}━━━ Установка AdGuard Home ━━━${NC}\n"

    echo -e "${YELLOW}[1/5]${NC} Скачивание AdGuard Home..."
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *) echo -e "${RED}  ✗ Архитектура не поддерживается${NC}"; return 1 ;;
    esac

    local url="https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${arch}.tar.gz"
    mkdir -p /tmp/agh_install
    curl -fsSL "$url" -o /tmp/agh_install/agh.tar.gz 2>/dev/null || {
        echo -e "${RED}  ✗ Не удалось скачать${NC}"; return 1
    }
    tar -xzf /tmp/agh_install/agh.tar.gz -C /tmp/agh_install/ 2>/dev/null
    mkdir -p "$AGH_DIR"
    cp /tmp/agh_install/AdGuardHome/AdGuardHome "$AGH_DIR/"
    chmod +x "${AGH_DIR}/AdGuardHome"
    rm -rf /tmp/agh_install
    echo -e "${GREEN}  ✓${NC}"

    echo -e "${YELLOW}[2/5]${NC} Выбор DNS порта..."
    local dns_port; dns_port=$(_agh_ask_port)
    echo -e "${GREEN}  ✓ Порт: ${dns_port}${NC}"

    echo -e "${YELLOW}[3/5]${NC} Отключение systemd-resolved stub listener..."
    if systemctl is-active systemd-resolved &>/dev/null && [ "$dns_port" = "53" ]; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/govpn.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved > /dev/null 2>&1
        echo -e "${GREEN}  ✓ stub listener отключён${NC}"
    else
        echo -e "${GREEN}  ✓ не нужно (порт ${dns_port})${NC}"
    fi

    echo -e "${YELLOW}[4/5]${NC} Создание конфигурации..."
    cat > "$AGH_CONF" << EOF
bind_host: 0.0.0.0
bind_port: 3000
users:
  - name: admin
    password: \$2a\$10\$NOTSET
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
debug_pprof: false
web_session_ttl: 720
dns:
  bind_hosts:
    - 0.0.0.0
  port: ${dns_port}
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstreams:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
  fallback_dns: []
  upstream_mode: parallel
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: true
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_response_ttl: 10
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_browsing_cache_size: 1048576
  safe_search_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  custom_blocked_response: ""
  filtering_enabled: true
  filters:
    - enabled: true
      url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
      name: AdGuard DNS filter
      id: 1
    - enabled: true
      url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
      name: AdGuard DNS Popup Hosts filter
      id: 2
    - enabled: true
      url: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
      name: StevenBlack unified hosts
      id: 3
  whitelist_filters: []
  user_rules: []
  parental_enabled: false
  safebrowsing_enabled: false
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: true
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
EOF

    save_config "AGH_DNS_PORT" "$dns_port"
    echo -e "${GREEN}  ✓ Конфиг создан${NC}"

    echo -e "${YELLOW}[5/5]${NC} Запуск сервиса..."
    "${AGH_DIR}/AdGuardHome" -s install > /dev/null 2>&1
    systemctl enable AdGuardHome > /dev/null 2>&1
    systemctl start AdGuardHome > /dev/null 2>&1
    sleep 2

    _agh_running && echo -e "${GREEN}  ✓ AdGuard Home запущен${NC}" || {
        echo -e "${RED}  ✗ Не запустился${NC}"
        return 1
    }

    log_action "AGH INSTALL: port=${dns_port}"
    echo -e "\n${GREEN}AdGuard Home установлен!${NC}"
    echo -e "${WHITE}Веб-панель: ${CYAN}http://${MY_IP}:3000${NC}"
    echo -e "${WHITE}DNS порт: ${CYAN}${dns_port}${NC}"
    return 0
}

_agh_apply_clients() {
    local iface; iface=$(_awg_iface)
    local -a selected=("$@")
    local dns_port; dns_port=$(grep "^AGH_DNS_PORT=" "$CONF_FILE" 2>/dev/null | cut -d'"' -f2)
    dns_port="${dns_port:-5335}"

    # Очистить старые правила
    iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn:agh" | \
        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done

    [ "${#selected[@]}" -eq 0 ] && return 0

    for ip in "${selected[@]}"; do
        # Редирект DNS трафика клиента на AdGuard
        iptables -t nat -A PREROUTING -i "$iface" -s "$ip" \
            -p udp --dport 53 -j REDIRECT --to-port "$dns_port" \
            -m comment --comment "govpn:agh:${ip}" > /dev/null 2>&1
        iptables -t nat -A PREROUTING -i "$iface" -s "$ip" \
            -p tcp --dport 53 -j REDIRECT --to-port "$dns_port" \
            -m comment --comment "govpn:agh:${ip}" > /dev/null 2>&1
    done
    save_iptables
}

_agh_patch_start_sh() {
    # Аналогично WARP — для контейнера Amnezia
    local start_sh="/opt/amnezia/start.sh"
    local iface; iface=$(_awg_iface)
    local dns_port; dns_port=$(grep "^AGH_DNS_PORT=" "$CONF_FILE" 2>/dev/null | cut -d'"' -f2)
    dns_port="${dns_port:-5335}"
    local -a selected=("$@")

    docker exec "$AWG_CONTAINER" sh -c \
        "[ -f /opt/amnezia/start.sh.govpn-backup ] || cp '${start_sh}' /opt/amnezia/start.sh.govpn-backup" 2>/dev/null

    local block="${AGH_MARKER_B}"$'\n'
    for ip in "${selected[@]}"; do
        block+="iptables -t nat -C PREROUTING -i ${iface} -s ${ip} -p udp --dport 53 -j REDIRECT --to-port ${dns_port} 2>/dev/null || \\"$'\n'
        block+="    iptables -t nat -A PREROUTING -i ${iface} -s ${ip} -p udp --dport 53 -j REDIRECT --to-port ${dns_port}"$'\n'
        block+="iptables -t nat -C PREROUTING -i ${iface} -s ${ip} -p tcp --dport 53 -j REDIRECT --to-port ${dns_port} 2>/dev/null || \\"$'\n'
        block+="    iptables -t nat -A PREROUTING -i ${iface} -s ${ip} -p tcp --dport 53 -j REDIRECT --to-port ${dns_port}"$'\n'
    done
    block+="${AGH_MARKER_E}"

    docker exec "$AWG_CONTAINER" sh -c \
        "sed -i '/# --- GOVPN AGH BEGIN ---/,/# --- GOVPN AGH END ---/d' '${start_sh}' 2>/dev/null || true"
    docker exec "$AWG_CONTAINER" bash -c "printf '\n%s\n' '${block}' >> '${start_sh}'; chmod +x '${start_sh}'" 2>/dev/null
}

adguard_menu() {
    if ! _agh_installed; then
        clear
        echo -e "\n${CYAN}━━━ AdGuard Home ━━━${NC}\n"
        echo -e "${WHITE}AdGuard Home не установлен.${NC}"
        echo -e "${WHITE}Установить DNS фильтрацию рекламы для клиентов?${NC}\n"
        echo -e "  ${YELLOW}[1]${NC} Установить AdGuard Home"
        echo -e "  ${YELLOW}[0]${NC} Назад"
        read -p "Выбор: " ch
        [ "$ch" = "1" ] && _agh_install || return
        _agh_running || { read -p "Enter..."; return; }
    fi

    # Загружаем список клиентов с AGH
    local -a agh_sel=()
    local agh_loaded=0

    while true; do
        clear
        echo -e "\n${CYAN}━━━ AdGuard Home — DNS фильтрация ━━━${NC}\n"

        local dns_port; dns_port=$(grep "^AGH_DNS_PORT=" "$CONF_FILE" 2>/dev/null | cut -d'"' -f2)
        dns_port="${dns_port:-5335}"

        if _agh_running; then
            echo -e "  ${WHITE}Статус:   ${GREEN}● запущен${NC}"
            echo -e "  ${WHITE}DNS порт: ${CYAN}${dns_port}${NC}"
            echo -e "  ${WHITE}Веб:      ${CYAN}http://${MY_IP}:3000${NC}"
        else
            echo -e "  ${WHITE}Статус:   ${RED}● не запущен${NC}"
        fi
        echo ""

        # Клиенты AWG
        local -a all_ips=()
        if is_amnezia; then
            while IFS= read -r ip; do [ -n "$ip" ] && all_ips+=("$ip"); done <<< "$(_awg_all_clients)"
        fi

        # Также клиенты из iptables правил (для non-Amnezia)
        if [ ${#all_ips[@]} -eq 0 ]; then
            echo -e "${YELLOW}Нет клиентов AWG.${NC}\n"
        else
            if [ "$agh_loaded" -eq 0 ]; then
                while IFS= read -r ip; do [ -n "$ip" ] && agh_sel+=("$ip"); done < \
                    <([ -f "$AGH_CLIENTS_FILE" ] && cat "$AGH_CLIENTS_FILE" || true)
                agh_loaded=1
            fi

            echo -e "${WHITE}Клиенты (DNS фильтрация):${NC}"
            for i in "${!all_ips[@]}"; do
                local ip="${all_ips[$i]}"
                local name; name=$(_awg_client_name "$ip")
                local label="${name:-${ip%/32}}"
                local in_agh=0
                for s in "${agh_sel[@]}"; do [ "$s" = "$ip" ] && in_agh=1; done
                if [ "$in_agh" -eq 1 ]; then
                    echo -e "  ${YELLOW}[$((i+1))]${NC} ${GREEN}✅${NC} ${WHITE}${label}${NC}  ${ip}"
                else
                    echo -e "  ${YELLOW}[$((i+1))]${NC} ${WHITE}☐${NC}  ${WHITE}${label}${NC}  ${ip}"
                fi
            done
            echo ""
        fi

        echo -e "  ${YELLOW}[a]${NC}  Включить всем"
        echo -e "  ${YELLOW}[n]${NC}  Выключить всем"
        echo -e "  ${YELLOW}[s]${NC}  Применить"
        echo -e "  ${YELLOW}[r]${NC}  Перезапустить AdGuard"
        echo -e "  ${RED}[x]${NC}  Удалить AdGuard Home"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch

        case "$ch" in
            [1-9])
                local idx=$((ch-1))
                [ -z "${all_ips[$idx]:-}" ] && continue
                local tip="${all_ips[$idx]}"
                local already=0
                for s in "${agh_sel[@]}"; do [ "$s" = "$tip" ] && already=1; done
                if [ "$already" -eq 1 ]; then
                    local -a tmp=()
                    for s in "${agh_sel[@]}"; do [ -n "$s" ] && [ "$s" != "$tip" ] && tmp+=("$s"); done
                    agh_sel=("${tmp[@]}")
                else
                    agh_sel+=("$tip")
                fi ;;
            a|A) agh_sel=("${all_ips[@]}") ;;
            n|N) agh_sel=() ;;
            s|S)
                echo ""
                echo -e "${YELLOW}[1/3]${NC} Сохраняем список..."
                printf '%s\n' "${agh_sel[@]}" > "$AGH_CLIENTS_FILE"
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[2/3]${NC} Применяем iptables правила..."
                if is_amnezia; then
                    # Внутри контейнера
                    docker exec "$AWG_CONTAINER" sh -c "
                        iptables -t nat -S PREROUTING | grep 'govpn:agh' | \
                            sed 's/^-A /-D /' | while read -r r; do iptables -t nat \$r 2>/dev/null; done
                    " > /dev/null 2>&1
                    local iface; iface=$(_awg_iface)
                    for ip in "${agh_sel[@]}"; do
                        docker exec "$AWG_CONTAINER" sh -c "
                            iptables -t nat -A PREROUTING -i ${iface} -s ${ip} -p udp --dport 53 \
                                -j REDIRECT --to-port ${dns_port} 2>/dev/null || true
                            iptables -t nat -A PREROUTING -i ${iface} -s ${ip} -p tcp --dport 53 \
                                -j REDIRECT --to-port ${dns_port} 2>/dev/null || true
                        " > /dev/null 2>&1
                    done
                else
                    _agh_apply_clients "${agh_sel[@]}"
                fi
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[3/3]${NC} Персистентность (start.sh)..."
                is_amnezia && _agh_patch_start_sh "${agh_sel[@]}"
                echo -e "${GREEN}  ✓${NC}"

                log_action "AGH CLIENTS: ${#agh_sel[@]} с DNS фильтрацией"
                echo -e "\n${GREEN}Применено. DNS трафик выбранных клиентов → AdGuard Home${NC}"
                read -p "Нажмите Enter..." ;;
            r|R)
                systemctl restart AdGuardHome && echo -e "${GREEN}OK${NC}" || echo -e "${RED}Ошибка${NC}"
                sleep 1 ;;
            x|X)
                read -p "$(echo -e "${RED}Удалить AdGuard Home? (y/n): ${NC}")" c
                [ "$c" = "y" ] && {
                    systemctl stop AdGuardHome > /dev/null 2>&1
                    "${AGH_DIR}/AdGuardHome" -s uninstall > /dev/null 2>&1
                    rm -rf "$AGH_DIR"
                    iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn:agh" | \
                        sed 's/^-A /-D /' | while read -r r; do iptables -t nat $r 2>/dev/null; done
                    save_iptables
                    echo -e "${GREEN}Удалён.${NC}"
                    log_action "AGH UNINSTALL"
                    read -p "Enter..."; return
                } ;;
            0|"") return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  УПРАВЛЕНИЕ ПИРАМИ AWG (создание/удаление клиентов)
# ═══════════════════════════════════════════════════════════════

awg_peers_menu() {
    if ! is_amnezia; then
        echo -e "${YELLOW}Amnezia не обнаружен.${NC}"; read -p "Enter..."; return
    fi

    command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1

    local sort_mode="name"  # name | ip | activity

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиенты AWG ━━━${NC}\n"
        echo -e "  ${WHITE}Контейнер: ${CYAN}${AWG_CONTAINER}${NC}  Сортировка: ${YELLOW}${sort_mode}${NC}\n"

        local conf; conf=$(_awg_conf)
        local -a all_ips=()
        while IFS= read -r ip; do [ -n "$ip" ] && all_ips+=("$ip"); done <<< "$(_awg_all_clients)"

        # Кешируем wg show
        local wg_show
        wg_show=$(docker exec "$AWG_CONTAINER" sh -c "wg show $(_awg_iface) 2>/dev/null" 2>/dev/null)

        # Сортировка
        local -a sorted_ips=()
        if [ ${#all_ips[@]} -gt 0 ]; then
            local -a pairs=()
            for ip in "${all_ips[@]}"; do
                local name; name=$(_awg_client_name "$ip")
                local bare="${ip%/32}"
                local hshake
                hshake=$(echo "$wg_show" | \
                    awk "/allowed ips:.*${bare}/{f=1} f && /latest handshake/{print; f=0}" | \
                    sed 's/.*latest handshake: //')
                case "$sort_mode" in
                    name)     pairs+=("${name:-zzz_$bare}|${ip}") ;;
                    ip)       pairs+=("${bare}|${ip}") ;;
                    activity) [ -n "$hshake" ] && pairs+=("0|${ip}") || pairs+=("1|${ip}") ;;
                esac
            done
            while IFS='|' read -r _ ip; do
                sorted_ips+=("$ip")
            done < <(printf '%s\n' "${pairs[@]}" | sort -f)
        fi

        if [ ${#sorted_ips[@]} -gt 0 ]; then
            echo -e "${WHITE}Клиенты:${NC}"
            for i in "${!sorted_ips[@]}"; do
                local ip="${sorted_ips[$i]}"
                local name; name=$(_awg_client_name "$ip")
                local bare="${ip%/32}"
                local hshake
                hshake=$(echo "$wg_show" | \
                    awk "/allowed ips:.*${bare}/{f=1} f && /latest handshake/{print; f=0}" | \
                    sed 's/.*latest handshake: //')
                local status_icon="${RED}●${NC}"
                local status_txt="${RED}не подключён${NC}"
                if [ -n "$hshake" ]; then
                    status_icon="${GREEN}●${NC}"
                    status_txt="${GREEN}${hshake}${NC}"
                fi
                printf "  ${YELLOW}[%d]${NC} %b ${WHITE}%-20s${NC}  ${CYAN}%s${NC}\n" \
                    "$((i+1))" "$status_icon" "${name:-$bare}" "$ip"
                echo -e "       ${status_txt}"
            done
        else
            echo -e "  ${YELLOW}Клиентов нет${NC}"
        fi

        echo ""
        echo -e "  ${YELLOW}[+]${NC}   Добавить клиента"
        [ ${#sorted_ips[@]} -gt 0 ] && echo -e "  ${YELLOW}[номер]${NC} Конфиг / QR код"
        [ ${#sorted_ips[@]} -gt 0 ] && echo -e "  ${YELLOW}[-]${NC}   Удалить клиента"
        echo -e "  ${YELLOW}[/]${NC}   Сменить сортировку (${sort_mode})"
        echo -e "  ${YELLOW}[0]${NC}   Назад"
        echo ""
        read -p "Выбор (Enter = обновить): " ch

        # Пустой Enter — обновить
        [ -z "$ch" ] && continue

        case "$ch" in
            +)  _awg_add_peer ;;
            -)  _awg_del_peer "${sorted_ips[@]}" ;;
            /)
                case "$sort_mode" in
                    name)     sort_mode="ip" ;;
                    ip)       sort_mode="activity" ;;
                    activity) sort_mode="name" ;;
                esac ;;
            0)  return ;;
            *)
                [[ "$ch" =~ ^[0-9]+$ ]] && \
                    (( ch >= 1 && ch <= ${#sorted_ips[@]} )) && \
                    _awg_show_client_menu "${sorted_ips[$((ch-1))]}"
                ;;
        esac
    done
}

_awg_show_client_menu() {
    local client_ip="$1"
    local name; name=$(_awg_client_name "$client_ip")
    local label="${name:-${client_ip%/32}}"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиент: ${WHITE}${label}${CYAN} ━━━${NC}\n"
        echo -e "  ${WHITE}IP:   ${CYAN}${client_ip}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC}  Показать конфиг (текст)"
        echo -e "  ${YELLOW}[2]${NC}  Показать QR код"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " ch
        case "$ch" in
            1) _awg_show_config "$client_ip" ;;
            2) _awg_show_qr "$client_ip" ;;
            0|"") return ;;
        esac
    done
}

_awg_get_client_config() {
    local client_ip="$1"
    local conf; conf=$(_awg_conf)

    # Получаем данные клиента из clientsTable
    local privkey psk
    local client_data
    client_data=$(docker exec "$AWG_CONTAINER" sh -c \
        "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" 2>/dev/null)

    # Ищем приватный ключ в файлах клиентов (если сохранён)
    # В Amnezia приватные ключи хранятся в отдельных файлах или в самом конфиге
    local client_dir="/opt/amnezia/awg"
    local bare="${client_ip%/32}"

    # Ищем сохранённый конфиг клиента
    local saved_conf
    saved_conf=$(docker exec "$AWG_CONTAINER" sh -c \
        "find '${client_dir}' -name '*.conf' 2>/dev/null | xargs grep -l '${bare}' 2>/dev/null | grep -v wg0 | head -1")

    if [ -n "$saved_conf" ]; then
        docker exec "$AWG_CONTAINER" sh -c "cat '${saved_conf}'" 2>/dev/null
        return 0
    fi

    # Если конфиг создан нашим скриптом — ищем в govpn storage
    local govpn_conf="${CONF_DIR}/awg_clients/${bare}.conf"
    [ -f "$govpn_conf" ] && cat "$govpn_conf" && return 0

    return 1
}

_awg_show_config() {
    local client_ip="$1"
    local name; name=$(_awg_client_name "$client_ip")
    clear
    echo -e "\n${CYAN}━━━ Конфиг: ${WHITE}${name:-${client_ip%/32}}${CYAN} ━━━${NC}\n"

    local cfg; cfg=$(_awg_get_client_config "$client_ip")
    if [ -n "$cfg" ]; then
        echo -e "${GREEN}${cfg}${NC}"
    else
        echo -e "${YELLOW}Конфиг не найден.${NC}"
        echo -e "${WHITE}Клиент был добавлен через Amnezia приложение —${NC}"
        echo -e "${WHITE}приватный ключ хранится только на устройстве клиента.${NC}"
        echo -e "${WHITE}Для повторной выдачи: удалите и создайте клиента заново.${NC}"
    fi

    echo ""
    read -p "Нажмите Enter..."
}

_awg_show_qr() {
    local client_ip="$1"
    local name; name=$(_awg_client_name "$client_ip")
    clear
    echo -e "\n${CYAN}━━━ QR код: ${WHITE}${name:-${client_ip%/32}}${CYAN} ━━━${NC}\n"

    local cfg; cfg=$(_awg_get_client_config "$client_ip")
    if [ -z "$cfg" ]; then
        echo -e "${YELLOW}Конфиг не найден.${NC}"
        echo -e "${WHITE}Клиент добавлен через Amnezia — ключ только на устройстве.${NC}"
        echo -e "${WHITE}Удалите и создайте клиента заново через п.5.${NC}"
        echo ""; read -p "Нажмите Enter..."; return
    fi

    echo -e "${WHITE}Формат QR:${NC}"
    echo -e "  ${YELLOW}[1]${NC} WireGuard (.conf — для WireGuard приложения)"
    echo -e "  ${YELLOW}[2]${NC} AmneziaWG (JSON — для Amnezia приложения)"
    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""; read -p "Выбор: " fmt

    if ! command -v qrencode &>/dev/null; then
        echo -e "${YELLOW}Устанавливаю qrencode...${NC}"
        apt-get install -y qrencode > /dev/null 2>&1
    fi

    case "$fmt" in
        1)
            echo -e "\n${WHITE}QR для WireGuard:${NC}\n"
            echo "$cfg" | qrencode -t ansiutf8 2>/dev/null || \
                echo -e "${RED}Ошибка qrencode${NC}"
            ;;
        2)
            # Парсим конфиг в Amnezia JSON формат
            local privkey addr dns endpoint pubkey psk
            local jc jmin jmax s1 s2 h1 h2 h3 h4
            privkey=$(echo "$cfg" | awk '/PrivateKey/{print $3}')
            addr=$(echo "$cfg"    | awk '/^Address/{print $3}')
            dns=$(echo "$cfg"     | awk '/^DNS/{print $3}')
            endpoint=$(echo "$cfg"| awk '/Endpoint/{print $3}')
            pubkey=$(echo "$cfg"  | awk '/PublicKey/{print $3}')
            psk=$(echo "$cfg"     | awk '/PresharedKey/{print $3}')
            jc=$(echo "$cfg"      | awk '/^Jc /{print $3}')
            jmin=$(echo "$cfg"    | awk '/^Jmin /{print $3}')
            jmax=$(echo "$cfg"    | awk '/^Jmax /{print $3}')
            s1=$(echo "$cfg"      | awk '/^S1 /{print $3}')
            s2=$(echo "$cfg"      | awk '/^S2 /{print $3}')
            h1=$(echo "$cfg"      | awk '/^H1 /{print $3}')
            h2=$(echo "$cfg"      | awk '/^H2 /{print $3}')
            h3=$(echo "$cfg"      | awk '/^H3 /{print $3}')
            h4=$(echo "$cfg"      | awk '/^H4 /{print $3}')

            local amn_json
            amn_json="{\"protocol\":\"awg\",\"description\":\"${name:-${client_ip%/32}}\",\"dns1\":\"${dns:-1.1.1.1}\",\"dns2\":\"8.8.8.8\",\"hostName\":\"${endpoint%%:*}\",\"port\":\"${endpoint##*:}\",\"privateKey\":\"${privkey}\",\"publicKey\":\"${pubkey}\",\"presharedKey\":\"${psk}\",\"allowedIPs\":\"0.0.0.0/0\",\"persistentKeepalive\":\"25\",\"Jc\":\"${jc:-4}\",\"Jmin\":\"${jmin:-40}\",\"Jmax\":\"${jmax:-70}\",\"S1\":\"${s1:-0}\",\"S2\":\"${s2:-0}\",\"H1\":\"${h1:-1}\",\"H2\":\"${h2:-2}\",\"H3\":\"${h3:-3}\",\"H4\":\"${h4:-4}\"}"

            echo -e "\n${WHITE}QR для Amnezia:${NC}\n"
            echo "$amn_json" | qrencode -t ansiutf8 2>/dev/null || \
                echo -e "${RED}Ошибка qrencode${NC}"
            ;;
        0|"") return ;;
    esac

    echo ""
    echo -e "${WHITE}Отсканируйте QR в приложении.${NC}"
    read -p "Нажмите Enter..."
}

_awg_next_ip() {
    # Найти следующий свободный IP в подсети 10.8.1.x
    local conf; conf=$(_awg_conf)
    local used
    used=$(docker exec "$AWG_CONTAINER" sh -c "grep 'AllowedIPs' '$conf'" 2>/dev/null | \
        grep -oE '10\.8\.1\.[0-9]+' | sort -t. -k4 -n)
    local i=2
    while echo "$used" | grep -q "10.8.1.${i}"; do ((i++)); done
    echo "10.8.1.${i}"
}

_awg_add_peer() {
    clear
    echo -e "\n${CYAN}━━━ Добавить клиента AWG ━━━${NC}\n"

    echo -e "${WHITE}Имя клиента (например: iPhone, MacBook):${NC}"
    read -p "> " peer_name
    [ -z "$peer_name" ] && return

    echo -e "\n${YELLOW}Генерация ключей...${NC}"

    local privkey pubkey psk client_ip
    privkey=$(docker exec "$AWG_CONTAINER" sh -c "wg genkey" 2>/dev/null)
    pubkey=$(echo "$privkey" | docker exec -i "$AWG_CONTAINER" sh -c "wg pubkey" 2>/dev/null)
    psk=$(docker exec "$AWG_CONTAINER" sh -c "wg genpsk" 2>/dev/null)
    client_ip=$(_awg_next_ip)

    local conf; conf=$(_awg_conf)
    local server_pubkey
    server_pubkey=$(docker exec "$AWG_CONTAINER" sh -c "wg show $(_awg_iface) public-key" 2>/dev/null)
    local server_port
    server_port=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | \
        grep "^${AWG_CONTAINER}" | grep -oE ':[0-9]+->.*udp' | grep -oE '^:[0-9]+' | \
        tr -d ':' | head -1)

    # Выбор endpoint из алиасов
    echo -e "\n${WHITE}Через какой IP клиент будет подключаться?${NC}\n"
    local -a ep_ips=() ep_labels=()

    # Этот сервер — первый
    ep_ips+=("$MY_IP")
    ep_labels+=("Прямой  ${MY_IP}:${server_port}")

    # Серверы из алиасов (кроме текущего)
    if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
        while IFS='=' read -r ip val; do
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
            [ "$ip" = "$MY_IP" ] && continue
            local aname; aname=$(echo "$val" | cut -d'|' -f1)
            local acountry; acountry=$(echo "$val" | cut -d'|' -f3)
            ep_ips+=("$ip")
            ep_labels+=("${aname:-$ip}  ${ip}:${server_port}  (${acountry})")
        done < "$ALIASES_FILE"
    fi

    ep_ips+=("custom")
    ep_labels+=("Ввести вручную")

    for i in "${!ep_labels[@]}"; do
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${ep_labels[$i]}"
    done
    echo ""
    read -p "Выбор [1]: " ep_choice
    [ -z "$ep_choice" ] && ep_choice=1

    local endpoint_ip="${MY_IP}"
    local endpoint_port="${server_port}"

    if [[ "$ep_choice" =~ ^[0-9]+$ ]] && (( ep_choice >= 1 && ep_choice <= ${#ep_ips[@]} )); then
        local sel="${ep_ips[$((ep_choice-1))]}"
        if [ "$sel" = "custom" ]; then
            echo -e "${WHITE}Введите IP:порт (например 155.212.247.249:47684):${NC}"
            read -p "> " custom_ep
            endpoint_ip="${custom_ep%%:*}"
            endpoint_port="${custom_ep##*:}"
        else
            endpoint_ip="$sel"
            # Спросить порт если отличается
            echo -e "${WHITE}Порт (Enter = ${server_port}):${NC}"
            read -p "> " custom_port
            [ -n "$custom_port" ] && endpoint_port="$custom_port"
        fi
    fi

    local server_endpoint="${endpoint_ip}:${endpoint_port}"

    # Параметры обфускации из серверного конфига
    local jc jmin jmax s1 s2 h1 h2 h3 h4
    jc=$(docker exec "$AWG_CONTAINER" sh -c "grep '^Jc' '$conf'" 2>/dev/null | awk '{print $3}')
    jmin=$(docker exec "$AWG_CONTAINER" sh -c "grep '^Jmin' '$conf'" 2>/dev/null | awk '{print $3}')
    jmax=$(docker exec "$AWG_CONTAINER" sh -c "grep '^Jmax' '$conf'" 2>/dev/null | awk '{print $3}')
    s1=$(docker exec "$AWG_CONTAINER" sh -c "grep '^S1' '$conf'" 2>/dev/null | awk '{print $3}')
    s2=$(docker exec "$AWG_CONTAINER" sh -c "grep '^S2' '$conf'" 2>/dev/null | awk '{print $3}')
    h1=$(docker exec "$AWG_CONTAINER" sh -c "grep '^H1' '$conf'" 2>/dev/null | awk '{print $3}')
    h2=$(docker exec "$AWG_CONTAINER" sh -c "grep '^H2' '$conf'" 2>/dev/null | awk '{print $3}')
    h3=$(docker exec "$AWG_CONTAINER" sh -c "grep '^H3' '$conf'" 2>/dev/null | awk '{print $3}')
    h4=$(docker exec "$AWG_CONTAINER" sh -c "grep '^H4' '$conf'" 2>/dev/null | awk '{print $3}')

    # Собираем конфиг клиента
    local client_conf
    client_conf="[Interface]
PrivateKey = ${privkey}
Address = ${client_ip}/32
DNS = ${MY_IP}
Jc = ${jc:-4}
Jmin = ${jmin:-40}
Jmax = ${jmax:-70}
S1 = ${s1:-0}
S2 = ${s2:-0}
H1 = ${h1:-1}
H2 = ${h2:-2}
H3 = ${h3:-3}
H4 = ${h4:-4}

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0
Endpoint = ${server_endpoint}
PersistentKeepalive = 25"

    # Сохраняем конфиг на диск для повторной выдачи
    local bare="${client_ip%/32}"
    mkdir -p "${CONF_DIR}/awg_clients"
    echo "$client_conf" > "${CONF_DIR}/awg_clients/${bare}.conf"
    chmod 600 "${CONF_DIR}/awg_clients/${bare}.conf"

    # Добавить пир в конфиг контейнера
    docker exec "$AWG_CONTAINER" sh -c "
printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
    '${pubkey}' '${psk}' '${client_ip%/32}' >> '$conf'
" 2>/dev/null

    # Обновить clientsTable
    local ts; ts=$(date -u '+%a %b %d %T %Y')
    docker exec "$AWG_CONTAINER" python3 -c "
import json
try:
    with open('/opt/amnezia/awg/clientsTable') as f:
        data = json.load(f)
except:
    data = []
data.append({
    'clientId': '${pubkey}',
    'userData': {
        'clientName': '${peer_name}',
        'allowedIps': '${client_ip}/32',
        'creationDate': '${ts}',
        'dataReceived': '0 B',
        'dataSent': '0 B',
        'latestHandshake': 'never'
    }
})
with open('/opt/amnezia/awg/clientsTable', 'w') as f:
    json.dump(data, f, indent=4)
" 2>/dev/null

    # Применить без перезапуска
    docker exec "$AWG_CONTAINER" bash -c \
        "wg addconf $(_awg_iface) <(printf '[Peer]\nPublicKey = ${pubkey}\nPresharedKey = ${psk}\nAllowedIPs = ${client_ip}/32\n')" \
        2>/dev/null || \
        docker exec "$AWG_CONTAINER" sh -c \
            "wg syncconf $(_awg_iface) <(wg-quick strip '$conf')" 2>/dev/null

    echo -e "${GREEN}  ✓ Клиент создан: ${peer_name} (${client_ip})${NC}\n"
    log_action "AWG PEER ADD: ${peer_name} ${client_ip}"

    # Показываем конфиг и QR сразу
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Конфиг:${NC}\n"
    echo -e "${GREEN}${client_conf}${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if command -v qrencode &>/dev/null; then
        echo -e "\n${WHITE}QR код:${NC}\n"
        echo "$client_conf" | qrencode -t ansiutf8
    fi

    echo -e "\n${WHITE}Конфиг сохранён: ${CYAN}${CONF_DIR}/awg_clients/${bare}.conf${NC}"
    echo -e "${WHITE}Его можно получить повторно через п.5 → номер клиента.${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

_awg_del_peer() {
    local -a sorted_ips=("$@")
    clear
    echo -e "\n${CYAN}━━━ Удалить клиента AWG ━━━${NC}\n"

    local conf; conf=$(_awg_conf)

    if [ ${#sorted_ips[@]} -eq 0 ]; then
        while IFS= read -r ip; do [ -n "$ip" ] && sorted_ips+=("$ip"); done <<< "$(_awg_all_clients)"
    fi

    [ ${#sorted_ips[@]} -eq 0 ] && echo -e "${YELLOW}Нет клиентов.${NC}" && read -p "Enter..." && return

    for i in "${!sorted_ips[@]}"; do
        local ip="${sorted_ips[$i]}"
        local name; name=$(_awg_client_name "$ip")
        echo -e "  ${YELLOW}[$((i+1))]${NC} ${WHITE}${name:-${ip%/32}}${NC}  ${ip}"
    done
    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    read -p "Выбор: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#sorted_ips[@]} )) || return

    local del_ip="${sorted_ips[$((ch-1))]}"
    local del_name; del_name=$(_awg_client_name "$del_ip")
    local bare="${del_ip%/32}"

    read -p "$(echo -e "${RED}Удалить ${del_name:-$del_ip}? (y/n): ${NC}")" c
    [ "$c" != "y" ] && return

    # Найти pubkey клиента из конфига через awk (python3 может отсутствовать)
    local del_pubkey
    del_pubkey=$(docker exec "$AWG_CONTAINER" sh -c "
        awk '
            /\[Peer\]/ { in_peer=1; pk=\"\"; aip=\"\" }
            in_peer && /PublicKey/ { pk=\$3 }
            in_peer && /AllowedIPs/ && \$3 ~ /^${bare}\// { print pk; in_peer=0 }
        ' '$conf'
    " 2>/dev/null)

    # Удалить из активного wg
    [ -n "$del_pubkey" ] && \
        docker exec "$AWG_CONTAINER" sh -c "wg set $(_awg_iface) peer '${del_pubkey}' remove" 2>/dev/null

    # Удалить блок [Peer] из конфига через awk
    docker exec "$AWG_CONTAINER" sh -c "
        awk '
            /\[Peer\]/ { block=\"\[Peer\]\n\"; in_peer=1; skip=0; next }
            in_peer {
                block = block \$0 \"\n\"
                if (/AllowedIPs/ && \$0 ~ /${bare}\//) skip=1
                if (/^\[/ && !/\[Peer\]/) { in_peer=0; if (!skip) printf \"%s\", block; print; next }
            }
            !in_peer { print }
            END { if (in_peer && !skip) printf \"%s\", block }
        ' '$conf' > /tmp/wg_new.conf && mv /tmp/wg_new.conf '$conf'
    " 2>/dev/null

    # Удалить из clientsTable через awk/python (если есть)
    docker exec "$AWG_CONTAINER" sh -c "
        if command -v python3 >/dev/null 2>&1; then
            python3 -c \"
import json
try:
    with open('/opt/amnezia/awg/clientsTable') as f:
        data = json.load(f)
    data = [c for c in data
            if c.get('userData',{}).get('allowedIps','').split('/')[0] != '${bare}']
    with open('/opt/amnezia/awg/clientsTable', 'w') as f:
        json.dump(data, f, indent=4)
except: pass
\"
        fi
    " 2>/dev/null

    # Удалить сохранённый конфиг
    rm -f "${CONF_DIR}/awg_clients/${bare}.conf"

    echo -e "${GREEN}  ✓ Удалён: ${del_name:-$del_ip}${NC}"
    log_action "AWG PEER DEL: ${del_name} ${del_ip}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ═══════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear

        # Шапка
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        echo -e "${WHITE}  GoVPN Manager v${VERSION}${NC}  ${CYAN}Режим: ${MODE_LABEL}${NC}"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}IP:   ${GREEN}${MY_IP}${NC}   ${WHITE}Iface: ${CYAN}${IFACE}${NC}"

        # Цепочка из алиасов
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            local chain=""
            while IFS='=' read -r ip val; do
                [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
                local n; n=$(echo "$val" | cut -d'|' -f1)
                local node="${n:-$ip}"
                [ "$ip" = "$MY_IP" ] && node="${CYAN}${node}*${NC}"
                [ -z "$chain" ] && chain="${node}" || chain="${chain} ${WHITE}→${NC} ${node}"
            done < "$ALIASES_FILE"
            is_3xui && _3xui_warp_running && chain="${chain} ${WHITE}→${NC} ${GREEN}CF${NC}"
            echo -e "  ${WHITE}Цепь: ${chain}${NC}"
        fi

        # WARP статус
        echo -e "  ${WHITE}WARP: $(warp_overall_status)${NC}"

        # AdGuard статус
        if _agh_installed; then
            local agh_st
            _agh_running && agh_st="${GREEN}● запущен (DNS :$(_agh_port))${NC}" || \
                agh_st="${RED}● не запущен${NC}"
            echo -e "  ${WHITE}AGH:  ${agh_st}"
        fi

        echo -e "${MAGENTA}──────────────────────────────────────────────${NC}"

        # Адаптивное меню
        echo -e " ${CYAN}── ОСНОВНОЕ ─────────────────────────${NC}"
        if ! is_bridge; then
            echo -e "  ${GREEN}1)  ★ Настроить WARP${NC}  ${CYAN}(мастер)${NC}"
            echo -e "  2)  Тест WARP"
        fi
        if is_amnezia; then
            echo -e "  3)  Клиенты → WARP"
            echo -e "  4)  DNS фильтрация (AdGuard)"
            echo -e "  5)  Управление клиентами AWG"
        fi
        echo -e " ${CYAN}── СЕТЬ ─────────────────────────────${NC}"
        echo -e "  6)  iptables проброс"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e "  7)  Серверы, скорость, тесты"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e "  8)  Система и управление"
        echo -e "  0)  Выход"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        read -p "Выбор: " ch

        [ -z "$ch" ] && continue

        case "$ch" in
            1) ! is_bridge && warp_setup_wizard ;;
            2) ! is_bridge && warp_test ;;
            3) is_amnezia && awg_clients_menu ;;
            4) is_amnezia && adguard_menu ;;
            5) is_amnezia && awg_peers_menu ;;
            6) iptables_menu ;;
            7) tools_menu ;;
            8) system_menu ;;
            0)
                clear
                [ ! -x "$INSTALL_PATH" ] && {
                    ln -sf "$(readlink -f "$0")" "$INSTALL_PATH" 2>/dev/null
                    ln -sf "$INSTALL_PATH" /usr/bin/govpn 2>/dev/null
                }
                exit 0 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  ЗАПУСК
# ═══════════════════════════════════════════════════════════════

run_startup() {
    local total=5 s=0
    clear; echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║              GoVPN Manager v${VERSION} — Загрузка                      ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ((s++)); printf "  ${CYAN}[%d/%d]${NC}  Проверка root...\n" "$s" "$total"
    check_root

    ((s++)); printf "  ${CYAN}[%d/%d]${NC}  Зависимости...\n" "$s" "$total"
    check_deps

    ((s++)); printf "  ${CYAN}[%d/%d]${NC}  Конфигурация...\n" "$s" "$total"
    init_config; detect_interface; prepare_system

    ((s++)); printf "  ${CYAN}[%d/%d]${NC}  Внешний IP...\n" "$s" "$total"
    get_my_ip

    ((s++)); printf "  ${CYAN}[%d/%d]${NC}  Определение режима...\n" "$s" "$total"
    detect_mode

    # Установка команды
    local self; self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [ "$self" != "$INSTALL_PATH" ]; then
        if [ -f "$self" ] && [ "$self" != "/dev/stdin" ]; then
            cp -f "$self" "$INSTALL_PATH"
        else
            curl -fsSL "$REPO_URL" -o "$INSTALL_PATH" 2>/dev/null
        fi
        chmod +x "$INSTALL_PATH"
    fi
    ln -sf "$INSTALL_PATH" /usr/bin/govpn 2>/dev/null
    export PATH="/usr/local/bin:$PATH"

    echo ""
    echo -e "  ${GREEN}✅ Готов!${NC}  Режим: ${CYAN}${MODE_LABEL}${NC}  IP: ${GREEN}${MY_IP}${NC}"
    echo ""
    sleep 1
    show_menu
}

# ═══════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
    rollback)
        init_config
        [ -z "${2:-}" ] && echo "Использование: govpn rollback <файл>" && exit 1
        [ ! -f "$2" ] && echo "Файл не найден: $2" && exit 1
        if [[ "$2" == *"x-ui.db"* ]]; then
            cp "$2" /etc/x-ui/x-ui.db && systemctl restart x-ui && echo "OK"
        elif [[ "$2" == *"config.json"* ]]; then
            cp "$2" /usr/local/x-ui/bin/config.json && systemctl restart x-ui && echo "OK"
        fi ;;
    *)
        run_startup ;;
esac
