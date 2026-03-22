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
    iptables -t nat -S PREROUTING 2>/dev/null | \
        grep -E "govpn:" | \
        while read -r rule; do
            local proto port dest
            proto=$(echo "$rule" | grep -oP '\-p \K\w+')
            port=$(echo "$rule" | grep -oP 'dpt:\K[0-9]+')
            dest=$(echo "$rule" | grep -oP 'to:\K[\d.:]+')
            [ -n "$proto" ] && [ -n "$port" ] && [ -n "$dest" ] && \
                echo "${proto}|${port}|${dest}"
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

        # Показать активные правила
        local rules; rules=$(get_rules_list)
        if [ -n "$rules" ]; then
            echo -e "${WHITE}Активные правила:${NC}"
            while IFS='|' read -r proto port dest; do
                local dest_ip="${dest%:*}" dest_port="${dest#*:}"
                echo -e "  ${GREEN}●${NC} ${proto} :${port} → $(fmt_ip "$dest_ip"):${dest_port}"
            done <<< "$rules"
            echo ""
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
                    echo -e "${GREEN}Сброшено.${NC}"; sleep 1
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
    local -a rule_arr=()
    local i=1
    while IFS='|' read -r proto port dest; do
        echo -e "  ${YELLOW}[$i]${NC} ${proto} :${port} → ${dest}"
        rule_arr+=("${proto}|${port}|${dest}")
        ((i++))
    done <<< "$rules"
    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    read -p "Выбор: " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#rule_arr[@]} )) || return

    IFS='|' read -r proto port dest <<< "${rule_arr[$((ch-1))]}"
    local comment="govpn:${port}:${proto}"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "$comment" | \
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
    echo -e "${WHITE}Доступна: ${GREEN}v${new_ver:-?}${NC}"

    [ "$new_ver" = "$VERSION" ] && {
        echo -e "${GREEN}Уже актуальная версия.${NC}"; rm -f "$tmp"; read -p "Enter..."; return
    }

    cp "$INSTALL_PATH" "${BACKUP_DIR}/govpn.bak.$(date +%s)" 2>/dev/null
    cp -f "$tmp" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"; rm -f "$tmp"

    # Symlink
    ln -sf "$INSTALL_PATH" /usr/bin/govpn 2>/dev/null

    echo -e "${GREEN}[OK] Обновлён до v${new_ver}${NC}"
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
        echo -e "${MAGENTA}──────────────────────────────────────────────${NC}"

        # Адаптивное меню
        echo -e " ${CYAN}── ОСНОВНОЕ ─────────────────────────${NC}"
        if ! is_bridge; then
            echo -e "  ${GREEN}1)  ★ Настроить WARP${NC}  ${CYAN}(мастер)${NC}"
            echo -e "  2)  Тест WARP"
        fi
        if is_amnezia; then
            echo -e "  3)  Клиенты Amnezia → WARP"
        fi
        echo -e " ${CYAN}── СЕТЬ ─────────────────────────────${NC}"
        echo -e "  4)  iptables проброс"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e "  5)  Серверы, скорость, тесты"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e "  6)  Система и управление"
        echo -e "  0)  Выход"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        read -p "Выбор: " ch

        [ -z "$ch" ] && continue

        case "$ch" in
            1) ! is_bridge && warp_setup_wizard ;;
            2) ! is_bridge && warp_test ;;
            3) is_amnezia && awg_clients_menu ;;
            4) iptables_menu ;;
            5) tools_menu ;;
            6) system_menu ;;
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
