#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  GoVPN Manager v4.0
#  Автоопределение режима · WARP мастер · iptables каскад
#  Поддержка: 3X-UI · AmneziaWG · Bridge · Combo
# ══════════════════════════════════════════════════════════════

VERSION="5.11"
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
    if [ -f "$CONF_FILE" ]; then
        # Очищаем escape-коды ANSI если они попали в конфиг
        if grep -qP '\x1b\[' "$CONF_FILE" 2>/dev/null; then
            local tmp_conf; tmp_conf=$(mktemp)
            sed 's/\x1b\[[0-9;]*m//g' "$CONF_FILE" > "$tmp_conf"
            mv "$tmp_conf" "$CONF_FILE"
        fi
        source "$CONF_FILE" 2>/dev/null || true
    fi
    WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"
}

save_config() {
    local key="$1"
    # Полностью убираем ANSI escape из значения
    local val; val=$(echo "$2" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\033')
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$CONF_FILE"
    else
        echo "${key}=\"${val}\"" >> "$CONF_FILE"
    fi
    source "$CONF_FILE" 2>/dev/null || true
}

# Транслитерация RU раскладки → EN для букв-команд в меню
# Позволяет вводить a/n/s/y и их русские аналоги а/н/с/у
ru_to_en() {
    local input="$1"
    case "$input" in
        # Цифры — без изменений
        [0-9]) echo "$input"; return ;;
        # Русские буквы → английские эквиваленты по позиции на клавиатуре
        "й"|"Й") echo "q" ;;  "ц"|"Ц") echo "w" ;;  "у"|"У") echo "e" ;;
        "к"|"К") echo "r" ;;  "е"|"Е") echo "t" ;;  "н"|"Н") echo "y" ;;
        "г"|"Г") echo "u" ;;  "ш"|"Ш") echo "i" ;;  "щ"|"Щ") echo "o" ;;
        "з"|"З") echo "p" ;;  "ф"|"Ф") echo "a" ;;  "ы"|"Ы") echo "s" ;;
        "в"|"В") echo "d" ;;  "а"|"А") echo "f" ;;  "п"|"П") echo "g" ;;
        "р"|"Р") echo "h" ;;  "о"|"О") echo "j" ;;  "л"|"Л") echo "k" ;;
        "д"|"Д") echo "l" ;;  "я"|"Я") echo "z" ;;  "ч"|"Ч") echo "x" ;;
        "с"|"С") echo "c" ;;  "м"|"М") echo "v" ;;  "и"|"И") echo "b" ;;
        "т"|"Т") echo "n" ;;  "ь"|"Ь") echo "m" ;;
        *) echo "$input" ;;
    esac
}

# Читает input с поддержкой RU раскладки
read_choice() {
    local prompt="${1:-Выбор: }"
    local ch
    read -p "$prompt" ch
    ru_to_en "$ch"
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

    # Проверяем AmneziaWG — ищем контейнер с наибольшим числом клиентов
    if command -v docker &>/dev/null; then
        local best_ct="" best_count=0
        while IFS= read -r ct; do
            [ -z "$ct" ] && continue
            # Считаем клиентов в clientsTable (надёжнее чем конфиг)
            local count=0
            count=$(docker exec "$ct" sh -c \
                "grep -c 'clientId' /opt/amnezia/awg/clientsTable 2>/dev/null || echo 0" 2>/dev/null)
            count=$(echo "$count" | tr -d '[:space:]')
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            # Если clientsTable пуст — считаем пиры в конфиге
            if [ "$count" -eq 0 ]; then
                for f in /opt/amnezia/awg/awg0.conf /opt/amnezia/awg/wg0.conf; do
                    if docker exec "$ct" sh -c "[ -f '$f' ]" 2>/dev/null; then
                        count=$(docker exec "$ct" sh -c \
                            "grep -c '\[Peer\]' '$f' 2>/dev/null || echo 0" 2>/dev/null)
                        count=$(echo "$count" | tr -d '[:space:]')
                        break
                    fi
                done
            fi
            if (( count > best_count )); then
                best_count=$count
                best_ct=$ct
            fi
        done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg")

        # Fallback — любой amnezia контейнер
        if [ -z "$best_ct" ]; then
            best_ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg" | head -1)
        fi

        if [ -n "$best_ct" ]; then
            has_amnezia=1
            AWG_CONTAINER="$best_ct"
        fi
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
    local raw
    raw=$(docker exec "$AWG_CONTAINER" sh -c \
        "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" 2>/dev/null)

    # Извлекаем allowedIps — работает и с однострочным и с многострочным JSON
    local result
    result=$(echo "$raw" | grep -o '"allowedIps"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/.*"allowedIps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | \
        grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | \
        awk '{if($0 !~ /\//) print $0"/32"; else print $0}')

    # Fallback — конфиг
    if [ -z "$result" ]; then
        local conf; conf=$(_awg_conf)
        result=$(docker exec "$AWG_CONTAINER" sh -c \
            "grep 'AllowedIPs' '$conf' 2>/dev/null" 2>/dev/null | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32')
    fi

    echo "$result"
}

_awg_client_name() {
    local ip="${1%/32}"
    local raw
    raw=$(docker exec "$AWG_CONTAINER" sh -c \
        "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" 2>/dev/null)
    # Ищем clientName в той же строке или блоке где есть нужный IP
    echo "$raw" | grep -B5 "\"allowedIps\".*${ip}" | \
        grep -o '"clientName"[[:space:]]*:[[:space:]]*"[^"]*"' | \
        sed 's/.*"clientName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | \
        head -1
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

_awg_cleanup_legacy() {
    # Удалить устаревшие глобальные fwmark правила
    local iface; iface=$(_awg_iface)
    local start_sh="/opt/amnezia/start.sh"
    docker exec "$AWG_CONTAINER" sh -c "
        iptables -t mangle -D PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true
        ip rule list | awk '/fwmark.*lookup 100/{print \$1}' | sed 's/://' | sort -rn | \
            while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done
        sed -i '/iptables -t mangle -A PREROUTING.*MARK --set-mark 100/d' '${start_sh}' 2>/dev/null || true
        sed -i '/ip rule add fwmark 100 lookup 100/d' '${start_sh}' 2>/dev/null || true
    " > /dev/null 2>&1
}

_awg_apply_rules() {
    local -a selected=("$@")
    local iface; iface=$(_awg_iface)

    # Полная очистка — и ip rule from IP и fwmark (старый подход)
    docker exec "$AWG_CONTAINER" sh -c "
        ip rule list | awk '/lookup 100/{print \$1}' | sed 's/://' | sort -rn | \
            while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done
        ip rule del fwmark 0x64 lookup 100 2>/dev/null || true
        ip rule del fwmark 100 lookup 100 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true
        iptables -t nat -S POSTROUTING 2>/dev/null | grep 'warp.*MASQUERADE' | \
            sed 's/^-A /-D /' | while read -r r; do iptables -t nat \$r 2>/dev/null || true; done
        ip route flush table 100 2>/dev/null || true
    " > /dev/null 2>&1

    [ "${#selected[@]}" -eq 0 ] && return 0

    # Маршрут через warp
    docker exec "$AWG_CONTAINER" sh -c \
        "ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"

    # Per-client ip rule from IP (без fwmark)
    local prio=100
    for ip in "${selected[@]}"; do
        local bare="${ip%/32}"
        docker exec "$AWG_CONTAINER" sh -c "
            ip rule add from ${bare} table 100 priority ${prio} 2>/dev/null || true
            iptables -t nat -C POSTROUTING -s ${bare}/32 -o warp -j MASQUERADE 2>/dev/null || \
            iptables -t nat -I POSTROUTING 1 -s ${bare}/32 -o warp -j MASQUERADE 2>/dev/null || true
        " > /dev/null 2>&1
        ((prio++))
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
        # Очистка устаревших глобальных правил при старте
        block+="iptables -t mangle -D PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true"$'\n'
        block+="ip rule del fwmark 0x64 lookup 100 2>/dev/null || true"$'\n'
        block+="ip rule del fwmark 100 lookup 100 2>/dev/null || true"$'\n'
        block+="ip rule list | awk '/fwmark.*lookup 100/{print \$1}' | sed 's/://' | sort -rn | while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done"$'\n'
        # Таблица маршрутизации
        block+="ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
        # Per-client правила
        local prio=100
        for ip in "${selected[@]}"; do
            local bare="${ip%/32}"
            block+="ip rule add from ${bare} table 100 priority ${prio} 2>/dev/null || true"$'\n'
            block+="iptables -t nat -C POSTROUTING -s ${bare}/32 -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s ${bare}/32 -o warp -j MASQUERADE 2>/dev/null || true"$'\n'
            ((prio++))
        done
    fi
    block+="${AWG_MARKER_E}"

    # Удалить старый GOVPN блок (все варианты названий)
    docker exec "$AWG_CONTAINER" sh -c "
        sed -i '/# --- GOVPN WARP BEGIN ---/,/# --- GOVPN WARP END ---/d' '${start_sh}' 2>/dev/null || true
        sed -i '/# --- WARP BEGIN ---/,/# --- WARP END ---/d' '${start_sh}' 2>/dev/null || true
    " 2>/dev/null

    # Вставить ПОСЛЕ WARP-MANAGER END если есть, иначе перед tail
    docker exec "$AWG_CONTAINER" bash -c "
tmpf=\$(mktemp)
if grep -qF '# --- WARP-MANAGER END ---' '${start_sh}'; then
    while IFS= read -r line; do
        echo \"\$line\"
        if echo \"\$line\" | grep -qF '# --- WARP-MANAGER END ---'; then
            printf '%s\n' '${block}'
        fi
    done < '${start_sh}' > \"\$tmpf\"
elif grep -qF 'tail -f /dev/null' '${start_sh}'; then
    while IFS= read -r line; do
        if echo \"\$line\" | grep -qF 'tail -f /dev/null'; then
            printf '%s\n' '${block}'
        fi
        echo \"\$line\"
    done < '${start_sh}' > \"\$tmpf\"
else
    cp '${start_sh}' \"\$tmpf\"
    printf '\n%s\n' '${block}' >> \"\$tmpf\"
fi
mv \"\$tmpf\" '${start_sh}'
chmod +x '${start_sh}'
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

    # Проверяем текущее состояние
    local amn_installed=0 amn_running=0 amn_ip=""
    local xui_installed=0 xui_running=0 xui_ip=""

    if is_amnezia; then
        _awg_warp_running 2>/dev/null && amn_running=1
        docker exec "$AWG_CONTAINER" sh -c "[ -f '${AWG_WARP_CONF}' ]" 2>/dev/null && amn_installed=1
        [ "$amn_running" -eq 1 ] && amn_ip=$(_awg_warp_ip)
    fi
    if is_3xui; then
        _3xui_warp_installed && xui_installed=1
        _3xui_warp_running && xui_running=1
        [ "$xui_running" -eq 1 ] && xui_ip=$(_3xui_warp_ip)
    fi

    # Если WARP уже работает — показать состояние и предложить действия
    local already_running=0
    [ "$amn_running" -eq 1 ] && already_running=1
    [ "$xui_running" -eq 1 ] && already_running=1

    if [ "$already_running" -eq 1 ]; then
        echo -e "${GREEN}━━━ WARP уже настроен ━━━${NC}\n"
        is_amnezia && [ "$amn_running" -eq 1 ] && \
            echo -e "  ${WHITE}Amnezia:  ${GREEN}● ${amn_ip}${NC}"
        is_3xui && [ "$xui_running" -eq 1 ] && \
            echo -e "  ${WHITE}3X-UI:    ${GREEN}● ${xui_ip}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC}  Статус и тест"
        echo -e "  ${YELLOW}[2]${NC}  Перевыпустить ключ (новый аккаунт WARP)"
        echo -e "  ${YELLOW}[3]${NC}  Переустановить полностью"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " warp_action
        case "$warp_action" in
            1) warp_test; return ;;
            2) # Перевыпуск — только wgcf регистрация заново
                clear
                echo -e "\n${CYAN}━━━ Перевыпуск ключа WARP ━━━${NC}\n"
                if is_amnezia && [ "$amn_installed" -eq 1 ]; then
                    echo -e "${YELLOW}Регистрируем новый аккаунт WARP...${NC}"
                    _awg_create_warp_conf && {
                        echo -e "${GREEN}  ✓ Новый ключ создан${NC}"
                        echo -e "${YELLOW}  Перезапускаю туннель...${NC}"
                        docker exec "$AWG_CONTAINER" sh -c \
                            "wg-quick down '${AWG_WARP_CONF}' 2>/dev/null; wg-quick up '${AWG_WARP_CONF}' 2>/dev/null" 2>/dev/null
                        sleep 3
                        local new_ip; new_ip=$(_awg_warp_ip)
                        echo -e "${GREEN}  ✓ Новый IP: ${new_ip}${NC}"
                        log_action "AWG WARP REKEY: ${new_ip}"
                    } || echo -e "${RED}  ✗ Ошибка перевыпуска${NC}"
                fi
                read -p "Нажмите Enter..."; return ;;
            3) : ;; # продолжаем к полной установке
            *) return ;;
        esac
    fi

    # Полная установка
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
        echo -e "${WHITE}Используйте iptables проброс (п.6).${NC}"
        read -p "Enter..."; return
    fi

    local ok=0
    [ "$do_3xui" -eq 1 ] && { _3xui_install_warp && ok=1 || true; echo ""; }
    [ "$do_amnezia" -eq 1 ] && { _awg_install_warp && ok=1 || true; echo ""; }

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

    # Дать возможность сменить контейнер если их несколько
    local -a containers=()
    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg" | sort)
    if [ "${#containers[@]}" -gt 1 ]; then
        clear
        echo -e "\n${CYAN}━━━ Выбор контейнера ━━━${NC}\n"
        for i in "${!containers[@]}"; do
            local ct="${containers[$i]}"
            local cnt; cnt=$(docker exec "$ct" sh -c \
                "grep -c 'clientId' /opt/amnezia/awg/clientsTable 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
            local active; active=$(docker exec "$ct" sh -c \
                "wg show 2>/dev/null | grep -c 'latest handshake'" 2>/dev/null | tr -d '[:space:]')
            local mark=""
            [ "$ct" = "$AWG_CONTAINER" ] && mark=" ${CYAN}(текущий)${NC}"
            echo -e "  ${YELLOW}[$((i+1))]${NC} ${WHITE}${ct}${NC}  клиентов: ${GREEN}${cnt:-0}${NC}  активных: ${GREEN}${active:-0}${NC}${mark}"
        done
        echo -e "  ${YELLOW}[0]${NC} Назад"
        echo ""
        read -p "Выбор (Enter = ${AWG_CONTAINER}): " ct_choice
        if [ -z "$ct_choice" ]; then
            : # оставить текущий
        elif [ "$ct_choice" = "0" ]; then
            return
        elif [[ "$ct_choice" =~ ^[0-9]+$ ]] && (( ct_choice >= 1 && ct_choice <= ${#containers[@]} )); then
            AWG_CONTAINER="${containers[$((ct_choice-1))]}"
        fi
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
            local octet="${ip%/32}"; octet="${octet##*.}"
            local in_warp=0
            for s in "${sel_ips[@]}"; do [ "$s" = "$ip" ] && in_warp=1; done
            if [ "$in_warp" -eq 1 ]; then
                echo -e "  ${YELLOW}[${octet}]${NC} ${GREEN}✅${NC} ${WHITE}${label}${NC}  ${ip}"
            else
                echo -e "  ${YELLOW}[${octet}]${NC} ${WHITE}☐${NC}  ${WHITE}${label}${NC}  ${ip}"
            fi
        done

        echo ""
        echo -e "  ${YELLOW}[a]${NC}  Все через WARP"
        echo -e "  ${YELLOW}[n]${NC}  Отключить всех"
        echo -e "  ${YELLOW}[s]${NC}  Применить"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")

        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        if [[ "$ch" =~ ^[0-9]+$ ]]; then
            # Ищем IP по последнему октету
            local tip=""
            for ip in "${all_ips[@]}"; do
                local oct="${ip%/32}"; oct="${oct##*.}"
                [ "$oct" = "$ch" ] && tip="$ip" && break
            done
            if [ -n "$tip" ]; then
                local already=0
                for s in "${sel_ips[@]}"; do [ "$s" = "$tip" ] && already=1; done
                if [ "$already" -eq 1 ]; then
                    local -a tmp=()
                    for s in "${sel_ips[@]}"; do [ -n "$s" ] && [ "$s" != "$tip" ] && tmp+=("$s"); done
                    sel_ips=("${tmp[@]}")
                else
                    sel_ips+=("$tip")
                fi
            fi
        else
        case "$ch" in
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
        esac
        fi
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
        ch=$(read_choice "Выбор: ")

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

    # IP exit-ноды
    local dest_ip=""
    while true; do
        echo -e "${WHITE}Введите IP адрес exit-ноды (куда перенаправить):${NC}"
        read -p "> " dest_ip
        [ -z "$dest_ip" ] && echo -e "${RED}Нельзя оставить пустым.${NC}" && continue
        [[ "$dest_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        echo -e "${RED}Некорректный IP. Пример: 85.192.26.32${NC}"
    done

    # Порт
    local port=""
    local hint=""
    case "$label" in
        *WireGuard*|*Amnezia*) hint=" (стандартный AWG: 47684 или 51820)" ;;
        *VLESS*) hint=" (стандартный: 443 или 8443)" ;;
        *MTProto*) hint=" (стандартный: 8443)" ;;
    esac
    while true; do
        echo -e "${WHITE}Введите порт${hint}:${NC}"
        read -p "> " port
        [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && break
        echo -e "${RED}Некорректный порт. Введите число от 1 до 65535.${NC}"
    done

    echo ""
    echo -e "${WHITE}Правило: ${CYAN}${proto} :${port} → ${dest_ip}:${port}${NC}"
    read -p "Применить? (y/n): " c
    [[ "$c" != "y" ]] && return

    apply_rule "$proto" "$port" "$port" "$dest_ip" "$label"
    read -p "Нажмите Enter..."
}

_add_custom_rule() {
    clear
    echo -e "\n${CYAN}━━━ Кастомное правило ━━━${NC}\n"

    local proto=""
    while true; do
        echo -e "${WHITE}Протокол (tcp или udp):${NC}"
        read -p "> " proto
        [ -z "$proto" ] && return
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] && break
        echo -e "${RED}Введите tcp или udp.${NC}"
    done

    local dest_ip=""
    while true; do
        echo -e "${WHITE}IP адрес exit-ноды:${NC}"
        read -p "> " dest_ip
        [ -z "$dest_ip" ] && return
        [[ "$dest_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] && break
        echo -e "${RED}Некорректный IP. Пример: 85.192.26.32${NC}"
    done

    local in_port=""
    while true; do
        echo -e "${WHITE}ВХОДЯЩИЙ порт (на этом сервере):${NC}"
        read -p "> " in_port
        [[ "$in_port" =~ ^[0-9]+$ ]] && (( in_port >= 1 && in_port <= 65535 )) && break
        echo -e "${RED}Некорректный порт.${NC}"
    done

    local out_port=""
    while true; do
        echo -e "${WHITE}ИСХОДЯЩИЙ порт (на exit-ноде):${NC}"
        read -p "> " out_port
        [[ "$out_port" =~ ^[0-9]+$ ]] && (( out_port >= 1 && out_port <= 65535 )) && break
        echo -e "${RED}Некорректный порт.${NC}"
    done

    echo ""
    echo -e "${WHITE}Правило: ${CYAN}${proto} :${in_port} → ${dest_ip}:${out_port}${NC}"
    read -p "Применить? (y/n): " c
    [[ "$c" != "y" ]] && return

    apply_rule "$proto" "$in_port" "$out_port" "$dest_ip" "Custom"
    read -p "Нажмите Enter..."
}

_delete_rule() {
    local rules; rules=$(get_rules_list)
    [ -z "$rules" ] && echo -e "${YELLOW}Нет правил.${NC}" && read -p "Enter..." && return

    clear
    echo -e "\n${CYAN}━━━ Удалить правило ━━━${NC}\n"

    local -a rule_arr=()
    local i=1
    while IFS='|' read -r proto port dest comment; do
        local dest_ip="${dest%:*}" dest_port="${dest#*:}"
        local tag=""
        echo "$comment" | grep -q "govpn:" && tag=" ${CYAN}[govpn]${NC}" || tag=" ${YELLOW}[внешнее]${NC}"
        echo -e "  ${YELLOW}[$i]${NC} ${proto} :${port} → ${dest_ip}:${dest_port}${tag}"
        rule_arr+=("${proto}|${port}|${dest}|${comment}")
        ((i++))
    done <<< "$rules"

    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    ch=$(read_choice "Выбор: ")
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#rule_arr[@]} )) || return

    IFS='|' read -r proto port dest comment <<< "${rule_arr[$((ch-1))]}"
    local dest_ip="${dest%:*}" dest_port="${dest#*:}"

    read -p "$(echo -e "${RED}Удалить ${proto} :${port} → ${dest_ip}:${dest_port}? (y/n): ${NC}")" c
    [[ "$c" != "y" ]] && return

    # Удаляем по комментарию если govpn, иначе по параметрам
    if echo "$comment" | grep -q "govpn:"; then
        # Точное удаление по всем параметрам
        iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -m comment --comment "$comment" \
            -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null || \
        iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null
    else
        iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "${dest_ip}:${dest_port}" 2>/dev/null
    fi
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
        echo -e "  ${YELLOW}[5]${NC}  Reality SNI Scanner"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")
        case "$ch" in
            1) _speed_test ;;
            2) _chain_test ;;
            3) _site_check ;;
            4) _servers_menu ;;
            5) _reality_scanner ;;
            0|"") return ;;
        esac
    done
}

_reality_scanner() {
    clear
    echo -e "\n${CYAN}━━━ Reality SNI Scanner ━━━${NC}\n"
    echo -e "${WHITE}Сканирует TLS серверы для использования как SNI в Reality (3X-UI/VLESS).${NC}"
    echo -e "${WHITE}Нужен TLS 1.3 + ALPN h2 — иначе Reality не будет работать.${NC}\n"

    # Скачиваем/собираем RealiTLScanner если нет
    local scanner_bin="/usr/local/bin/RealiTLScanner"
    if [ ! -f "$scanner_bin" ]; then
        echo -e "${YELLOW}Установка RealiTLScanner...${NC}"

        # Пробуем через Go
        if command -v go &>/dev/null && go version 2>/dev/null | grep -q "go1\.[2-9][0-9]"; then
            echo -e "${CYAN}  Сборка из исходников (Go)...${NC}"
            go install github.com/xtls/RealiTLScanner@latest 2>/dev/null && \
                cp ~/go/bin/RealiTLScanner "$scanner_bin" 2>/dev/null
        fi

        # Если Go нет — устанавливаем Go и собираем
        if [ ! -f "$scanner_bin" ]; then
            echo -e "${CYAN}  Устанавливаю Go...${NC}"
            local go_ver="1.22.4"
            local arch
            case "$(uname -m)" in
                x86_64)  arch="amd64" ;;
                aarch64) arch="arm64" ;;
                *) echo -e "${RED}Архитектура не поддерживается${NC}"; read -p "Enter..."; return ;;
            esac
            curl -fsSL "https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz" -o /tmp/go.tar.gz 2>/dev/null && {
                tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null
                rm -f /tmp/go.tar.gz
                export PATH="/usr/local/go/bin:$PATH"
                echo -e "${GREEN}  ✓ Go установлен${NC}"
                echo -e "${CYAN}  Сборка RealiTLScanner...${NC}"
                GOPATH=/tmp/go_build /usr/local/go/bin/go install \
                    github.com/xtls/RealiTLScanner@latest 2>/dev/null && \
                    cp /tmp/go_build/bin/RealiTLScanner "$scanner_bin" 2>/dev/null
            }
        fi

        if [ ! -f "$scanner_bin" ]; then
            echo -e "${RED}  ✗ Не удалось установить RealiTLScanner${NC}"
            echo -e "${WHITE}  Установите вручную: go install github.com/xtls/RealiTLScanner@latest${NC}"
            read -p "Enter..."; return
        fi
        chmod +x "$scanner_bin"
        echo -e "${GREEN}  ✓ Установлен${NC}\n"
    fi

    # Выбор режима сканирования
    echo -e "${WHITE}Что сканировать?${NC}\n"
    echo -e "  ${YELLOW}[1]${NC}  Популярные CDN (Cloudflare, Fastly, Akamai) — быстро"
    echo -e "  ${YELLOW}[2]${NC}  По стране — выбор из списка"
    echo -e "  ${YELLOW}[3]${NC}  Свой IP / домен / CIDR"
    echo -e "  ${YELLOW}[4]${NC}  Свои IP как домен маскировки (аналог MTProto FakeTLS)"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "Выбор: " scan_mode

    local target="" threads=5 timeout=5

    case "$scan_mode" in
        1)
            echo -e "\n${WHITE}Выберите CDN:${NC}"
            echo -e "  ${YELLOW}[1]${NC} Cloudflare (1.1.1.0/24)"
            echo -e "  ${YELLOW}[2]${NC} Fastly     (151.101.0.0/22)"
            echo -e "  ${YELLOW}[3]${NC} Akamai     (23.32.0.0/22)"
            echo -e "  ${YELLOW}[4]${NC} Amazon     (13.224.0.0/22)"
            echo -e "  ${YELLOW}[5]${NC} Google     (142.250.0.0/22)"
            echo ""
            read -p "Выбор [1]: " cdn_choice
            case "${cdn_choice:-1}" in
                1) target="1.1.1.0/24"       ;;
                2) target="151.101.0.0/22"   ;;
                3) target="23.32.0.0/22"     ;;
                4) target="13.224.0.0/22"    ;;
                5) target="142.250.0.0/22"   ;;
                *) target="1.1.1.0/24"       ;;
            esac
            threads=10
            ;;
        2)
            echo -e "\n${WHITE}Выберите страну:${NC}"
            echo -e "  ${YELLOW}[1]${NC}  🇷🇺 Россия   — mail.ru CDN (94.100.180.0/22)"
            echo -e "  ${YELLOW}[2]${NC}  🇩🇪 Германия — Hetzner (95.216.0.0/22)"
            echo -e "  ${YELLOW}[3]${NC}  🇳🇱 Нидерланды — Serverius (185.107.56.0/22)"
            echo -e "  ${YELLOW}[4]${NC}  🇫🇷 Франция   — OVH (91.134.0.0/22)"
            echo -e "  ${YELLOW}[5]${NC}  🇸🇪 Швеция    — Bahnhof (91.123.240.0/22)"
            echo -e "  ${YELLOW}[6]${NC}  🌍 Общий CDN  — Fastly (151.101.0.0/22)"
            echo -e "  ${YELLOW}[7]${NC}  Свой диапазон"
            echo ""
            read -p "Выбор: " country_choice
            case "$country_choice" in
                1) target="94.100.180.0/22"    ;;
                2) target="95.216.0.0/22"      ;;
                3) target="185.107.56.0/22"    ;;
                4) target="91.134.0.0/22"      ;;
                5) target="91.123.240.0/22"    ;;
                6) target="151.101.0.0/22"     ;;
                7)
                    echo -e "${WHITE}Введите IP/CIDR/домен:${NC}"
                    read -p "> " target
                    ;;
                *) echo -e "${RED}Неверный выбор${NC}"; read -p "Enter..."; return ;;
            esac
            ;;
        3)
            echo -e "\n${WHITE}Введите IP, домен или CIDR (например: 1.2.3.4, site.com, 1.2.3.0/24):${NC}"
            read -p "> " target
            [ -z "$target" ] && return
            ;;
        4)
            # Проверяем свои IP как потенциальные домены маскировки
            clear
            echo -e "\n${CYAN}━━━ Проверка своих серверов как SNI ━━━${NC}\n"
            echo -e "${WHITE}Проверяю серверы из вашего списка...${NC}\n"
            local found=0
            while IFS='=' read -r ip val; do
                [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
                local name; name=$(echo "$val" | cut -d'|' -f1)
                echo -ne "  ${WHITE}${name:-$ip} (${ip}):${NC} "
                local result
                result=$("$scanner_bin" -addr "$ip" -timeout 3 2>/dev/null | grep "feasible=true" | head -1)
                if [ -n "$result" ]; then
                    local domain; domain=$(echo "$result" | grep -oP 'domain=\K\S+')
                    local tls; tls=$(echo "$result" | grep -oP 'tls=\K\S+')
                    echo -e "${GREEN}✓ TLS${tls} — ${domain}${NC}"
                    ((found++))
                else
                    echo -e "${RED}✗ не подходит для Reality${NC}"
                fi
            done < "$ALIASES_FILE" 2>/dev/null
            [ $found -eq 0 ] && echo -e "${YELLOW}Нет подходящих серверов. Добавьте серверы в п.7→4.${NC}"
            echo ""
            read -p "Нажмите Enter..."
            return
            ;;
        0|"") return ;;
        *) return ;;
    esac

    # Параметры сканирования
    echo ""
    echo -e "${WHITE}Количество потоков (Enter = ${threads}):${NC}"
    read -p "> " user_threads
    [ -n "$user_threads" ] && [[ "$user_threads" =~ ^[0-9]+$ ]] && threads="$user_threads"

    local max_results=10
    echo -e "${WHITE}Максимум результатов (Enter = ${max_results}):${NC}"
    read -p "> " user_max
    [ -n "$user_max" ] && [[ "$user_max" =~ ^[0-9]+$ ]] && max_results="$user_max"

    clear
    echo -e "\n${CYAN}━━━ Сканирование: ${target} ━━━${NC}\n"
    echo -e "${YELLOW}Поиск TLS 1.3 + ALPN h2 серверов...${NC}\n"

    local out_file="/tmp/reality_scan_$$.csv"

    # Таймаут зависит от размера диапазона
    local scan_timeout=30
    if echo "$target" | grep -qE '/[0-9]$|/1[0-6]$'; then
        scan_timeout=120  # большие диапазоны (/8-/16)
    elif echo "$target" | grep -qE '/1[7-9]$|/2[0-2]$'; then
        scan_timeout=60   # средние (/17-/22)
    fi
    echo -e "${CYAN}Сканирование (до ${scan_timeout}с, потоков: ${threads})...${NC}"

    timeout "$scan_timeout" "$scanner_bin" \
        -addr "$target" -thread "$threads" -timeout "$timeout" \
        -out "$out_file" > /dev/null 2>&1 || true

    echo ""

    # Показываем результаты из CSV
    if [ -f "$out_file" ] && [ "$(wc -l < "$out_file")" -gt 1 ]; then
        local total; total=$(( $(wc -l < "$out_file") - 1 ))
        echo -e "${GREEN}Найдено: ${total} серверов совместимых с Reality${NC}\n"

        printf "  ${WHITE}%-20s %-35s %-15s${NC}\n" "IP" "Домен (SNI)" "Страна"
        echo -e "  $(printf '─%.0s' {1..70})"

        tail -n +2 "$out_file" | head -"$max_results" | \
        while IFS=',' read -r ip origin domain issuer geo; do
            domain="${domain//\"/}"
            issuer="${issuer//\"/}"
            geo="${geo//\"/}"
            [ -z "$domain" ] && continue
            printf "  ${GREEN}✓${NC} %-18s ${CYAN}%-35s${NC} %s\n" \
                "$ip" "$domain" "${geo:-?}"
        done

        echo ""
        echo -e "${WHITE}Лучшие SNI для Reality (скопируйте в 3X-UI → serverName):${NC}"
        tail -n +2 "$out_file" | head -5 | \
        while IFS=',' read -r ip origin domain issuer geo; do
            domain="${domain//\"/}"
            [ -n "$domain" ] && echo -e "  ${GREEN}▶${NC} ${CYAN}${domain}${NC}"
        done
        echo -e "\n${WHITE}Файл результатов: ${CYAN}${out_file}${NC}"
    else
        echo -e "${YELLOW}Результатов нет.${NC}"
        echo -e "${WHITE}Попробуйте: увеличить timeout, уменьшить диапазон или выбрать другой CDN.${NC}"
        echo ""
        echo -e "${WHITE}Ручная проверка домена:${NC}"
        echo -e "  ${CYAN}RealiTLScanner -addr ваш_домен -timeout 5${NC}"
    fi
    echo ""
    read -p "Нажмите Enter..."
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
        ch=$(read_choice "Выбор: ")

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
        ch=$(read_choice "Выбор: ")
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
#  УПРАВЛЕНИЕ ПИРАМИ AWG (создание/удаление клиентов)
# ═══════════════════════════════════════════════════════════════

awg_peers_menu() {
    if ! is_amnezia; then
        echo -e "${YELLOW}Amnezia не обнаружен.${NC}"; read -p "Enter..."; return
    fi

    command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1

    # Выбор контейнера если их несколько
    local -a containers=()
    mapfile -t containers < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -i "amnezia-awg" | sort)
    if [ "${#containers[@]}" -gt 1 ]; then
        clear
        echo -e "\n${CYAN}━━━ Выбор контейнера ━━━${NC}\n"
        for i in "${!containers[@]}"; do
            local ct="${containers[$i]}"
            local cnt; cnt=$(docker exec "$ct" sh -c \
                "grep -c 'clientId' /opt/amnezia/awg/clientsTable 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
            local active; active=$(docker exec "$ct" sh -c \
                "wg show 2>/dev/null | grep -c 'latest handshake'" 2>/dev/null | tr -d '[:space:]')
            local mark=""
            [ "$ct" = "$AWG_CONTAINER" ] && mark=" ${CYAN}(текущий)${NC}"
            echo -e "  ${YELLOW}[$((i+1))]${NC} ${WHITE}${ct}${NC}  клиентов: ${GREEN}${cnt:-0}${NC}  активных: ${GREEN}${active:-0}${NC}${mark}"
        done
        echo -e "  ${YELLOW}[0]${NC} Назад"
        echo ""
        read -p "Выбор (Enter = ${AWG_CONTAINER}): " ct_choice
        if [ -z "$ct_choice" ]; then
            :
        elif [ "$ct_choice" = "0" ]; then
            return
        elif [[ "$ct_choice" =~ ^[0-9]+$ ]] && (( ct_choice >= 1 && ct_choice <= ${#containers[@]} )); then
            AWG_CONTAINER="${containers[$((ct_choice-1))]}"
        fi
    fi

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
        ch=$(read_choice "Выбор (Enter = обновить): ")

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
        ch=$(read_choice "Выбор: ")
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
    echo -e "  ${YELLOW}[1]${NC} WireGuard / AmneziaWG (.conf)"
    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""; read -p "Выбор: " fmt

    if ! command -v qrencode &>/dev/null; then
        echo -e "${YELLOW}Устанавливаю qrencode...${NC}"
        apt-get install -y qrencode > /dev/null 2>&1
    fi

    case "$fmt" in
        1)
            echo -e "\n${WHITE}QR код:${NC}\n"
            echo "$cfg" | qrencode -t ansiutf8 2>/dev/null || \
                echo -e "${RED}Ошибка qrencode${NC}"
            ;;
        2)
            # Amnezia читает обычный .conf формат через QR — тот же что WireGuard
            echo -e "\n${WHITE}QR для Amnezia (AWG конфиг):${NC}\n"
            echo "$cfg" | qrencode -t ansiutf8 2>/dev/null || \
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

    if [ -z "$privkey" ] || [ -z "$pubkey" ] || [ -z "$psk" ] || [ -z "$client_ip" ]; then
        echo -e "${RED}Ошибка генерации ключей.${NC}"; read -p "Enter..."; return
    fi

    local conf; conf=$(_awg_conf)
    local iface; iface=$(_awg_iface)
    local server_pubkey
    server_pubkey=$(docker exec "$AWG_CONTAINER" sh -c "wg show ${iface} public-key" 2>/dev/null)

    # Порт — из ListenPort в конфиге (надёжнее чем docker ps)
    local server_port
    server_port=$(docker exec "$AWG_CONTAINER" sh -c \
        "grep '^ListenPort' '$conf' | awk '{print \$3}'" 2>/dev/null | tr -d '[:space:]')
    [ -z "$server_port" ] && server_port=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | \
        grep "^${AWG_CONTAINER}" | grep -oE '[0-9]+->.*udp' | grep -oE '^[0-9]+' | head -1)
    [ -z "$server_port" ] && server_port="47684"

    # Выбор endpoint
    echo -e "\n${WHITE}Через какой IP клиент подключается?${NC}\n"
    local -a ep_ips=() ep_labels=()
    ep_ips+=("$MY_IP")
    ep_labels+=("Прямой  ${MY_IP}:${server_port}")

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

    local endpoint_ip="$MY_IP" endpoint_port="$server_port"
    if [[ "$ep_choice" =~ ^[0-9]+$ ]] && (( ep_choice >= 1 && ep_choice <= ${#ep_ips[@]} )); then
        local sel="${ep_ips[$((ep_choice-1))]}"
        if [ "$sel" = "custom" ]; then
            read -p "IP:порт > " custom_ep
            endpoint_ip="${custom_ep%%:*}"; endpoint_port="${custom_ep##*:}"
        else
            endpoint_ip="$sel"
            echo -e "${WHITE}Порт (Enter = ${server_port}):${NC}"
            read -p "> " custom_port
            [ -n "$custom_port" ] && endpoint_port="$custom_port"
        fi
    fi

    # Параметры обфускации только из [Interface]
    local iface_block
    iface_block=$(docker exec "$AWG_CONTAINER" sh -c \
        "awk '/^\[Interface\]/{p=1} /^\[Peer\]/{p=0} p' '$conf'" 2>/dev/null)
    local jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5
    jc=$(echo "$iface_block"   | awk '/^Jc = /{print $3; exit}')
    jmin=$(echo "$iface_block" | awk '/^Jmin = /{print $3; exit}')
    jmax=$(echo "$iface_block" | awk '/^Jmax = /{print $3; exit}')
    s1=$(echo "$iface_block"   | awk '/^S1 = /{print $3; exit}')
    s2=$(echo "$iface_block"   | awk '/^S2 = /{print $3; exit}')
    s3=$(echo "$iface_block"   | awk '/^S3 = /{print $3; exit}')
    s4=$(echo "$iface_block"   | awk '/^S4 = /{print $3; exit}')
    h1=$(echo "$iface_block"   | awk '/^H1 = /{print $3; exit}')
    h2=$(echo "$iface_block"   | awk '/^H2 = /{print $3; exit}')
    h3=$(echo "$iface_block"   | awk '/^H3 = /{print $3; exit}')
    h4=$(echo "$iface_block"   | awk '/^H4 = /{print $3; exit}')
    # I1-I5 закомментированы в серверном конфиге — читаем со знаком #
    i1=$(echo "$iface_block"   | awk '/^# I1 = /{sub(/^# I1 = /,""); print; exit}')
    i2=$(echo "$iface_block"   | awk '/^# I2 = /{sub(/^# I2 = /,""); print; exit}')
    i3=$(echo "$iface_block"   | awk '/^# I3 = /{sub(/^# I3 = /,""); print; exit}')
    i4=$(echo "$iface_block"   | awk '/^# I4 = /{sub(/^# I4 = /,""); print; exit}')
    i5=$(echo "$iface_block"   | awk '/^# I5 = /{sub(/^# I5 = /,""); print; exit}')

    # DNS — берём из Docker сети контейнера (Amnezia использует свой DNS резолвер)
    local server_dns
    server_dns=$(docker inspect "$AWG_CONTAINER" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); \
        nets=d[0].get('NetworkSettings',{}).get('Networks',{}); \
        gw=[v.get('Gateway','') for v in nets.values() if v.get('Gateway')]; \
        print(gw[0] if gw else '')" 2>/dev/null | tr -d '[:space:]')
    # Если нашли gateway — используем как DNS (Amnezia ставит DNS на gateway контейнера)
    if [ -n "$server_dns" ]; then
        # Заменяем последний октет на 254
        local dns_base="${server_dns%.*}"
        server_dns="${dns_base}.254, 1.0.0.1"
    else
        server_dns="172.29.172.254, 1.0.0.1"
    fi

    # Конфиг клиента — формат точно как Amnezia
    local bare="${client_ip%/32}"
    local client_conf
    client_conf="[Interface]
Address = ${client_ip}/32
DNS = ${server_dns}
PrivateKey = ${privkey}
Jc = ${jc:-4}
Jmin = ${jmin:-40}
Jmax = ${jmax:-50}
S1 = ${s1:-0}
S2 = ${s2:-0}
S3 = ${s3:-0}
S4 = ${s4:-0}
H1 = ${h1:-1}
H2 = ${h2:-2}
H3 = ${h3:-3}
H4 = ${h4:-4}
I1 = ${i1}
I2 = ${i2}
I3 = ${i3}
I4 = ${i4}
I5 = ${i5}

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${endpoint_ip}:${endpoint_port}
PersistentKeepalive = 25"

    # Сохранить конфиг на хосте
    mkdir -p "${CONF_DIR}/awg_clients"
    echo "$client_conf" > "${CONF_DIR}/awg_clients/${bare}.conf"
    chmod 600 "${CONF_DIR}/awg_clients/${bare}.conf"

    # Бэкап clientsTable ПЕРЕД изменением
    docker exec "$AWG_CONTAINER" sh -c \
        "cp /opt/amnezia/awg/clientsTable /opt/amnezia/awg/clientsTable.bak.\$(date +%s) 2>/dev/null || true"

    # Добавить пир в awg0.conf (безопасно — только append)
    docker exec "$AWG_CONTAINER" sh -c \
        "printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' \
        '${pubkey}' '${psk}' '${bare}' >> '${conf}'" 2>/dev/null

    # Применить в активный wg через temp файл (без bash process substitution)
    docker exec "$AWG_CONTAINER" sh -c \
        "echo '${psk}' > /tmp/govpn_psk.tmp && \
         wg set ${iface} peer '${pubkey}' preshared-key /tmp/govpn_psk.tmp \
         allowed-ips '${bare}/32' && rm -f /tmp/govpn_psk.tmp" 2>/dev/null || \
    docker exec "$AWG_CONTAINER" sh -c \
        "wg set ${iface} peer '${pubkey}' allowed-ips '${bare}/32'" 2>/dev/null

    # Обновить clientsTable — ТОЛЬКО через python3, иначе пропустить
    if docker exec "$AWG_CONTAINER" sh -c "command -v python3 >/dev/null 2>&1" 2>/dev/null; then
        local ts; ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        docker exec "$AWG_CONTAINER" python3 -c "
import json
try:
    with open('/opt/amnezia/awg/clientsTable') as f:
        data = json.load(f)
except:
    data = []
data.append({'clientId':'${pubkey}','userData':{'clientName':'${peer_name}','allowedIps':'${bare}/32','creationDate':'${ts}','dataReceived':'0 B','dataSent':'0 B','latestHandshake':'never'}})
with open('/opt/amnezia/awg/clientsTable','w') as f:
    json.dump(data,f,indent=4)
" 2>/dev/null
        echo -e "${GREEN}  ✓ Клиент добавлен в clientsTable${NC}"
    else
        echo -e "${YELLOW}  ⚠ python3 нет — clientsTable не обновлён${NC}"
        echo -e "${WHITE}  Клиент работает, но в Amnezia приложении будет без имени.${NC}"
        # Добавляем в clientsTable вручную через govpn (на хосте)
        local ts; ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        # Читаем файл на хост, модифицируем, записываем обратно
        local ct_content
        ct_content=$(docker exec "$AWG_CONTAINER" sh -c \
            "cat /opt/amnezia/awg/clientsTable 2>/dev/null || echo '[]'")
        local new_entry="{\"clientId\":\"${pubkey}\",\"userData\":{\"clientName\":\"${peer_name}\",\"allowedIps\":\"${bare}/32\",\"creationDate\":\"${ts}\",\"dataReceived\":\"0 B\",\"dataSent\":\"0 B\",\"latestHandshake\":\"never\"}}"
        # Используем python3 на ХОСТЕ (не в контейнере)
        local new_ct
        new_ct=$(echo "$ct_content" | python3 -c "
import json,sys
data=json.load(sys.stdin)
import json as j
entry=j.loads('${new_entry}')
data.append(entry)
print(j.dumps(data,indent=4))
" 2>/dev/null)
        if [ -n "$new_ct" ]; then
            echo "$new_ct" | docker exec -i "$AWG_CONTAINER" sh -c \
                "cat > /opt/amnezia/awg/clientsTable" 2>/dev/null
            echo -e "${GREEN}  ✓ clientsTable обновлён через хост${NC}"
        fi
    fi

    echo -e "${GREEN}  ✓ Клиент создан: ${peer_name} (${client_ip})${NC}\n"
    log_action "AWG PEER ADD: ${peer_name} ${client_ip}"

    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}Конфиг:${NC}\n${GREEN}${client_conf}${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if command -v qrencode &>/dev/null; then
        echo -e "\n${WHITE}QR (WireGuard):${NC}\n"
        echo "$client_conf" | qrencode -t ansiutf8
    fi

    echo -e "\n${WHITE}Конфиг сохранён: ${CYAN}${CONF_DIR}/awg_clients/${bare}.conf${NC}"
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
    ch=$(read_choice "Выбор: ")
    [[ "$ch" == "0" || -z "$ch" ]] && return
    [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#sorted_ips[@]} )) || return

    local del_ip="${sorted_ips[$((ch-1))]}"
    local del_name; del_name=$(_awg_client_name "$del_ip")
    local bare="${del_ip%/32}"

    read -p "$(echo -e "${RED}Удалить ${del_name:-$del_ip}? (y/n): ${NC}")" c
    [ "$c" != "y" ] && return

    # Найти pubkey через awk (надёжно)
    local del_pubkey
    del_pubkey=$(docker exec "$AWG_CONTAINER" sh -c "
        awk 'BEGIN{pk=\"\"; found=0}
             /^\[Peer\]/{pk=\"\"; found=0}
             /^PublicKey/{pk=\$3}
             /^AllowedIPs/ && \$0 ~ /[ \t]${bare}\//{print pk; found=1}
        ' '${conf}'
    " 2>/dev/null | head -1)

    echo -e "${YELLOW}  Pubkey: ${del_pubkey:0:20}...${NC}"

    # Удалить из активного wg
    [ -n "$del_pubkey" ] && \
        docker exec "$AWG_CONTAINER" sh -c \
            "wg set $(_awg_iface) peer '${del_pubkey}' remove" 2>/dev/null && \
        echo -e "${GREEN}  ✓ Удалён из активного wg${NC}"

    # Копируем конфиг на хост, редактируем python3, копируем обратно
    local tmp_conf="/tmp/awg_conf_edit.conf"
    docker cp "${AWG_CONTAINER}:${conf}" "$tmp_conf" 2>/dev/null

    python3 - "$tmp_conf" "$bare" << 'PYEOF'
import sys

conf_path = sys.argv[1]
target_ip = sys.argv[2]  # например "10.8.1.13"

with open(conf_path) as f:
    lines = f.readlines()

result = []
peer_block = []
in_peer = False
removed = 0

for line in lines:
    stripped = line.strip()
    if stripped == '[Peer]':
        # Начало нового Peer блока — сохраняем предыдущий если был
        if in_peer and peer_block:
            result.extend(peer_block)
        peer_block = [line]
        in_peer = True
    elif stripped.startswith('[') and stripped != '[Peer]':
        # Начало другой секции ([Interface] и т.д.)
        if in_peer and peer_block:
            # Проверяем нужно ли удалить этот peer
            should_remove = any(
                l.strip().startswith('AllowedIPs') and
                (target_ip + '/') in l or
                l.strip().startswith('AllowedIPs') and
                l.strip().split('=', 1)[-1].strip().split('/')[0].strip() == target_ip
                for l in peer_block
            )
            if should_remove:
                removed += 1
            else:
                result.extend(peer_block)
        peer_block = []
        in_peer = False
        result.append(line)
    elif in_peer:
        peer_block.append(line)
    else:
        result.append(line)

# Не забыть последний peer блок
if in_peer and peer_block:
    should_remove = any(
        l.strip().startswith('AllowedIPs') and
        l.strip().split('=', 1)[-1].strip().split('/')[0].strip() == target_ip
        for l in peer_block
    )
    if should_remove:
        removed += 1
    else:
        result.extend(peer_block)

with open(conf_path, 'w') as f:
    f.writelines(result)

print(f"Removed {removed} peer(s) matching {target_ip}")
PYEOF

    docker cp "$tmp_conf" "${AWG_CONTAINER}:${conf}" 2>/dev/null
    rm -f "$tmp_conf"
    echo -e "${GREEN}  ✓ Конфиг обновлён${NC}"

    # Удалить из clientsTable (python3 на хосте через docker cp)
    local tmp_ct="/tmp/awg_ct_edit.json"
    docker cp "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" "$tmp_ct" 2>/dev/null
    if [ -f "$tmp_ct" ]; then
        python3 - "$tmp_ct" "$bare" << 'PYEOF'
import sys, json

ct_path = sys.argv[1]
target_ip = sys.argv[2]

try:
    with open(ct_path) as f:
        data = json.load(f)
    before = len(data)
    data = [c for c in data
            if c.get('userData', {}).get('allowedIps', '').split('/')[0] != target_ip]
    with open(ct_path, 'w') as f:
        json.dump(data, f, indent=4)
    print(f"Removed {before - len(data)} entry")
except Exception as e:
    print(f"Error: {e}")
PYEOF
        docker cp "$tmp_ct" "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" 2>/dev/null
        rm -f "$tmp_ct"
        echo -e "${GREEN}  ✓ clientsTable обновлён${NC}"
    fi

    # Удалить сохранённый конфиг
    rm -f "${CONF_DIR}/awg_clients/${bare}.conf"

    echo -e "${GREEN}  ✓ Удалён: ${del_name:-$del_ip}${NC}"
    log_action "AWG PEER DEL: ${del_name} ${del_ip}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  MTPROTO ПРОКСИ (mtg v2)
# ═══════════════════════════════════════════════════════════════

MTG_CONF_DIR="${CONF_DIR}/mtproto"
MTG_IMAGE="nineseconds/mtg:2"

# Список доменов для FakeTLS с описаниями
MTG_DOMAINS=(
    "bing.com:Microsoft Bing"
    "apple.com:Apple"
    "microsoft.com:Microsoft"
    "amazon.com:Amazon"
    "cloudflare.com:Cloudflare"
    "wikipedia.org:Wikipedia"
    "speedtest.net:Speedtest"
    "github.com:GitHub"
    "stackoverflow.com:StackOverflow"
    "medium.com:Medium"
)

# Популярные порты для MTProto
MTG_PORTS=(443 8443 2053 2083 2087)

_mtg_list_instances() {
    # Ищем все контейнеры связанные с MTProto/mtg
    docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | \
        grep -iE "^(mtg-|mtproto)" | sort
}

_mtg_count_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | \
        grep -icE "^(mtg-|mtproto)" 2>/dev/null | tr -d '[:space:]' | head -1 || echo "0"
}

_mtg_detect_type() {
    local name="$1"
    [[ "$name" == mtg-* ]] && echo "govpn" || echo "external"
}

_mtg_is_running() {
    local name="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"
}

_mtg_connections() {
    local name="$1"
    # Получаем статистику из mtg stats endpoint (порт 3129 по умолчанию)
    local stats_port
    stats_port=$(cat "${MTG_CONF_DIR}/${name}.meta" 2>/dev/null | grep "^stats_port=" | cut -d'=' -f2)
    [ -z "$stats_port" ] && echo "?" && return
    local conns
    conns=$(curl -s --max-time 2 "http://localhost:${stats_port}/stats" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('connections',{}).get('active',0))" 2>/dev/null)
    echo "${conns:-?}"
}

_mtg_get_link() {
    local name="$1"
    cat "${MTG_CONF_DIR}/${name}.meta" 2>/dev/null | grep "^link=" | cut -d'=' -f2-
}

_mtg_ping_domain() {
    local domain="$1"
    local ms
    ms=$(curl -so /dev/null -w '%{time_connect}' --max-time 3 "https://${domain}/" 2>/dev/null)
    [ -z "$ms" ] && echo "999" && return
    awk "BEGIN{printf \"%.0f\", $ms*1000}" 2>/dev/null || echo "999"
}

_mtg_detect_country() {
    local geo
    geo=$(curl -s --max-time 5 "http://ip-api.com/json/${MY_IP}?fields=country,countryCode,city" 2>/dev/null)
    local country city cc
    country=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null)
    city=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null)
    cc=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('countryCode',''))" 2>/dev/null)
    echo "${cc}|${country}|${city}"
}

_mtg_check_port() {
    local port="$1"
    ss -tlnup 2>/dev/null | grep -q ":${port} " && return 1 || return 0
}

_mtg_add() {
    clear
    echo -e "\n${CYAN}━━━ Новый MTProto прокси ━━━${NC}\n"

    # Определяем страну сервера
    echo -ne "${WHITE}Определяю страну сервера...${NC} "
    local geo_info; geo_info=$(_mtg_detect_country)
    local geo_cc="${geo_info%%|*}"
    local geo_rest="${geo_info#*|}"
    local geo_country="${geo_rest%%|*}"
    local geo_city="${geo_rest##*|}"
    echo -e "${GREEN}${geo_cc} ${geo_country} (${geo_city})${NC}"

    # Если Россия — предупреждение
    if [ "$geo_cc" = "RU" ]; then
        echo -e "${YELLOW}  ⚠ Российский IP — MTProto работает, но некоторые домены могут быть заблокированы${NC}"
    fi
    echo ""

    # Выбор порта
    echo -e "${WHITE}Выберите порт:${NC}"
    local port_colors=("$GREEN" "$GREEN" "$CYAN" "$CYAN" "$CYAN")
    local port_notes=("рекомендуется — выглядит как HTTPS" "альтернативный HTTPS" "нестандартный" "нестандартный" "нестандартный")
    local i=1
    for p in "${MTG_PORTS[@]}"; do
        local note="${port_notes[$((i-1))]}"
        local col="${port_colors[$((i-1))]}"
        if _mtg_check_port "$p"; then
            echo -e "  ${YELLOW}[$i]${NC} ${col}${p}${NC}  — ${note}"
        else
            local occ; occ=$(ss -tlnup 2>/dev/null | grep ":${p} " | sed 's/.*users:(("//' | cut -d'"' -f1 | head -1)
            echo -e "  ${YELLOW}[$i]${NC} ${RED}${p}${NC}  — ${RED}занят (${occ})${NC}"
        fi
        ((i++))
    done
    echo -e "  ${YELLOW}[$i]${NC} Свой порт"
    echo ""
    read -p "Выбор [1]: " port_choice
    [ -z "$port_choice" ] && port_choice=1

    local chosen_port=""
    if [[ "$port_choice" =~ ^[0-9]+$ ]] && (( port_choice >= 1 && port_choice <= ${#MTG_PORTS[@]} )); then
        chosen_port="${MTG_PORTS[$((port_choice-1))]}"
    elif (( port_choice == ${#MTG_PORTS[@]} + 1 )); then
        while true; do
            echo -e "${WHITE}Введите порт (1-65535):${NC}"
            read -p "> " chosen_port
            [[ "$chosen_port" =~ ^[0-9]+$ ]] && (( chosen_port >= 1 && chosen_port <= 65535 )) && break
            echo -e "${RED}Некорректный порт.${NC}"
        done
    else
        chosen_port="443"
    fi

    # Предупреждение если порт занят
    if ! _mtg_check_port "$chosen_port"; then
        local occ; occ=$(ss -tlnup 2>/dev/null | grep ":${chosen_port} " | sed 's/.*users:(("//' | cut -d'"' -f1 | head -1)
        echo -e "\n${RED}  ⚠ Порт ${chosen_port} занят процессом: ${occ}${NC}"
        echo -e "${WHITE}  Это может вызвать конфликт. Продолжить всё равно? (y/n):${NC}"
        read -p "  > " force_port
        [[ "$force_port" != "y" ]] && return
    fi
    echo ""

    # Выбор домена с пингом
    echo -e "${WHITE}Выберите домен маскировки (FakeTLS):${NC}"
    echo -e "${CYAN}  Тестирую доступность доменов...${NC}"
    echo ""

    local -a domain_list=() domain_ms=()
    for entry in "${MTG_DOMAINS[@]}"; do
        local d="${entry%%:*}"
        local desc="${entry##*:}"
        local ms; ms=$(_mtg_ping_domain "$d")
        domain_list+=("$d")
        domain_ms+=("$ms")
        local col="$GREEN"
        (( ms > 100 )) && col="$YELLOW"
        (( ms > 300 )) && col="$RED"
        [ "$ms" = "999" ] && col="$RED" && ms="нет ответа"
        printf "  ${YELLOW}[%d]${NC} %-20s ${col}%s${NC}  %s\n" \
            "${#domain_list[@]}" "$d" "${ms}ms" "$desc"
    done
    echo -e "  ${YELLOW}[$((${#domain_list[@]}+1))]${NC} Свой домен"
    echo ""
    echo -e "${YELLOW}  ⚠ Не используйте домены заблокированные в вашем регионе!${NC}"
    echo ""
    read -p "Выбор [1]: " domain_choice
    [ -z "$domain_choice" ] && domain_choice=1

    local chosen_domain=""
    if [[ "$domain_choice" =~ ^[0-9]+$ ]] && (( domain_choice >= 1 && domain_choice <= ${#domain_list[@]} )); then
        chosen_domain="${domain_list[$((domain_choice-1))]}"
    elif (( domain_choice == ${#domain_list[@]} + 1 )); then
        echo -e "${WHITE}Введите домен (например: telegram.org):${NC}"
        read -p "> " chosen_domain
        [ -z "$chosen_domain" ] && return
    else
        chosen_domain="bing.com"
    fi

    # Генерируем имя контейнера
    local name="mtg-${chosen_port}"

    # Проверяем что контейнер не существует
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        echo -e "${YELLOW}  Контейнер ${name} уже существует. Удалить и пересоздать? (y/n):${NC}"
        read -p "  > " recreate
        [[ "$recreate" != "y" ]] && return
        docker stop "$name" > /dev/null 2>&1
        docker rm "$name" > /dev/null 2>&1
    fi

    # Генерируем секрет
    echo -e "\n${YELLOW}Генерация секрета...${NC}"
    local secret
    secret=$(docker run --rm "$MTG_IMAGE" generate-secret tls "${chosen_domain}" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$secret" ]; then
        echo -e "${RED}  ✗ Не удалось сгенерировать секрет. Docker установлен?${NC}"
        read -p "Enter..."; return
    fi
    echo -e "${GREEN}  ✓ Секрет: ${secret:0:20}...${NC}"

    # Конфиг файл для mtg
    mkdir -p "$MTG_CONF_DIR"
    local conf_file="${MTG_CONF_DIR}/${name}.toml"
    cat > "$conf_file" << TOML
secret = "${secret}"
bind-to = "0.0.0.0:3128"

[network]
dns = "https://1.1.1.1/dns-query"
TOML

    # Запускаем контейнер
    echo -e "${YELLOW}Запускаю контейнер ${name}...${NC}"
    docker run -d \
        --name "$name" \
        --restart unless-stopped \
        -v "${conf_file}:/config.toml" \
        -p "${chosen_port}:3128" \
        "$MTG_IMAGE" run /config.toml > /dev/null 2>&1

    sleep 3

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        echo -e "${RED}  ✗ Контейнер не запустился${NC}"
        echo -e "${YELLOW}  Логи: docker logs ${name}${NC}"
        read -p "Enter..."; return
    fi

    # Формируем ссылку
    local link="tg://proxy?server=${MY_IP}&port=${chosen_port}&secret=${secret}"
    local link_tme="https://t.me/proxy?server=${MY_IP}&port=${chosen_port}&secret=${secret}"

    # Сохраняем мета-данные
    cat > "${MTG_CONF_DIR}/${name}.meta" << META
port=${chosen_port}
domain=${chosen_domain}
secret=${secret}
link=${link}
link_tme=${link_tme}
created=$(date '+%Y-%m-%d %H:%M:%S')
META

    echo -e "${GREEN}  ✓ MTProto прокси запущен!${NC}\n"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}Порт:   ${CYAN}${chosen_port}${NC}"
    echo -e "  ${WHITE}Домен:  ${CYAN}${chosen_domain}${NC}"
    echo -e "  ${WHITE}Ссылка: ${GREEN}${link}${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if command -v qrencode &>/dev/null; then
        echo -e "\n${WHITE}QR код:${NC}\n"
        echo "$link" | qrencode -t ansiutf8 2>/dev/null
    fi

    log_action "MTG ADD: ${name} port=${chosen_port} domain=${chosen_domain}"
    echo ""
    read -p "Нажмите Enter..."
}

_mtg_manage() {
    local name="$1"
    local meta_file="${MTG_CONF_DIR}/${name}.meta"

    while true; do
        clear
        local port domain link running_st
        port=$(grep "^port=" "$meta_file" 2>/dev/null | cut -d'=' -f2)
        domain=$(grep "^domain=" "$meta_file" 2>/dev/null | cut -d'=' -f2)
        link=$(grep "^link=" "$meta_file" 2>/dev/null | cut -d'=' -f2-)
        local created; created=$(grep "^created=" "$meta_file" 2>/dev/null | cut -d'=' -f2-)

        if _mtg_is_running "$name"; then
            running_st="${GREEN}● активен${NC}"
        else
            running_st="${RED}● остановлен${NC}"
        fi

        echo -e "\n${CYAN}━━━ ${name} ━━━${NC}\n"
        echo -e "  ${WHITE}Статус:  ${running_st}"
        echo -e "  ${WHITE}Порт:    ${CYAN}${port}${NC}"
        echo -e "  ${WHITE}Домен:   ${CYAN}${domain} (FakeTLS)${NC}"
        echo -e "  ${WHITE}Создан:  ${WHITE}${created}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC}  Показать ссылку и QR"
        echo -e "  ${YELLOW}[2]${NC}  Перевыпустить секрет"
        if _mtg_is_running "$name"; then
            echo -e "  ${YELLOW}[3]${NC}  Остановить"
        else
            echo -e "  ${YELLOW}[3]${NC}  Запустить"
        fi
        echo -e "  ${RED}[4]${NC}  Удалить прокси"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")

        case "$ch" in
            1)
                clear
                echo -e "\n${CYAN}━━━ Ссылки: ${name} ━━━${NC}\n"
                echo -e "${WHITE}tg:// ссылка:${NC}"
                echo -e "${GREEN}${link}${NC}\n"
                local link_tme; link_tme=$(grep "^link_tme=" "$meta_file" 2>/dev/null | cut -d'=' -f2-)
                echo -e "${WHITE}t.me ссылка:${NC}"
                echo -e "${GREEN}${link_tme}${NC}\n"
                if command -v qrencode &>/dev/null; then
                    echo -e "${WHITE}QR код (tg://):${NC}\n"
                    echo "$link" | qrencode -t ansiutf8 2>/dev/null
                fi
                read -p "Нажмите Enter..." ;;
            2)
                clear
                echo -e "\n${CYAN}━━━ Перевыпуск секрета: ${name} ━━━${NC}\n"
                echo -e "${YELLOW}Генерируем новый секрет для домена ${domain}...${NC}"
                local new_secret
                new_secret=$(docker run --rm "$MTG_IMAGE" generate-secret tls "${domain}" 2>/dev/null | tr -d '[:space:]')
                if [ -z "$new_secret" ]; then
                    echo -e "${RED}Ошибка генерации секрета.${NC}"; read -p "Enter..."; continue
                fi
                # Обновляем конфиг
                local conf_file="${MTG_CONF_DIR}/${name}.toml"
                sed -i "s|^secret = .*|secret = \"${new_secret}\"|" "$conf_file"
                # Перезапускаем контейнер
                docker stop "$name" > /dev/null 2>&1
                docker rm "$name" > /dev/null 2>&1
                docker run -d --name "$name" --restart unless-stopped \
                    -v "${conf_file}:/config.toml" \
                    -p "${port}:3128" "$MTG_IMAGE" run /config.toml > /dev/null 2>&1
                sleep 2
                # Обновляем мета
                local new_link="tg://proxy?server=${MY_IP}&port=${port}&secret=${new_secret}"
                local new_link_tme="https://t.me/proxy?server=${MY_IP}&port=${port}&secret=${new_secret}"
                sed -i "s|^secret=.*|secret=${new_secret}|" "$meta_file"
                sed -i "s|^link=.*|link=${new_link}|" "$meta_file"
                sed -i "s|^link_tme=.*|link_tme=${new_link_tme}|" "$meta_file"
                echo -e "${GREEN}  ✓ Новый секрет активен${NC}"
                echo -e "${GREEN}  Новая ссылка: ${new_link}${NC}"
                log_action "MTG REKEY: ${name}"
                read -p "Нажмите Enter..." ;;
            3)
                if _mtg_is_running "$name"; then
                    docker stop "$name" > /dev/null 2>&1
                    echo -e "${YELLOW}Остановлен.${NC}"
                else
                    local conf_file="${MTG_CONF_DIR}/${name}.toml"
                    docker start "$name" > /dev/null 2>&1 || \
                    docker run -d --name "$name" --restart unless-stopped \
                        -v "${conf_file}:/config.toml" \
                        -p "${port}:3128" "$MTG_IMAGE" run /config.toml > /dev/null 2>&1
                    sleep 2
                    _mtg_is_running "$name" && echo -e "${GREEN}Запущен.${NC}" || echo -e "${RED}Не удалось запустить.${NC}"
                fi
                sleep 1 ;;
            4)
                read -p "$(echo -e "${RED}Удалить ${name}? (y/n): ${NC}")" c
                [ "$c" != "y" ] && continue
                docker stop "$name" > /dev/null 2>&1
                docker rm "$name" > /dev/null 2>&1
                rm -f "${MTG_CONF_DIR}/${name}.toml" "${MTG_CONF_DIR}/${name}.meta"
                echo -e "${GREEN}  ✓ Удалён.${NC}"
                log_action "MTG DEL: ${name}"
                read -p "Нажмите Enter..."; return ;;
            0|"") return ;;
        esac
    done
}

mtproto_menu() {
    if ! command -v docker &>/dev/null; then
        echo -e "${RED}Docker не установлен.${NC}"; read -p "Enter..."; return
    fi

    mkdir -p "$MTG_CONF_DIR"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ MTProto прокси ━━━${NC}\n"

        local -a names=()
        local instances; instances=$(_mtg_list_instances)

        if [ -n "$instances" ]; then
            echo -e "${WHITE}Прокси:${NC}"
            while IFS=$'\t' read -r cname status ports; do
                local port domain ctype
                ctype=$(_mtg_detect_type "$cname")

                # Читаем порт из мета или из docker ports напрямую из табличного вывода
                port=$(grep "^port=" "${MTG_CONF_DIR}/${cname}.meta" 2>/dev/null | cut -d'=' -f2)
                if [ -z "$port" ]; then
                    # Парсим из колонки Ports формата "0.0.0.0:443->3128/tcp"
                    port=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1 | cut -d: -f2)
                    [ -z "$port" ] && port=$(echo "$ports" | grep -oE '[0-9]+->.*tcp' | head -1 | cut -d- -f1)
                fi

                domain=$(grep "^domain=" "${MTG_CONF_DIR}/${cname}.meta" 2>/dev/null | cut -d'=' -f2)
                if [ -z "$domain" ]; then
                    # Декодируем домен из FakeTLS секрета (ee + 16 байт random + домен hex)
                    local secret
                    secret=$(docker inspect "$cname" 2>/dev/null | \
                        python3 -c "
import json,sys
d=json.load(sys.stdin)
cmd=d[0].get('Config',{}).get('Cmd',[]) or []
for arg in cmd:
    if str(arg).startswith('ee') and len(str(arg)) > 34:
        print(arg)
        break
" 2>/dev/null | tr -d '[:space:]')
                    if [ -n "$secret" ]; then
                        domain=$(python3 -c "
s='${secret}'
try:
    hd=s[34:]
    print(bytes.fromhex(hd).decode('utf-8'))
except:
    print('?')
" 2>/dev/null)
                    fi
                    [ -z "$domain" ] && domain="?"
                fi

                local idx=$((${#names[@]}+1))
                names+=("$cname")
                local type_label=""
                [ "$ctype" = "external" ] && type_label=" ${YELLOW}[внешний]${NC}"

                if _mtg_is_running "$cname"; then
                    echo -e "  ${YELLOW}[${idx}]${NC} ${GREEN}●${NC} ${WHITE}${cname}${NC}${type_label}  порт:${CYAN}${port:-?}${NC}  домен:${CYAN}${domain:-?}${NC}"
                else
                    echo -e "  ${YELLOW}[${idx}]${NC} ${RED}○${NC} ${WHITE}${cname}${NC}${type_label}  порт:${CYAN}${port:-?}${NC}  ${RED}остановлен${NC}"
                fi
            done <<< "$instances"
            echo ""
        else
            echo -e "  ${YELLOW}Прокси не найдены${NC}\n"
        fi

        echo -e "  ${YELLOW}[+]${NC}  Добавить прокси"
        [ ${#names[@]} -gt 0 ] && echo -e "  ${YELLOW}[номер]${NC}  Управление"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")

        [ "$ch" = "0" ] || [ -z "$ch" ] && return
        [ "$ch" = "+" ] && { _mtg_add; continue; }

        if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#names[@]} )); then
            _mtg_manage "${names[$((ch-1))]}"
        fi
    done
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

        # Статусная строка
        echo -e "  ${WHITE}WARP: $(warp_overall_status)${NC}"
        # MTProto статус
        local mtg_count; mtg_count=$(_mtg_count_running)
        [ "$mtg_count" -gt 0 ] && \
            echo -e "  ${WHITE}MTG:  ${GREEN}● ${mtg_count} прокси активно${NC}"

        echo -e "${MAGENTA}──────────────────────────────────────────────${NC}"

        # Адаптивное меню
        if ! is_bridge; then
            echo -e " ${CYAN}── WARP ──────────────────────────────${NC}"
            echo -e "  ${GREEN}1)  ★ Настроить WARP${NC}  ${CYAN}(мастер)${NC}"
            echo -e "  2)  Тест WARP"
            if is_amnezia; then
                echo -e "  3)  Клиенты → WARP"
            fi
        fi
        if is_amnezia; then
            echo -e " ${CYAN}── AWG ───────────────────────────────${NC}"
            echo -e "  4)  Управление клиентами AWG"
        fi
        echo -e " ${CYAN}── ПРОКСИ ────────────────────────────${NC}"
        echo -e "  5)  MTProto прокси"
        echo -e "  6)  iptables проброс"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e "  7)  Серверы, скорость, тесты"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e "  8)  Система и управление"
        echo -e "  0)  Выход"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        ch=$(read_choice "Выбор: ")

        [ -z "$ch" ] && continue

        # Транслитерация русской раскладки для букв-команд
        case "$ch" in
            *) ;;  # числа обрабатываем ниже
        esac

        case "$ch" in
            1) ! is_bridge && warp_setup_wizard ;;
            2) ! is_bridge && warp_test ;;
            3) is_amnezia && awg_clients_menu ;;
            4) is_amnezia && awg_peers_menu ;;
            5) mtproto_menu ;;
            6) iptables_menu ;;
            7) tools_menu ;;
            8) system_menu ;;
            0)
                clear; exit 0 ;;
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
