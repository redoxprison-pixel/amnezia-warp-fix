#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  GoVPN Manager v4.0
#  Автоопределение режима · WARP мастер · iptables каскад
#  Поддержка: 3X-UI · AmneziaWG · Bridge · Combo
# ══════════════════════════════════════════════════════════════

VERSION="6.43"
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
HY2_RUNNING=0     # 1 если hysteria-server активен

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

read_choice() {
    local prompt="${1:-Выбор: }"
    local raw
    read -p "$prompt" raw < /dev/tty
    [ -z "$raw" ] && echo "" && return
    # Транслитерация русской раскладки
    if [[ "$raw" =~ ^[a-zA-Z0-9!+/\.,:@_=-]+$ ]]; then
        echo "$raw"
    else
        ru_to_en "$raw"
    fi
}

# Безопасный read для ответов y/n — принимает кириллицу и н→y
read_yn() {
    local prompt="$1"
    local raw
    echo -ne "$prompt" > /dev/tty
    read raw < /dev/tty
    raw=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    case "$raw" in
        y|н|yes|да) echo "y" ;;
        *) echo "n" ;;
    esac
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

    # Hysteria2 — независимо от основного режима
    # Hysteria2 detection disabled (QUIC blocked by ISP)
    # if systemctl is-active hysteria-server &>/dev/null 2>&1; then
    #     HY2_RUNNING=1
    #     MODE_LABEL="${MODE_LABEL} +Hy2"
    # fi
}

is_3xui() { [[ "$MODE" == "3xui" || "$MODE" == "combo" ]]; }
is_amnezia() { [[ "$MODE" == "amnezia" || "$MODE" == "combo" ]]; }
is_bridge() { [[ "$MODE" == "bridge" ]]; }
is_hysteria2() { [ "$HY2_RUNNING" -eq 1 ]; }

# ═══════════════════════════════════════════════════════════════
#  WARP — ОБЩИЕ ФУНКЦИИ
# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
#  МОНИТОРИНГ — системные метрики для шапки
# ═══════════════════════════════════════════════════════════════


get_sys_stats() {
    local cpu_line1 cpu_line2
    cpu_line1=$(grep '^cpu ' /proc/stat 2>/dev/null)
    sleep 0.4
    cpu_line2=$(grep '^cpu ' /proc/stat 2>/dev/null)
    local cpu_pct="?"
    if [ -n "$cpu_line1" ] && [ -n "$cpu_line2" ]; then
        cpu_pct=$(awk -v l1="$cpu_line1" -v l2="$cpu_line2" 'BEGIN {
            split(l1,a); split(l2,b)
            idle1=a[5]; idle2=b[5]; total1=0; total2=0
            for(i=2;i<=8;i++){total1+=a[i];total2+=b[i]}
            dt=total2-total1; di=idle2-idle1
            if(dt>0) printf "%d",int((dt-di)*100/dt+0.5); else print "0"
        }' /dev/null)
    fi
    local mem_total mem_avail
    mem_total=$(grep '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    mem_avail=$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    local ram_str="?"
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ] && (( mem_total > 0 )); then
        ram_str="$(_fmt_bytes "$(( (mem_total - mem_avail) * 1024 ))")/$(_fmt_bytes "$(( mem_total * 1024 ))")"
    fi
    local disk_avail
    disk_avail=$(df -B1 / 2>/dev/null | awk 'NR==2{print $4}')
    [ -n "$disk_avail" ] && disk_avail="$(_fmt_bytes "$disk_avail") free" || disk_avail="?"
    echo "CPU ${cpu_pct}%  RAM ${ram_str}  Disk ${disk_avail}"
}

get_awg_stats() {
    is_amnezia || return
    [ -z "$AWG_CONTAINER" ] && return
    local iface; iface=$(_awg_iface)
    local peer_total=0
    peer_total=$(docker exec "$AWG_CONTAINER" sh -c \
        "awg show ${iface} peers 2>/dev/null | grep -c '^' || wg show ${iface} peers 2>/dev/null | grep -c '^'" 2>/dev/null \
        | tr -d '[:space:]')
    [[ "$peer_total" =~ ^[0-9]+$ ]] || peer_total=0
    local now; now=$(date +%s)
    local peer_active=0
    while IFS= read -r ts; do
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        (( now - ts <= 180 )) && (( peer_active++ ))
    done < <(docker exec "$AWG_CONTAINER" sh -c \
        "awg show ${iface} latest-handshakes 2>/dev/null || wg show ${iface} latest-handshakes 2>/dev/null" 2>/dev/null \
        | awk '{print $2}')
    local rx tx rx_str="" tx_str=""
    rx=$(docker exec "$AWG_CONTAINER" sh -c \
        "cat /proc/net/dev 2>/dev/null | awk -v iface='${iface}:' '\$1==iface{print \$2}'" 2>/dev/null | tr -d '[:space:]')
    tx=$(docker exec "$AWG_CONTAINER" sh -c \
        "cat /proc/net/dev 2>/dev/null | awk -v iface='${iface}:' '\$1==iface{print \$10}'" 2>/dev/null | tr -d '[:space:]')
    [[ "$rx" =~ ^[0-9]+$ ]] && [[ "$tx" =~ ^[0-9]+$ ]] && \
        rx_str="↓$(_fmt_bytes "$rx")" && tx_str="↑$(_fmt_bytes "$tx")"
    local result="${peer_total} peers"
    [ "$peer_total" -gt 0 ] && result="${result} (${peer_active} active)"
    [ -n "$rx_str" ] && result="${result}  ${rx_str} ${tx_str}"
    echo "$result"
}

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

# ═══════════════════════════════════════════════════════════════
#  3X-UI — УПРАВЛЕНИЕ КЛИЕНТАМИ ЧЕРЕЗ API
# ═══════════════════════════════════════════════════════════════

# Конфигурация 3X-UI (читается из БД автоматически)
# ═══════════════════════════════════════════════════════════════
#  3X-UI — УПРАВЛЕНИЕ КЛИЕНТАМИ ЧЕРЕЗ API
# ═══════════════════════════════════════════════════════════════

_3xui_load_config() {
    XUI_DB="/etc/x-ui/x-ui.db"
    XUI_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "17331")
    XUI_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    XUI_PATH="${XUI_PATH%/}"
    XUI_BASE="https://127.0.0.1:${XUI_PORT}${XUI_PATH}"
    XUI_SUB_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "")
    XUI_SUB_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath';" 2>/dev/null || echo "")
    XUI_SUB_DOMAIN=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
    # Если subDomain пустой — ищем из certbot, nginx или x-ui настроек
    if [ -z "$XUI_SUB_DOMAIN" ]; then
        XUI_SUB_DOMAIN=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    fi
    if [ -z "$XUI_SUB_DOMAIN" ]; then
        XUI_SUB_DOMAIN=$(grep -rh 'server_name' /etc/nginx/sites-enabled/ 2>/dev/null |             grep -v '#\|localhost\|_\|default' | grep -oP 'server_name\s+\K\S+' |             grep '\.' | head -1 || echo "")
    fi
    XUI_USER=$(sqlite3 "$XUI_DB" "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo "")
}

# Сохранить пароль панели в govpn конфиг
_3xui_save_password() {
    _3xui_load_config
    local pass
    echo -e "\n  ${WHITE}Введите пароль панели 3X-UI (пользователь: ${XUI_USER:-admin}):${NC}"
    read -r -s pass < /dev/tty
    echo ""
    [ -z "$pass" ] && return 1
    sed -i "/^XUI_PASS=/d" /etc/govpn/config 2>/dev/null
    echo "XUI_PASS=${pass}" >> /etc/govpn/config
    echo -e "  ${GREEN}✓ Пароль сохранён${NC}"
}

# Выполняет HTTP логин, возвращает cookie
_3xui_login_request() {
    local user="$1" pass="$2"
    local hf df
    hf=$(mktemp); df=$(mktemp)
    printf '{"username":"%s","password":"%s"}' "$user" "$pass" > "$df"
    curl -sk -X POST "${XUI_BASE}/login" \
        -H 'Content-Type: application/json' \
        -d "@${df}" -D "$hf" -o /dev/null 2>/dev/null
    grep -ioP '3x-ui=\S+(?=;)' "$hf" 2>/dev/null | head -1
    rm -f "$hf" "$df"
}

# Авторизация — возвращает cookie или запрашивает пароль
_3xui_auth() {
    _3xui_load_config
    [ -z "$XUI_USER" ] && { echo -e "  ${RED}✗ x-ui база недоступна${NC}" >&2; return 1; }

    local pass
    pass=$(grep "^XUI_PASS=" /etc/govpn/config 2>/dev/null | cut -d= -f2-)

    if [ -z "$pass" ]; then
        echo -e "\n  ${YELLOW}Пароль панели 3X-UI не сохранён.${NC}" >&2
        echo -e "  ${WHITE}Введите пароль (пользователь: ${XUI_USER}):${NC}" >&2
        read -r -s pass < /dev/tty
        echo "" >&2
        [ -z "$pass" ] && return 1
        echo "XUI_PASS=${pass}" >> /etc/govpn/config
    fi

    local cookie
    cookie=$(_3xui_login_request "$XUI_USER" "$pass")

    if [ -z "$cookie" ]; then
        sed -i "/^XUI_PASS=/d" /etc/govpn/config 2>/dev/null
        echo -e "  ${RED}✗ Неверный пароль.${NC}" >&2
        echo -e "  ${WHITE}Введите пароль заново:${NC}" >&2
        read -r -s pass < /dev/tty
        echo "" >&2
        [ -z "$pass" ] && return 1
        echo "XUI_PASS=${pass}" >> /etc/govpn/config
        cookie=$(_3xui_login_request "$XUI_USER" "$pass")
        [ -z "$cookie" ] && { echo -e "  ${RED}✗ Авторизация не удалась${NC}" >&2; return 1; }
    fi

    echo "$cookie"
}

# API запрос
_3xui_api() {
    local method="$1" path="$2" data="$3" cookie="$4"
    local url="${XUI_BASE}${path}"
    if [ "$method" = "GET" ]; then
        curl -sk -H "Cookie: $cookie" "$url" 2>/dev/null
    else
        local df; df=$(mktemp)
        printf '%s' "$data" > "$df"
        curl -sk -X POST -H "Cookie: $cookie" \
            -H "Content-Type: application/json" \
            -d "@${df}" "$url" 2>/dev/null
        rm -f "$df"
    fi
}

# Получает список inbound'ов
_3xui_get_inbounds() {
    _3xui_api GET "/panel/api/inbounds/list" "" "$1"
}

# Пишет вспомогательные python скрипты
_3xui_write_helpers() {
    cat > /tmp/xui_parse.py << 'PYEOF'
import json, sys, re, subprocess

def strip_suffix(email):
    # Новый формат: Name(-_•)N
    cleaned = re.sub(r'\(-_•\)\d+$', '', email).strip()
    if cleaned != email:
        return cleaned
    # Старый формат: Name(-_•) (•_-) (•_•) (-_-)
    return re.sub(r'\([^)]*[_\-•.][^)]*\)\s*$', '', email).strip()

def get_traffic(email):
    try:
        # Используем python sqlite3 чтобы не падать на спецсимволах
        import sqlite3
        conn = sqlite3.connect('/etc/x-ui/x-ui.db')
        conn.text_factory = lambda b: b.decode('utf-8', errors='replace')
        row = conn.execute(
            "SELECT up, down FROM client_traffics WHERE email=? LIMIT 1", (email,)
        ).fetchone()
        conn.close()
        return (int(row[0] or 0), int(row[1] or 0)) if row else (0, 0)
    except Exception:
        return 0, 0

try:
    with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
        d = json.load(f)
    seen = {}
    for ib in d.get("obj", []):
        ib_id = str(ib["id"])
        try:
            settings = json.loads(ib.get("settings", "{}"))
        except Exception:
            settings = {}
        for c in settings.get("clients", []):
            email = c.get("email", "")
            # Пропускаем записи с битыми суррогатами
            if '\ud800' <= email[:1] <= '\udfff' or any(
                '\ud800' <= ch <= '\udfff' for ch in email):
                continue
            sub_id = c.get("subId", "")
            enable = "on" if c.get("enable", True) else "off"
            base = strip_suffix(email)
            key = sub_id if sub_id else base
            if key not in seen:
                seen[key] = {"display_email": base or email, "subId": sub_id,
                             "inbounds": [], "emails": {}, "enable": enable,
                             "up": 0, "down": 0}
            if ib_id not in seen[key]["inbounds"]:
                seen[key]["inbounds"].append(ib_id)
                seen[key]["emails"][ib_id] = email
                up, dn = get_traffic(email)
                seen[key]["up"] += up
                seen[key]["down"] += dn
    for v in seen.values():
        emap = ";".join("{}:{}".format(k, v2) for k, v2 in v["emails"].items())
        print("{}|{}|{}|{}|{}|{}|{}".format(
            v["display_email"], v["subId"], ",".join(v["inbounds"]),
            v["enable"], v["up"], v["down"], emap))
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF

    cat > /tmp/xui_inbounds.py << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    show_all = len(sys.argv) > 2 and sys.argv[2] == "all"
    for ib in d.get("obj", []):
        proto = ib.get("protocol", "")
        raw_remark = ib.get("remark", "").lower()
        # Исключаем по протоколу: mixed=Socks, ws=WebSocket
        if proto in ("mixed", "ws"):
            continue
        # Исключаем по названию если содержит socks
        if "socks" in raw_remark:
            continue
        enabled = ib.get("enable", True)
        if not show_all and not enabled:
            continue
        raw = ib.get("remark", "")
        name = ""
        for c in raw:
            cp = ord(c)
            if 0x20 <= cp < 0x2000 and c.isprintable():
                name += c
        name = name.strip() or "id={}".format(ib["id"])
        status = "on" if enabled else "off"
        print("{}|{}|{}|{}|{}".format(
            ib["id"], name, ib.get("protocol",""), ib.get("port",""), status))
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF

    cat > /tmp/xui_getid.py << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    ib_id, email = sys.argv[2], sys.argv[3]
    for ib in d.get("obj", []):
        if str(ib["id"]) == ib_id:
            s = json.loads(ib.get("settings", "{}"))
            for c in s.get("clients", []):
                if c.get("email") == email:
                    print(c.get("id", ""))
                    break
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF

    # Универсальный helper для записи в SQLite (без проблем с кавычками/кириллицей)
    cat > /tmp/xui_db_write.py << 'PYEOF'
import json, sys, sqlite3, os
DB = "/etc/x-ui/x-ui.db"
mode = os.environ.get("MODE", "rename")
ib_id = os.environ.get("IB_ID", "")
old_email = os.environ.get("OLD_EMAIL", "")
new_email = os.environ.get("NEW_EMAIL", "")
field = os.environ.get("FIELD", "")
value = os.environ.get("VALUE", "")
try:
    conn = sqlite3.connect(DB)
    # surrogateescape чтобы не падать на битых UTF-8 в старых записях
    conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
    cur = conn.cursor()
    cur.execute("SELECT settings FROM inbounds WHERE id=?", (ib_id,))
    row = cur.fetchone()
    if not row:
        print("err:inbound not found"); conn.close(); sys.exit(1)
    s = json.loads(row[0])
    if mode == "rename":
        for c in s.get("clients", []):
            if c.get("email") == old_email:
                c["email"] = new_email; break
        cur.execute("UPDATE client_traffics SET email=? WHERE email=?", (new_email, old_email))
    elif mode == "update":
        for c in s.get("clients", []):
            if c.get("email") == old_email:
                if field == "enable":
                    c[field] = (value.lower() == "true")
                else:
                    try: c[field] = int(value)
                    except (ValueError, TypeError): c[field] = value
                break
    elif mode == "delete":
        before = len(s.get("clients", []))
        s["clients"] = [c for c in s.get("clients", []) if c.get("email") != old_email]
        if len(s.get("clients", [])) == before:
            print("err:client not found"); conn.close(); sys.exit(1)
        cur.execute("DELETE FROM client_traffics WHERE email=?", (old_email,))
    cur.execute("UPDATE inbounds SET settings=? WHERE id=?",
        (json.dumps(s, ensure_ascii=False), ib_id))
    conn.commit(); conn.close()
    print("ok")
except Exception as e:
    print("err:" + str(e))
PYEOF
}


# Парсит клиентов
_3xui_parse_clients() {
    local cookie="$1"
    local jf; jf=$(mktemp)
    _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
    python3 /tmp/xui_parse.py "$jf" 2>/dev/null
    rm -f "$jf"
}

# Список доступных inbound'ов (без WS и Socks5)
_3xui_select_inbounds() {
    local cookie="$1" show_all="${2:-}"
    local jf; jf=$(mktemp)
    _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
    if [ "$show_all" = "all" ]; then
        python3 /tmp/xui_inbounds.py "$jf" all 2>/dev/null
    else
        python3 /tmp/xui_inbounds.py "$jf" 2>/dev/null
    fi
    rm -f "$jf"
}

# Имя inbound'а по id (использует xui_inbounds.py)
_3xui_inbound_name() {
    local ib_id="$1" cookie="$2"
    local jf; jf=$(mktemp)
    _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
    python3 /tmp/xui_inbounds.py "$jf" all 2>/dev/null | grep "^${ib_id}|" | cut -d'|' -f2
    rm -f "$jf"
}

# Ссылка подписки
_3xui_sub_link() {
    local sub_id="$1"
    _3xui_load_config
    if [ -n "$XUI_SUB_DOMAIN" ]; then
        echo "https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}${sub_id}"
    elif [ -n "$MY_IP" ] && [ -n "$XUI_SUB_PORT" ]; then
        echo "http://${MY_IP}:${XUI_SUB_PORT}${XUI_SUB_PATH}${sub_id}"
    else
        echo "(подписка не настроена — subDomain или subPort пустые)"
    fi
}

# Генерация UUID и subId
_gen_uuid() {
    python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        cat /proc/sys/kernel/random/uuid 2>/dev/null
}
_gen_subid() {
    python3 -c "import random,string; print(''.join(random.choices(string.ascii_lowercase+string.digits,k=16)))" 2>/dev/null || \
        openssl rand -hex 8
}

# Форматирование байт
_fmt_bytes() {
    local b="${1:-0}"
    python3 -c "
b=int($b)
if b<1024: print('{}B'.format(b))
elif b<1048576: print('{:.1f}K'.format(b/1024))
elif b<1073741824: print('{:.1f}M'.format(b/1048576))
else: print('{:.1f}G'.format(b/1073741824))
" 2>/dev/null || echo "${b}B"
}

# Добавляет клиента в inbound
# ── Вспомогательная: перезапуск xray после изменений в БД
_3xui_restart_xray() {
    # x-ui-pro использует API для перезапуска xray
    curl -sk -X POST \
        -H "Cookie: $1" \
        "${XUI_BASE}/panel/api/server/restartXrayService" \
        -H 'Content-Type: application/json' \
        -d '{}' > /dev/null 2>&1 || true
}

# ── Добавляет клиента через API addClient (работает в этой версии)
_3xui_add_client_to_inbound() {
    local ib_id="$1" email="$2" uuid="$3" sub_id="$4" cookie="$5"
    local df; df=$(mktemp)
    python3 - "$ib_id" "$email" "$uuid" "$sub_id" > "$df" << 'PYEOF'
import json, sys
ib_id, email, uuid, sub_id = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
c = {"id": uuid, "email": email, "subId": sub_id, "enable": True,
     "flow": "xtls-rprx-vision", "limitIp": 0, "totalGB": 0,
     "expiryTime": 0, "reset": 0, "tgId": "", "comment": ""}
print(json.dumps({"id": int(ib_id), "settings": json.dumps({"clients": [c]})}))
PYEOF
    local res
    res=$(curl -sk -X POST -H "Cookie: $cookie" \
        -H 'Content-Type: application/json' \
        -d "@${df}" \
        "${XUI_BASE}/panel/api/inbounds/addClient" 2>/dev/null)
    rm -f "$df"
    echo "$res"
}

# ── Удаляет клиента через SQLite напрямую
_3xui_del_client_from_inbound() {
    local ib_id="$1" email="$2" cookie="$3"
    local result
    result=$(MODE=delete IB_ID="$ib_id" OLD_EMAIL="$email" \
        python3 /tmp/xui_db_write.py 2>/dev/null)
    if [ "$result" = "ok" ]; then
        echo '{"success":true,"msg":"deleted"}'
        echo -e "  ${CYAN}↻ Применяю изменения...${NC}" >&2
        _3xui_restart_xray "$cookie"
    else
        echo '{"success":false,"msg":"'"${result#err:}"'"}'
    fi
}


# ── Обновляет поле клиента через SQLite
_3xui_update_client_field() {
    local inbounds="$1" emails_map="$2" field="$3" value="$4" cookie="$5"
    local ok=0 fail=0

    IFS=',' read -ra ib_arr <<< "$inbounds"
    for ib_id in "${ib_arr[@]}"; do
        local exact_email
        exact_email=$(echo "$emails_map" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
        [ -z "$exact_email" ] && continue

        local result
        result=$(MODE=update IB_ID="$ib_id" OLD_EMAIL="$exact_email" \
            FIELD="$field" VALUE="$value" python3 /tmp/xui_db_write.py 2>/dev/null)

        if [ "$result" = "ok" ]; then
            (( ok++ ))
        else
            local err="${result#err:}"
            echo -e "  ${YELLOW}⚠ inbound ${ib_id}: ${err}${NC}"
            (( fail++ ))
        fi
    done

    [ "$ok" -gt 0 ] && _3xui_restart_xray "$cookie"

    if [ "$ok" -gt 0 ]; then
        echo -e "  ${GREEN}✓ Обновлено в ${ok} протокол(ах)${NC}"
    fi
    [ "$fail" -gt 0 ] && echo -e "  ${RED}✗ Не удалось: ${fail} протокол(ов)${NC}"
    read -p "  Enter..." < /dev/tty
}


# Добавить нового клиента
# Суффиксы для уникальных email по inbound
# Порядок inbound'ов: 1й=(-_•), 2й=(•_-), 3й=(•_•), 4й=(-_-)
# Разделитель групп клиента по inbound'ам
XUI_SEP='(-_•)'

# Формирует email клиента для конкретного inbound
# Формат: BaseName(-_•)N  (где N = id inbound'а)
_3xui_email_for_inbound() {
    local base_email="$1" ib_id="$2"
    echo "${base_email}${XUI_SEP}${ib_id}"
}

# Извлекает base email из email с суффиксом
_3xui_base_email() {
    local email="$1"
    # Убираем (-_•)N в конце
    echo "$email" | sed "s/(-_•)[0-9]*$//"
}

_3xui_add_client_menu() {
    local cookie="$1"
    clear
    echo -e "\n${CYAN}━━━ Добавить клиента ━━━${NC}\n"

    echo -ne "  Имя клиента: "; read -r base_email < /dev/tty
    [ -z "$base_email" ] && return

    local uuid sub_id
    uuid=$(_gen_uuid); sub_id=$(_gen_subid)

    # Загружаем активные inbound'ы
    local -a available_ibs=()
    local _sf; _sf=$(mktemp)
    _3xui_select_inbounds "$cookie" > "$_sf" 2>/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && available_ibs+=("$line")
    done < "$_sf"
    rm -f "$_sf"

    if [ ${#available_ibs[@]} -eq 0 ]; then
        echo -e "  ${RED}✗ Нет активных протоколов${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    echo -e "\n  ${WHITE}Доступные протоколы:${NC}\n"
    local i=1
    for ib in "${available_ibs[@]}"; do
        IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
        echo -e "  ${YELLOW}[$i]${NC}  ${ib_name}  ${CYAN}(${ib_proto}:${ib_port})${NC}  → email: ${base_email}${XUI_SEP}${ib_id}"
        (( i++ ))
    done
    echo ""
    echo -e "  ${GREEN}[a]${NC}  Все сразу ${CYAN}(рекомендуется)${NC}"
    echo ""
    echo -e "  ${WHITE}Введите номер(а) через пробел или 'a':${NC}"
    echo -ne "  → "; read -r sel < /dev/tty

    local -a selected_idx=()
    if [[ "$sel" == [aAаА] ]]; then
        for (( j=0; j<${#available_ibs[@]}; j++ )); do selected_idx+=("$j"); done
    else
        for num in $sel; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#available_ibs[@]} )); then
                selected_idx+=("$((num-1))")
            fi
        done
    fi

    if [ ${#selected_idx[@]} -eq 0 ]; then
        echo -e "\n  ${YELLOW}Ничего не выбрано${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    echo ""
    local success=0 fail=0
    for idx in "${selected_idx[@]}"; do
        local ib="${available_ibs[$idx]}"
        IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
        local email; email=$(_3xui_email_for_inbound "$base_email" "${available_ibs[$idx]%%|*}")
        echo -ne "  ${CYAN}→ ${ib_name} [${email}]...${NC} "
        local res; res=$(_3xui_add_client_to_inbound "$ib_id" "$email" "$uuid" "$sub_id" "$cookie")
        if echo "$res" | grep -q '"success":true'; then
            echo -e "${GREEN}✓${NC}"; (( success++ ))
        else
            local msg; msg=$(echo "$res" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('msg',''))" 2>/dev/null)
            echo -e "${RED}✗${NC}  ${msg}"; (( fail++ ))
        fi
    done

    if [ "$success" -gt 0 ]; then
        local sub_link; sub_link=$(_3xui_sub_link "$sub_id")
        echo -e "\n  ${GREEN}✅ Готово! Добавлен в ${success} протокол(ов)${NC}"
        echo -e "  ${WHITE}Имена:${NC}"
        for idx in "${selected_idx[@]}"; do
            local _ib_id="${available_ibs[$idx]%%|*}"
            echo -e "    ${CYAN}${base_email}${XUI_SEP}${_ib_id}${NC}"
        done
        echo -e "\n  ${WHITE}Подписка:${NC}\n  ${CYAN}${sub_link}${NC}\n"
        command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
        command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$sub_link"
        log_action "3XUI: добавлен ${base_email} subId=${sub_id}"
    fi
    [ "$fail" -gt 0 ] && echo -e "  ${YELLOW}⚠ ${fail} протокол(ов) не добавилось${NC}"
    read -p "  Enter..." < /dev/tty
}

_3xui_add_inbound_to_client() {
    local email="$1" sub_id="$2" current_inbounds="$3" emails_map="${4:-}" cookie="${5:-$4}"
    clear
    echo -e "\n${CYAN}━━━ Добавить протокол: ${email} ━━━${NC}\n"

    # Получаем UUID — ищем по каждому известному email из emails_map
    local first_ib="${current_inbounds%%,*}"
    local jf; jf=$(mktemp)
    _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
    local uuid=""
    # Перебираем все email'ы из emails_map
    while IFS= read -r _pair; do
        [ -z "$_pair" ] && continue
        local _ib="${_pair%%:*}" _em="${_pair##*:}"
        local _u; _u=$(python3 /tmp/xui_getid.py "$jf" "$_ib" "$_em" 2>/dev/null)
        if [ -n "$_u" ]; then uuid="$_u"; break; fi
    done <<< "$(echo "$emails_map" | tr ';' '\n')"
    # Fallback: базовый email и суффиксы
    if [ -z "$uuid" ]; then
        local base_email; base_email=$(_3xui_base_email "$email")
        # Перебираем возможные форматы: новый Name(-_•)N и старый с суффиксами
        for _ib in $(echo "$current_inbounds" | tr ',' ' '); do
            uuid=$(python3 /tmp/xui_getid.py "$jf" "$_ib" "${base_email}${XUI_SEP}${_ib}" 2>/dev/null)
            [ -n "$uuid" ] && break
        done
    fi
    rm -f "$jf"

    if [ -z "$uuid" ]; then
        echo -e "  ${RED}✗ Не удалось найти UUID клиента${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    # Inbound'ы которых ещё нет у клиента
    local -a available=()
    local _sf; _sf=$(mktemp)
    _3xui_select_inbounds "$cookie" > "$_sf" 2>/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local ib_id="${line%%|*}"
        [[ ",$current_inbounds," == *",$ib_id,"* ]] && continue
        available+=("$line")
    done < "$_sf"
    rm -f "$_sf"

    if [ ${#available[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}Клиент уже во всех активных протоколах${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    local i=1
    for ib in "${available[@]}"; do
        IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
        local base_em; base_em=$(_3xui_base_email "$email")
        echo -e "  ${YELLOW}[$i]${NC}  ${ib_name}  ${CYAN}(${ib_proto}:${ib_port})${NC}  → ${base_em}${XUI_SEP}${ib_id}"
        (( i++ ))
    done
    echo -e "\n  ${GREEN}[a]${NC}  Все сразу"
    echo ""
    echo -ne "  Выбор: "; read -r sel < /dev/tty

    local -a selected_idx=()
    if [[ "$sel" == [aAаА] ]]; then
        for (( j=0; j<${#available[@]}; j++ )); do selected_idx+=("$j"); done
    else
        for num in $sel; do
            [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#available[@]} )) && \
                selected_idx+=("$((num-1))")
        done
    fi
    [ ${#selected_idx[@]} -eq 0 ] && { read -p "  Enter..." < /dev/tty; return; }

    local base_email; base_email=$(_3xui_base_email "$email")
    echo ""
    for idx in "${selected_idx[@]}"; do
        local ib="${available[$idx]}"
        IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
        local new_email; new_email=$(_3xui_email_for_inbound "$base_email" "$ib_id")
        echo -ne "  ${CYAN}→ ${ib_name} [${new_email}]...${NC} "
        local res; res=$(_3xui_add_client_to_inbound "$ib_id" "$new_email" "$uuid" "$sub_id" "$cookie")
        echo "$res" | grep -q '"success":true' && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    done
    log_action "3XUI: ${email} добавлен в протоколы"
    read -p "  Enter..." < /dev/tty
}


_3xui_del_inbound_from_client() {
    local email="$1" current_inbounds="$2" emails_map="${3:-}" cookie="${4:-$3}"
    clear
    echo -e "\n${CYAN}━━━ Удалить протокол: ${email} ━━━${NC}\n"

    IFS=',' read -ra ib_arr <<< "$current_inbounds"
    if [ ${#ib_arr[@]} -le 1 ]; then
        echo -e "  ${YELLOW}Только один протокол — используйте 'Удалить клиента'.${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    local i=1
    for ib_id in "${ib_arr[@]}"; do
        local ib_name; ib_name=$(_3xui_inbound_name "$ib_id" "$cookie")
        echo -e "  ${YELLOW}[$i]${NC}  ${ib_name:-id=$ib_id} (id=${ib_id})"
        (( i++ ))
    done
    echo ""
    echo -ne "  Номер протокола для удаления: "; read -r num < /dev/tty
    [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#ib_arr[@]} )) || { read -p "  Enter..." < /dev/tty; return; }

    local target="${ib_arr[$((num-1))]}"
    local ib_name; ib_name=$(_3xui_inbound_name "$target" "$cookie")
    echo -ne "  ${RED}Удалить ${email} из ${ib_name:-id=$target}? (y/n): ${NC}"
    read -r c < /dev/tty
    [[ "$c" != "y" ]] && return

    # Находим точный email для этого inbound из emails_map
    local exact_em=""
    if [ -n "$emails_map" ]; then
        exact_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${target}:" | cut -d: -f2-)
    fi
    # Если нет в map — перебираем суффиксы
    [ -z "$exact_em" ] && exact_em="$email"
    local res; res=$(_3xui_del_client_from_inbound "$target" "$exact_em" "$cookie")
    if ! echo "$res" | grep -q '"success":true'; then
        local base; base=$(_3xui_base_email "$email")
        # Пробуем новый формат Name#N(-_•)
        res=$(_3xui_del_client_from_inbound "$target" "${base}${XUI_SEP}${target}" "$cookie")
        if ! echo "$res" | grep -q '"success":true'; then
            # Старый формат с суффиксами
            for sfx in '(-_•)' '(•_-)' '(•_•)' '(-_-)'; do
                res=$(_3xui_del_client_from_inbound "$target" "${base}${sfx}" "$cookie")
                echo "$res" | grep -q '"success":true' && break
            done
        fi
    fi
    echo "$res" | grep -q '"success":true' && \
        echo -e "  ${GREEN}✓ Удалён из ${ib_name:-id=$target}${NC}" || \
        echo -e "  ${RED}✗ Ошибка${NC}"
    log_action "3XUI: ${email} удалён из ${target}"
    read -p "  Enter..." < /dev/tty
}

# Включение / отключение inbound'ов
_3xui_toggle_inbounds_menu() {
    local cookie="$1"
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Управление протоколами ━━━${NC}\n"

        # Загружаем ВСЕ inbound'ы включая отключённые
        local -a all_ibs=()
        local _sf; _sf=$(mktemp)
        _3xui_select_inbounds "$cookie" all > "$_sf" 2>/dev/null
        while IFS= read -r line; do
            [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && all_ibs+=("$line")
        done < "$_sf"
        rm -f "$_sf"

        if [ ${#all_ibs[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}Протоколов не найдено${NC}"
            read -p "  Enter..." < /dev/tty; return
        fi

        local i=1
        for ib in "${all_ibs[@]}"; do
            IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
            local st_col
            [ "$ib_status" = "on" ] && st_col="${GREEN}● вкл${NC}" || st_col="${RED}● выкл${NC}"
            printf "  ${YELLOW}[%d]${NC}  %-22s ${CYAN}(%s:%s)${NC}  %b\n" \
                "$i" "$ib_name" "$ib_proto" "$ib_port" "$st_col"
            (( i++ ))
        done

        echo ""
        echo -e "  ${WHITE}Выберите номер для переключения (вкл/выкл)${NC}"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        if [[ "$ch" =~ ^[1-9][0-9]*$ ]] && (( ch >= 1 && ch <= ${#all_ibs[@]} )); then
            local ib="${all_ibs[$((ch-1))]}"
            IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"

            local action new_status
            if [ "$ib_status" = "on" ]; then
                action="отключить"; new_status="false"
            else
                action="включить"; new_status="true"
            fi

            echo -ne "  ${YELLOW}${action^} ${ib_name}? (y/n): ${NC}"
            read -r c < /dev/tty
            [[ "$c" != "y" ]] && continue

            # Получаем полный объект inbound и меняем enable
            local jf; jf=$(mktemp)
            _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
            local upd_data
            upd_data=$(python3 - "$jf" "$ib_id" "$new_status" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    ib_id, new_en = sys.argv[2], sys.argv[3] == "true"
    for ib in d.get("obj", []):
        if str(ib["id"]) == ib_id:
            ib["enable"] = new_en
            # API принимает объект inbound целиком
            print(json.dumps(ib))
            break
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF
            )
            rm -f "$jf"

            if [ -z "$upd_data" ]; then
                echo -e "  ${RED}✗ Ошибка получения данных inbound${NC}"
                read -p "  Enter..." < /dev/tty; continue
            fi

            local res
            res=$(_3xui_api POST "/panel/api/inbounds/update/${ib_id}" "$upd_data" "$cookie")

            if echo "$res" | grep -q '"success":true'; then
                local done_msg
                [ "$new_status" = "true" ] && done_msg="${GREEN}✓ Включён${NC}" || done_msg="${YELLOW}✓ Отключён${NC}"
                echo -e "  ${done_msg}: ${ib_name}"
                log_action "3XUI: inbound ${ib_id} (${ib_name}) → enable=${new_status}"
            else
                local err; err=$(echo "$res" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('msg',''))" 2>/dev/null)
                echo -e "  ${RED}✗ Ошибка: ${err}${NC}"
            fi
            read -p "  Enter..." < /dev/tty
        fi
    done
}

# ─── Профиль клиента ────────────────────────────────────────

_3xui_client_profile() {
    local client_str="$1" cookie="$2"
    IFS='|' read -r email sub_id inbounds enable up down emails_map <<< "$client_str"

    # Получает ограничения клиента из SQLite
    _get_client_limits() {
        local first_ib="${inbounds%%,*}"
        local first_email
        first_email=$(echo "$emails_map" | tr ';' '\n' | grep "^${first_ib}:" | cut -d: -f2-)
        [ -z "$first_email" ] && first_email="$email"
        python3 - "$first_ib" "$first_email" << 'PYEOF'
import json, sys, subprocess
from datetime import datetime
ib_id, email = sys.argv[1], sys.argv[2]
try:
    r = subprocess.run(['sqlite3', '/etc/x-ui/x-ui.db',
        f"SELECT settings FROM inbounds WHERE id={ib_id};"],
        capture_output=True, text=True, timeout=2)
    s = json.loads(r.stdout.strip())
    for c in s.get("clients", []):
        if c.get("email") == email:
            total_gb = c.get("totalGB", 0)
            expiry = c.get("expiryTime", 0)
            limit_ip = c.get("limitIp", 0)
            gb_str = "{:.1f} GB".format(total_gb/1073741824) if total_gb > 0 else "∞"
            if expiry and expiry > 0:
                dt = datetime.fromtimestamp(expiry/1000)
                exp_str = dt.strftime("%d.%m.%Y")
            else:
                exp_str = "∞"
            ip_str = str(limit_ip) if limit_ip > 0 else "∞"
            print("{}|{}|{}|{}|{}".format(gb_str, exp_str, ip_str, total_gb, expiry))
            break
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
    print("∞|∞|∞|0|0")
PYEOF
    }

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиент: ${email} ━━━${NC}\n"
        echo -e "  ${WHITE}SubId:${NC}    ${CYAN}${sub_id}${NC}"
        echo -e "  ${WHITE}Статус:${NC}   $([ "$enable" = "on" ] && echo -e "${GREEN}● активен${NC}" || echo -e "${RED}● отключён${NC}")"

        # Трафик из SQLite
        local real_up=0 real_down=0
        while IFS= read -r _em; do
            [ -z "$_em" ] && continue
            local _row
            _row=$(sqlite3 /etc/x-ui/x-ui.db "SELECT up, down FROM client_traffics WHERE email='${_em}' LIMIT 1;" 2>/dev/null)
            if [ -n "$_row" ]; then
                real_up=$(( real_up + ${_row%%|*} ))
                real_down=$(( real_down + ${_row##*|} ))
            fi
        done <<< "$(echo "$emails_map" | tr ';' '\n' | cut -d: -f2-)"
        local up_f down_f
        up_f=$(_fmt_bytes "$real_up"); down_f=$(_fmt_bytes "$real_down")
        echo -e "  ${WHITE}Трафик:${NC}   ↑${up_f} / ↓${down_f}"

        # Ограничения
        local limits_str lim_gb lim_exp lim_ip raw_gb raw_exp
        limits_str=$(_get_client_limits)
        IFS='|' read -r lim_gb lim_exp lim_ip raw_gb raw_exp <<< "$limits_str"
        echo -e "  ${WHITE}Лимит:${NC}    ${CYAN}${lim_gb}${NC}  •  Истекает: ${CYAN}${lim_exp}${NC}  •  IP: ${CYAN}${lim_ip}${NC}"

        # Протоколы
        echo -e "\n  ${WHITE}Протоколы:${NC}"
        IFS=',' read -ra ib_arr <<< "$inbounds"
        for ib_id in "${ib_arr[@]}"; do
            local ib_nm; ib_nm=$(_3xui_inbound_name "$ib_id" "$cookie")
            local ex_em
            ex_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
            echo -e "    ${CYAN}• ${ib_nm:-id=$ib_id}${NC}  ${WHITE}[${ex_em}]${NC}"
        done

        local sub_link; sub_link=$(_3xui_sub_link "$sub_id")
        echo -e "\n  ${WHITE}Подписка:${NC}\n  ${CYAN}${sub_link}${NC}\n"

        echo -e "  ${WHITE}── Подписка ──────────────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  QR-код подписки"
        echo -e "  ${CYAN}[r]${NC}  QR настройки Happ/INCY (roscomvpn маршрутизация)"
        echo -e "  ${WHITE}── Ограничения ───────────────────────${NC}"
        echo -e "  ${YELLOW}[2]${NC}  Лимит ГБ          ${CYAN}(${lim_gb})${NC}"
        echo -e "  ${YELLOW}[3]${NC}  Срок действия     ${CYAN}(${lim_exp})${NC}"
        echo -e "  ${YELLOW}[4]${NC}  Сбросить трафик"
        echo -e "  ${WHITE}── Протоколы / имя ───────────────────${NC}"
        echo -e "  ${GREEN}[5]${NC}  Добавить протокол"
        echo -e "  ${RED}[6]${NC}  Удалить протокол"
        echo -e "  ${YELLOW}[7]${NC}  Переименовать стек"
        echo -e "  ${WHITE}── Статус / удаление ─────────────────${NC}"
        if [ "$enable" = "on" ]; then
            echo -e "  ${YELLOW}[e]${NC}  Отключить стек"
        else
            echo -e "  ${YELLOW}[e]${NC}  ${GREEN}Включить стек${NC}"
        fi
        echo -e "  ${RED}[8]${NC}  Удалить полностью"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        case "$ch" in
            [rR])
                command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
                clear
                echo -e "\n${CYAN}━━━ Настройка Happ / INCY (roscomvpn) ━━━${NC}\n"
                echo -e "  ${WHITE}Шаг 1:${NC} Отсканируй QR подписки (п.[1]) и добавь в Happ"
                echo -e "  ${WHITE}Шаг 2:${NC} Добавь маршрутизацию roscomvpn — отсканируй QR ниже:"
                echo ""
                echo "https://routing.help" | qrencode -t ANSIUTF8 2>/dev/null
                echo -e "\n  ${CYAN}https://routing.help${NC}"
                echo -e "\n  ${WHITE}Что получишь:${NC}"
                echo -e "  ${GREEN}✓${NC} РФ/РБ сайты — напрямую (без VPN)"
                echo -e "  ${GREEN}✓${NC} Заблокированные (YouTube, Instagram) — через VPN"
                echo -e "  ${GREEN}✓${NC} Реклама — заблокирована"
                echo -e "  ${GREEN}✓${NC} Автообновление правил"
                echo ""
                read -p "  Enter..." < /dev/tty ;;
            1)
                command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
                echo ""; qrencode -t ANSIUTF8 "$sub_link"
                read -p "  Enter..." < /dev/tty ;;
            2)
                echo -e "\n  ${WHITE}Лимит трафика:${NC}  Текущий: ${CYAN}${lim_gb}${NC}"
                echo -e "  Введите новый лимит в ГБ (0 = без лимита):"
                echo -ne "  → "; read -r new_gb < /dev/tty
                [[ "$new_gb" =~ ^[0-9]+(\.?[0-9]*)$ ]] || { echo -e "  ${RED}✗ Неверный формат${NC}"; read -p "  Enter..." < /dev/tty; continue; }
                local new_gb_bytes
                new_gb_bytes=$(python3 -c "print(int(float('$new_gb') * 1073741824))" 2>/dev/null)
                _3xui_update_client_field "$inbounds" "$emails_map" "totalGB" "$new_gb_bytes" "$cookie"
                limits_str=$(_get_client_limits)
                IFS='|' read -r lim_gb lim_exp lim_ip raw_gb raw_exp <<< "$limits_str" ;;
            3)
                echo -e "\n  ${WHITE}Срок действия:${NC}  Текущий: ${CYAN}${lim_exp}${NC}"
                echo -e "  ${YELLOW}[1]${NC}  30 дней   ${YELLOW}[2]${NC}  90 дней"
                echo -e "  ${YELLOW}[3]${NC}  180 дней  ${YELLOW}[4]${NC}  1 год"
                echo -e "  ${YELLOW}[5]${NC}  Без ограничений"
                echo -e "  ${YELLOW}[6]${NC}  Указать дату (ДД.ММ.ГГГГ)"
                echo -ne "  → "; read -r exp_ch < /dev/tty
                local new_expiry=0
                case "$exp_ch" in
                    1) new_expiry=$(python3 -c "import time; print(int((time.time()+30*86400)*1000))");;
                    2) new_expiry=$(python3 -c "import time; print(int((time.time()+90*86400)*1000))");;
                    3) new_expiry=$(python3 -c "import time; print(int((time.time()+180*86400)*1000))");;
                    4) new_expiry=$(python3 -c "import time; print(int((time.time()+365*86400)*1000))");;
                    5) new_expiry=0;;
                    6)
                        echo -ne "  Дата (ДД.ММ.ГГГГ): "; read -r dstr < /dev/tty
                        new_expiry=$(python3 -c "
from datetime import datetime
try:
    dt=datetime.strptime('$dstr','%d.%m.%Y')
    print(int(dt.timestamp()*1000))
except: print(0)
" 2>/dev/null);;
                    *) continue;;
                esac
                _3xui_update_client_field "$inbounds" "$emails_map" "expiryTime" "$new_expiry" "$cookie"
                limits_str=$(_get_client_limits)
                IFS='|' read -r lim_gb lim_exp lim_ip raw_gb raw_exp <<< "$limits_str" ;;
            4)
                # Сброс трафика через SQLite
                IFS=',' read -ra ib_arr <<< "$inbounds"
                local ok=0
                for ib_id in "${ib_arr[@]}"; do
                    local ex_em
                    ex_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
                    [ -z "$ex_em" ] && continue
                    sqlite3 /etc/x-ui/x-ui.db \
                        "UPDATE client_traffics SET up=0, down=0 WHERE email='${ex_em}';" 2>/dev/null && (( ok++ ))
                done
                _3xui_restart_xray "$cookie"
                echo -e "  ${GREEN}✓ Трафик сброшен (${ok} записей)${NC}"
                real_up=0; real_down=0
                read -p "  Enter..." < /dev/tty ;;
            5)
                _3xui_add_inbound_to_client "$email" "$sub_id" "$inbounds" "$emails_map" "$cookie"
                return ;;
            6)
                _3xui_del_inbound_from_client "$email" "$inbounds" "$emails_map" "$cookie"
                return ;;
            7)
                # Переименование / причёсывание
                echo -e "\n  ${CYAN}━━━ Переименовать клиента ━━━${NC}\n"
                echo -e "  ${WHITE}Текущие имена по протоколам:${NC}"
                echo "$emails_map" | tr ';' '\n' | while IFS=: read -r _ib _em; do
                    [ -z "$_ib" ] && continue
                    local _nm; _nm=$(_3xui_inbound_name "$_ib" "$cookie")
                    echo -e "    ${CYAN}${_nm:-id=$_ib}${NC}: ${YELLOW}${_em}${NC}"
                done
                echo ""
                echo -e "  ${WHITE}Новое базовое имя${NC} (Enter = '${email}'):"
                echo -ne "  → "; read -r new_base < /dev/tty
                [ -z "$new_base" ] && new_base="$email"

                # Проверяем что имя свободно (только если изменилось)
                if [ "$new_base" != "$email" ]; then
                    local _cf2; _cf2=$(mktemp)
                    _3xui_parse_clients "$cookie" > "$_cf2" 2>/dev/null
                    local _exists; _exists=$(grep "^${new_base}|" "$_cf2" 2>/dev/null)
                    rm -f "$_cf2"
                    if [ -n "$_exists" ]; then
                        echo -e "  ${RED}✗ Имя '${new_base}' уже занято${NC}"
                        read -p "  Enter..." < /dev/tty; continue
                    fi
                fi

                echo -e "\n  ${WHITE}Результат:${NC}"
                IFS=',' read -ra ib_arr <<< "$inbounds"
                for _ib_id in "${ib_arr[@]}"; do
                    local _nm; _nm=$(_3xui_inbound_name "$_ib_id" "$cookie")
                    echo -e "    ${GREEN}${new_base}${XUI_SEP}${_ib_id}${NC}  ← ${_nm}"
                done
                echo ""
                echo -ne "  ${WHITE}Применить? (y/n): ${NC}"
                read -r c < /dev/tty
                [ "$c" != "y" ] && continue

                local ren_ok=0
                for _ib_id in "${ib_arr[@]}"; do
                    local old_em new_em
                    old_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${_ib_id}:" | cut -d: -f2-)
                    [ -z "$old_em" ] && continue
                    new_em="${new_base}${XUI_SEP}${_ib_id}"
                    [ "$old_em" = "$new_em" ] && (( ren_ok++ )) && continue
                    # Переименование через env-переменные и python sqlite3 (без проблем с кавычками)
                    local ren_res _nef; _nef=$(mktemp)
                    printf '%s' "$new_em" > "$_nef"
                    ren_res=$(MODE=rename IB_ID="$_ib_id" OLD_EMAIL="$old_em" \
                        NEW_EMAIL="$new_em" python3 /tmp/xui_db_write.py 2>/dev/null)
                    rm -f "$_nef"
                    if [ "$ren_res" = "ok" ]; then
                        (( ren_ok++ ))
                        echo -e "  ${GREEN}✓ id=${_ib_id}: ok${NC}"
                    else
                        echo -e "  ${RED}✗ id=${_ib_id}: ${ren_res#err:}${NC}"
                    fi
                done

                if [ "$ren_ok" -gt 0 ]; then
                    _3xui_restart_xray "$cookie"
                    echo -e "  ${GREEN}✓ Готово (${ren_ok} протокол(ов)): ${new_base}${XUI_SEP}N${NC}"
                    log_action "3XUI: переименован ${email} → ${new_base}"
                    read -p "  Enter..." < /dev/tty
                    return
                else
                    echo -e "  ${RED}✗ Не удалось применить${NC}"
                    read -p "  Enter..." < /dev/tty
                fi ;;
            [eE])
                # Вкл/выкл всего стека подписки
                local new_enable
                [ "$enable" = "on" ] && new_enable="false" || new_enable="true"
                local tog_ok=0
                IFS=',' read -ra ib_arr <<< "$inbounds"
                for ib_id in "${ib_arr[@]}"; do
                    local ex_em
                    ex_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
                    [ -z "$ex_em" ] && continue
                    local tog_res
                    # toggle enable через xui_db_write: используем update mode с полем enable
                    tog_res=$(MODE=update IB_ID="$ib_id" OLD_EMAIL="$ex_em" \
                        FIELD="enable" VALUE="$new_enable" python3 /tmp/xui_db_write.py 2>/dev/null)
                    [ "$tog_res" = "ok" ] && (( tog_ok++ ))
                done
                if [ "$tog_ok" -gt 0 ]; then
                    _3xui_restart_xray "$cookie"
                    [ "$new_enable" = "true" ] && enable="on" || enable="off"
                    local st_msg
                    [ "$enable" = "on" ] && \
                        echo -e "  ${GREEN}✓ Включён${NC}: ${email} (${tog_ok} протокол(ов))" || \
                        echo -e "  ${RED}✓ Отключён${NC}: ${email} (${tog_ok} протокол(ов))"
                    log_action "3XUI: ${email} enable=${new_enable}"
                fi
                read -p "  Enter..." < /dev/tty ;;
            8)
                echo -ne "\n  ${RED}Удалить ${email} из всех протоколов? (y/n): ${NC}"
                read -r c < /dev/tty
                [[ "$c" != "y" ]] && continue
                echo -e "  ${YELLOW}Удаляю...${NC}"
                IFS=',' read -ra ib_arr <<< "$inbounds"
                local ok=0 fail=0
                for ib_id in "${ib_arr[@]}"; do
                    # Ищем точный email из emails_map
                    local ex_em
                    ex_em=$(echo "$emails_map" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
                    # Fallback: ищем по subId напрямую в SQLite
                    if [ -z "$ex_em" ] && [ -n "$sub_id" ]; then
                        ex_em=$(python3 -c "
import json, subprocess
r = subprocess.run(['sqlite3', '/etc/x-ui/x-ui.db',
    'SELECT settings FROM inbounds WHERE id=${ib_id};'],
    capture_output=True, text=True, timeout=3)
try:
    s = json.loads(r.stdout.strip())
    for c in s.get('clients', []):
        if c.get('subId') == '${sub_id}':
            print(c.get('email', '')); break
except: pass
" 2>/dev/null)
                    fi
                    [ -z "$ex_em" ] && { (( fail++ )); continue; }
                    local res; res=$(_3xui_del_client_from_inbound "$ib_id" "$ex_em" "$cookie")
                    if echo "$res" | grep -q '"success":true'; then
                        (( ok++ ))
                    else
                        echo -e "  ${RED}✗ id=${ib_id}: не найден${NC}"
                        (( fail++ ))
                    fi
                done
                _3xui_restart_xray "$cookie"
                echo -e "  ${GREEN}✓ Удалён из ${ok} протокол(ов)${NC}"
                [ "$fail" -gt 0 ] && echo -e "  ${YELLOW}⚠ Не найден в ${fail} протокол(ах)${NC}"
                echo -e "  ${CYAN}↻ Перезапуск xray...${NC}"
                log_action "3XUI: удалён ${email}"
                read -p "  Enter..." < /dev/tty
                return ;;
        esac
    done
}

# ─── Отключённые клиенты ────────────────────────────────────

_3xui_disabled_clients_menu() {
    local filter_ib="$1" ib_label="$2" cookie="$3" srv_label="$4" srv_ip="$5"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Отключённые клиенты: ${ib_label} ━━━${NC}"
        echo -e "  ${WHITE}Сервер:${NC} ${GREEN}${srv_label} (${srv_ip})${NC}\n"

        # Загружаем всех клиентов и фильтруем выключенных
        local -a disabled=()
        local _cf; _cf=$(mktemp)
        _3xui_parse_clients "$cookie" > "$_cf" 2>/dev/null

        while IFS= read -r line; do
            [ -n "$line" ] && ! [[ "$line" == ERR:* ]] || continue
            IFS='|' read -r _e _s inbounds en _rest <<< "$line"
            [ "$en" = "on" ] && continue  # пропускаем включённых
            if [ -n "$filter_ib" ]; then
                [[ ",$inbounds," == *",$filter_ib,"* ]] || continue
            fi
            disabled+=("$line")
        done < "$_cf"
        rm -f "$_cf"

        if [ ${#disabled[@]} -eq 0 ]; then
            echo -e "  ${GREEN}✓ Отключённых клиентов нет${NC}\n"
            read -p "  Enter..." < /dev/tty; return
        fi

        printf "  \033[97m%-4s  %-22s  %-18s  %s\033[0m\n" "№" "Email" "SubId" "Трафик↑/↓"
        echo -e "  ${CYAN}$(printf '─%.0s' {1..56})${NC}"
        local i=1
        for c in "${disabled[@]}"; do
            IFS='|' read -r em sb inbs en up dn emap <<< "$c"
            local ce cs uf df
            ce=$(printf '%s' "$em" | tr -cd '[:print:]' | cut -c1-21)
            cs=$(printf '%s' "$sb" | cut -c1-18)
            uf=$(_fmt_bytes "$up"); df=$(_fmt_bytes "$dn")
            printf "  ${RED}[%-2d]${NC}  %-22s  %-18s  %s/%s\n" \
                "$i" "$ce" "$cs" "$uf" "$df"
            (( i++ ))
        done
        echo ""
        echo -e "  ${WHITE}Выберите номер для включения клиента${NC}"
        echo -e "  ${GREEN}[a]${NC}  Включить всех"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        local targets=()
        if [[ "$ch" == [aAаА] ]]; then
            targets=("${disabled[@]}")
        elif [[ "$ch" =~ ^[1-9][0-9]*$ ]] && (( ch >= 1 && ch <= ${#disabled[@]} )); then
            targets=("${disabled[$((ch-1))]}")
        else
            continue
        fi

        local enabled_cnt=0
        for c in "${targets[@]}"; do
            IFS='|' read -r em sb inbs en up dn emap <<< "$c"
            IFS=',' read -ra ib_arr <<< "$inbs"
            local c_ok=0
            for ib_id in "${ib_arr[@]}"; do
                local ex_em
                ex_em=$(echo "$emap" | tr ';' '\n' | grep "^${ib_id}:" | cut -d: -f2-)
                [ -z "$ex_em" ] && continue
                local res
                res=$(MODE=update IB_ID="$ib_id" OLD_EMAIL="$ex_em" \
                    FIELD="enable" VALUE="true" python3 /tmp/xui_db_write.py 2>/dev/null)
                [ "$res" = "ok" ] && (( c_ok++ ))
            done
            [ "$c_ok" -gt 0 ] && (( enabled_cnt++ )) && \
                echo -e "  ${GREEN}✓ Включён:${NC} ${em}"
        done

        [ "$enabled_cnt" -gt 0 ] && _3xui_restart_xray "$cookie"
        echo -e "  ${GREEN}Включено клиентов: ${enabled_cnt}${NC}"
        log_action "3XUI: включено ${enabled_cnt} клиентов"
        read -p "  Enter..." < /dev/tty
    done
}

# ─── Список клиентов inbound'а ──────────────────────────────

_3xui_clients_list_menu() {
    local filter_ib="$1" ib_label="$2" cookie="$3" srv_label="$4" srv_ip="$5"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиенты: ${ib_label} ━━━${NC}"
        echo -e "  ${WHITE}Сервер:${NC} ${GREEN}${srv_label} (${srv_ip})${NC}\n"

        _3xui_load_config
        local sub_url
        if [ -n "$XUI_SUB_DOMAIN" ]; then
            sub_url="${GREEN}https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}${NC}"
        elif [ -n "$XUI_SUB_PORT" ]; then
            # Автофикс subDomain
            local nginx_domain
            nginx_domain=$(grep -rh 'server_name' /etc/nginx/sites-enabled/ 2>/dev/null | \
                grep -oP 'server_name\s+\K\S+' | grep '\.' | grep -v 'localhost\|_' | head -1)
            if [ -n "$nginx_domain" ]; then
                echo -e "  ${YELLOW}⚠ subDomain пустой — исправить на ${nginx_domain}? (y/n):${NC} "
                read -r fix_c < /dev/tty
                if [ "$fix_c" = "y" ]; then
                    sqlite3 /etc/x-ui/x-ui.db \
                        "UPDATE settings SET value='${nginx_domain}' WHERE key='subDomain';" 2>/dev/null
                    systemctl restart x-ui > /dev/null 2>&1; sleep 1
                    _3xui_load_config
                fi
            fi
            sub_url="${YELLOW}http://${srv_ip}:${XUI_SUB_PORT}${XUI_SUB_PATH}${NC}"
        else
            sub_url="${RED}не настроено${NC}"
        fi
        echo -e "  ${WHITE}Подписки:${NC} ${sub_url}<subId>\n"

        # Загружаем клиентов
        local -a clients=()
        local _cf; _cf=$(mktemp)
        _3xui_parse_clients "$cookie" > "$_cf" 2>/dev/null

        if [ -n "$filter_ib" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && ! [[ "$line" == ERR:* ]] || continue
                IFS='|' read -r _e _s inbounds _rest <<< "$line"
                [[ ",$inbounds," == *",$filter_ib,"* ]] && clients+=("$line")
            done < "$_cf"
        else
            while IFS= read -r line; do
                [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && clients+=("$line")
            done < "$_cf"
        fi
        rm -f "$_cf"

        if [ ${#clients[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}Клиентов нет${NC}\n"
        else
            printf "  \033[97m%-4s  %-22s  %-18s  %-7s  %s\033[0m\n" \
                "№" "Email" "SubId" "Статус" "Трафик↑/↓"
            echo -e "  ${CYAN}$(printf '─%.0s' {1..62})${NC}"
            local i=1
            for c in "${clients[@]}"; do
                IFS='|' read -r em sb inbs en up dn emap <<< "$c"
                local ce cs st uf df
                ce=$(printf '%s' "$em" | tr -cd '[:print:]' | cut -c1-21)
                cs=$(printf '%s' "$sb" | cut -c1-18)
                [ "$en" = "on" ] && st="${GREEN}вкл${NC}" || st="${RED}выкл${NC}"
                uf=$(_fmt_bytes "$up"); df=$(_fmt_bytes "$dn")
                printf "  ${YELLOW}[%-2d]${NC}  %-22s  %-18s  %b    %s/%s\n" \
                    "$i" "$ce" "$cs" "$st" "$uf" "$df"
                (( i++ ))
            done
            echo ""
        fi

        echo -e "  ${GREEN}[a]${NC}  Добавить клиента"
        echo -e "  ${YELLOW}[d]${NC}  Отключённые клиенты"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        if [[ "$ch" =~ ^[1-9][0-9]*$ ]] && (( ch >= 1 && ch <= ${#clients[@]} )); then
            _3xui_client_profile "${clients[$((ch-1))]}" "$cookie"
            cookie=$(_3xui_auth)
        elif [[ "$ch" == [aAаА] ]]; then
            _3xui_add_client_menu "$cookie"
            cookie=$(_3xui_auth)
        elif [[ "$ch" == [dDдД] ]]; then
            _3xui_disabled_clients_menu "$filter_ib" "$ib_label" "$cookie" "$srv_label" "$srv_ip"
            cookie=$(_3xui_auth)
        fi
    done
}

# ─── Главное меню: выбор сервера и протокола ────────────────

_3xui_clients_menu() {
    _3xui_load_config
    _3xui_write_helpers

    local SERVER_LABEL="Текущий"
    local SERVER_IP="$MY_IP"
    # Устанавливаем subDomain если пустой
    if [ -z "$XUI_SUB_DOMAIN" ] && [ -n "$(certbot certificates 2>/dev/null | grep 'Domains:' | head -1 | awk '{print $2}')" ]; then
        local _auto_domain; _auto_domain=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
        sqlite3 "$XUI_DB" "UPDATE settings SET value='${_auto_domain}' WHERE key='subDomain';" 2>/dev/null
        XUI_SUB_DOMAIN="$_auto_domain"
        echo -e "  ${GREEN}✓ subDomain установлен: ${_auto_domain}${NC}"
    fi
    local SSH_TUNNEL_PID=""

    _3xui_switch_server() {
        [ -n "$SSH_TUNNEL_PID" ] && { kill "$SSH_TUNNEL_PID" 2>/dev/null; SSH_TUNNEL_PID=""; }
        XUI_BASE="https://127.0.0.1:${XUI_PORT}${XUI_PATH}"

        clear
        echo -e "\n${CYAN}━━━ Выберите сервер ━━━${NC}\n"
        echo -e "  ${YELLOW}[0]${NC}  ${MY_IP} (текущий)"
        local ai=1
        local -a alias_entries=()
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            while IFS= read -r aline; do
                [[ -z "$aline" || "$aline" == \#* ]] && continue
                local _aip="${aline%%=*}" _ai="${aline##*=}"
                local _an="${_ai%%|*}"
                [ "$_aip" = "$MY_IP" ] && continue
                echo -e "  ${YELLOW}[$ai]${NC}  ${_an} (${_aip})"
                alias_entries+=("${_aip}|${_an}"); (( ai++ ))
            done < "$ALIASES_FILE"
        fi
        echo ""; read -p "  Выбор: " srv_ch < /dev/tty

        if [[ "$srv_ch" =~ ^[1-9][0-9]*$ ]] && (( srv_ch < ai )); then
            local tgt="${alias_entries[$((srv_ch-1))]}"
            local tip="${tgt%%|*}" tnm="${tgt##*|}"
            echo -ne "  ${CYAN}→ SSH туннель к ${tnm}...${NC} "
            local tport=$(( 17000 + RANDOM % 1000 ))
            ssh -f -N -L "${tport}:127.0.0.1:${XUI_PORT}" \
                -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                "root@${tip}" 2>/dev/null
            if [ $? -eq 0 ]; then
                SSH_TUNNEL_PID=$(pgrep -f "ssh.*${tport}:127.0.0.1:${XUI_PORT}" | head -1)
                XUI_BASE="https://127.0.0.1:${tport}${XUI_PATH}"
                SERVER_LABEL="$tnm"; SERVER_IP="$tip"
                echo -e "${GREEN}✓${NC}"; sleep 1
            else
                echo -e "${RED}✗ SSH недоступен${NC}"; sleep 2
            fi
        else
            SERVER_LABEL="Текущий"; SERVER_IP="$MY_IP"
        fi
    }

    # Пароль
    if ! grep -q "^XUI_PASS=" /etc/govpn/config 2>/dev/null; then
        echo -e "\n  ${YELLOW}Пароль панели 3X-UI не настроен.${NC}"
        _3xui_save_password || return
    fi

    local cookie; cookie=$(_3xui_auth)
    [ -z "$cookie" ] && return 1

    trap '[ -n "$SSH_TUNNEL_PID" ] && kill "$SSH_TUNNEL_PID" 2>/dev/null; trap - RETURN' RETURN

    while true; do
        clear
        echo -e "\n${CYAN}━━━ 3X-UI — выбор протокола ━━━${NC}"
        echo -e "  ${WHITE}Сервер:${NC} ${GREEN}${SERVER_LABEL} (${SERVER_IP})${NC}"

        # Другие серверы в одну строку
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            local _others=""
            while IFS= read -r aline; do
                [[ -z "$aline" || "$aline" == \#* ]] && continue
                local _aip="${aline%%=*}" _ai="${aline##*=}"
                [ "$_aip" = "$SERVER_IP" ] && continue
                _others+="${_ai%%|*}(${_aip})  "
            done < "$ALIASES_FILE"
            [ -n "$_others" ] && echo -e "  ${WHITE}Другие:${NC}  ${CYAN}${_others}${NC}  ${YELLOW}[s]${NC} сменить"
        fi
        echo ""

        # Inbound'ы с числом клиентов
        local -a ibs=()
        local _sf; _sf=$(mktemp)
        _3xui_select_inbounds "$cookie" > "$_sf" 2>/dev/null
        while IFS= read -r line; do
            [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && ibs+=("$line")
        done < "$_sf"; rm -f "$_sf"

        if [ ${#ibs[@]} -eq 0 ]; then
            echo -e "  ${RED}✗ Нет активных протоколов${NC}"
            read -p "  Enter..." < /dev/tty; return
        fi

        echo -e "  ${WHITE}Выберите протокол:${NC}\n"
        local _jf; _jf=$(mktemp)
        _3xui_get_inbounds "$cookie" > "$_jf" 2>/dev/null
        local i=1
        for ib in "${ibs[@]}"; do
            IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
            local cnt
            cnt=$(python3 -c "
import json,sys
with open(sys.argv[1]) as f: d=json.load(f)
for ib in d.get('obj',[]):
    if str(ib['id'])=='$ib_id':
        s=json.loads(ib.get('settings','{}'))
        print(len(s.get('clients',[])))
        break
" "$_jf" 2>/dev/null || echo 0)
            printf "  ${YELLOW}[%d]${NC}  %-22s ${CYAN}%s:%s${NC}  %s клиентов\n" \
                "$i" "$ib_name" "$ib_proto" "$ib_port" "$cnt"
            (( i++ ))
        done
        rm -f "$_jf"

        echo ""
        echo -e "  ${WHITE}── Клиенты ──────────────────────────${NC}"
        echo -e "  ${GREEN}[a]${NC}  Все клиенты"
        echo -e "  ${CYAN}[d]${NC}  Отключённые клиенты"
        echo -e "  ${WHITE}── Routing ───────────────────────────${NC}"
        echo -e "  ${CYAN}[r]${NC}  QR настройки Happ/INCY (roscomvpn)"
        echo -e "  ${WHITE}── Настройки ────────────────────────${NC}"
        echo -e "  ${YELLOW}[i]${NC}  Вкл/выкл протоколов"
        if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
            echo -e "  ${YELLOW}[s]${NC}  Сменить сервер"
        fi
        echo -e "  ${YELLOW}[p]${NC}  Сменить пароль"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""

        local ch; ch=$(read_choice "Выбор: ")
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        case "$ch" in
            [sS]) _3xui_switch_server; cookie=$(_3xui_auth) ;;
            [iI]) _3xui_toggle_inbounds_menu "$cookie"; cookie=$(_3xui_auth) ;;
            [pP]) _3xui_save_password; cookie=$(_3xui_auth) ;;
            [aAаА])
                _3xui_clients_list_menu "" "Все протоколы" "$cookie" "$SERVER_LABEL" "$SERVER_IP"
                cookie=$(_3xui_auth) ;;
            [dDдД])
                _3xui_disabled_clients_menu "" "Все протоколы" "$cookie" "$SERVER_LABEL" "$SERVER_IP"
                cookie=$(_3xui_auth) ;;
            [rR])
                command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
                clear
                echo -e "\n${CYAN}━━━ Настройка Happ / INCY (roscomvpn) ━━━${NC}\n"
                echo -e "  ${WHITE}Шаг 1:${NC} Добавь подписку клиента в Happ (QR из профиля клиента)"
                echo -e "  ${WHITE}Шаг 2:${NC} Отсканируй QR ниже — добавит roscomvpn маршрутизацию:\n"
                echo "https://routing.help" | qrencode -t ANSIUTF8 2>/dev/null
                echo -e "\n  ${CYAN}https://routing.help${NC}\n"
                echo -e "  ${GREEN}✓${NC} РФ/РБ сайты — напрямую   ${GREEN}✓${NC} Заблокированные — через VPN"
                echo -e "  ${GREEN}✓${NC} Реклама — заблокирована   ${GREEN}✓${NC} Автообновление правил"
                echo ""
                read -p "  Enter..." < /dev/tty ;;
            *)
                if [[ "$ch" =~ ^[1-9][0-9]*$ ]] && (( ch >= 1 && ch <= ${#ibs[@]} )); then
                    local ib="${ibs[$((ch-1))]}"
                    IFS='|' read -r ib_id ib_name ib_proto ib_port ib_status <<< "$ib"
                    _3xui_clients_list_menu "$ib_id" "${ib_name} (${ib_proto}:${ib_port})" \
                        "$cookie" "$SERVER_LABEL" "$SERVER_IP"
                    cookie=$(_3xui_auth)
                fi ;;
        esac
    done
}


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

    echo -e "${YELLOW}[2/3]${NC} Регистрация и подключение..."

    # Если уже подключён — пропускаем
    if _3xui_warp_running; then
        echo -e "${GREEN}  ✓ WARP уже подключён${NC}"
    else
        # Регистрируемся (удаляем старую только если есть)
        local has_reg=0
        warp-cli registration show &>/dev/null 2>&1 && has_reg=1
        if [ "$has_reg" -eq 1 ]; then
            echo -e "  ${CYAN}Найдена существующая регистрация — сбрасываю...${NC}"
            # Сбрасываем кастомный эндпоинт перед удалением регистрации
            warp-cli tunnel endpoint reset > /dev/null 2>&1 || true
            warp-cli disconnect > /dev/null 2>&1 || true
            sleep 1
            warp-cli registration delete > /dev/null 2>&1 || true
            sleep 3
        fi

        local reg_out
        reg_out=$(warp-cli --accept-tos registration new 2>&1)
        if echo "$reg_out" | grep -qi "error\|fail"; then
            echo -e "${RED}  ✗ Ошибка регистрации: $(echo "$reg_out" | head -1)${NC}"
            return 1
        fi

        # Настраиваем режим proxy
        # Настраиваем режим proxy
        warp-cli --accept-tos mode proxy > /dev/null 2>&1
        warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" > /dev/null 2>&1

        # Ждём инициализации настроек перед connect
        echo -e "  ${YELLOW}Инициализация...${NC}"
        sleep 6
        warp-cli --accept-tos connect > /dev/null 2>&1

        local connected=0
        for i in $(seq 1 10); do
            sleep 3
            local st; st=$(warp-cli status 2>/dev/null | head -1)
            if echo "$st" | grep -qi "Connected"; then connected=1; break; fi
            echo -e "  ${YELLOW}Ожидание... (${i}/10) — ${st}${NC}"
            (( i % 3 == 0 )) && warp-cli connect > /dev/null 2>&1
        done

        if [ "$connected" -eq 0 ]; then
            echo -e "${RED}  ✗ Не удалось подключить${NC}"
            warp-cli status 2>&1 | head -2 | while read -r l; do echo "    $l"; done
            return 1
        fi
    fi

    local wip; wip=$(_3xui_warp_ip)
    echo -e "${GREEN}  ✓ WARP подключён: ${wip}${NC}"

    echo -e "${YELLOW}[3/3]${NC} Применение outbound в xray (через БД)..."
    _3xui_patch_db && echo -e "${GREEN}  ✓ xrayTemplateConfig обновлён${NC}" || \
        echo -e "${YELLOW}  ⚠ БД не найдена — добавьте outbound вручную${NC}"

    log_action "3XUI WARP SETUP: port=${WARP_SOCKS_PORT}, ip=${wip}"
    return 0
}

_3xui_setup_ru_outbound() {
    # Настройка РФ сервера как outbound для российских доменов
    local db="/etc/x-ui/x-ui.db"
    [ -f "$db" ] || { echo -e "  ${RED}✗ БД не найдена${NC}"; return 1; }

    clear
    echo -e "\n${CYAN}━━━ РФ сервер как outbound ━━━${NC}\n"
    echo -e "  ${WHITE}Это позволяет направить РФ/РБ трафик через РФ IP.${NC}"
    echo -e "  ${WHITE}Сервисы будут видеть российский IP — VPN не детектируется.${NC}\n"

    # Проверяем есть ли уже ru_server outbound
    local has_ru
    has_ru=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null |         python3 -c "
import json,sys
try:
    cfg=json.load(sys.stdin)
    tags=[o.get('tag','') for o in cfg.get('outbounds',[])]
    print('yes' if 'ru_server' in tags else 'no')
except: print('no')
" 2>/dev/null || echo "no")

    if [ "$has_ru" = "yes" ]; then
        echo -e "  ${GREEN}✓ РФ outbound уже настроен${NC}"
        echo ""
        echo -e "  ${YELLOW}[d]${NC}  Удалить РФ outbound"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        read -r ch < /dev/tty
        [ "$ch" = "d" ] || [ "$ch" = "D" ] && _3xui_remove_ru_outbound
        return
    fi

    echo -e "  ${WHITE}Введите VLESS ссылку РФ сервера:${NC}"
    echo -e "  ${CYAN}vless://uuid@host:port?...${NC}"
    echo -e "  ${WHITE}(или Enter для ручного ввода SOCKS5)${NC}\n"
    read -r ru_vless < /dev/tty

    local ru_host="" ru_port="1080" ru_uuid="" ru_mode=""

    if [[ "$ru_vless" == vless://* ]]; then
        ru_uuid=$(echo "$ru_vless" | python3 -c "import sys,urllib.parse; u=sys.stdin.read().strip()[8:]; print(u.split('@')[0])")
        ru_host=$(echo "$ru_vless" | python3 -c "import sys; u=sys.stdin.read().strip()[8:]; h=u.split('@')[1].split('?')[0]; print(h.rsplit(':',1)[0])")
        ru_port=$(echo "$ru_vless" | python3 -c "import sys; u=sys.stdin.read().strip()[8:]; h=u.split('@')[1].split('?')[0]; print(h.rsplit(':',1)[1])")
        echo -e "  ${GREEN}✓${NC} Host: ${ru_host}  Port: ${ru_port}"
    else
        echo -ne "  IP или домен РФ сервера: "
        read -r ru_host < /dev/tty
        [ -z "$ru_host" ] && return
        echo -ne "  Порт (Enter = 1080): "
        read -r ru_port_in < /dev/tty
        [ -n "$ru_port_in" ] && ru_port="$ru_port_in"
        echo -ne "  Пароль/UUID (Enter = пропустить): "
        read -r ru_uuid < /dev/tty
        ru_vless=""
    fi

    echo ""
    echo -e "  ${YELLOW}Направить через РФ сервер:${NC}"
    echo -e "  [1] РФ/РБ сайты (category-ru) + свой список direct"
    echo -e "  [2] Только свой список direct"
    echo -e "  [3] Без правил (только outbound)"
    read -r ru_mode < /dev/tty

    [ $? -eq 0 ] && systemctl restart x-ui > /dev/null 2>&1 && sleep 2 &&         echo -e "  ${GREEN}✓ Настроено, xray перезапущен${NC}" ||         echo -e "  ${RED}✗ Ошибка${NC}"
    read -p "  Enter..." < /dev/tty
}

_3xui_remove_ru_outbound() {
    local db="/etc/x-ui/x-ui.db"
    python3 - << PYEOF3
import json, subprocess as sp, sys
db = '$db'
r = sp.run(['sqlite3', db, "SELECT value FROM settings WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
cfg = json.loads(r.stdout.strip())
cfg['outbounds'] = [o for o in cfg.get('outbounds',[]) if o.get('tag') != 'ru_server']
rules = cfg.get('routing',{}).get('rules',[])
cfg['routing']['rules'] = [r for r in rules if r.get('outboundTag') != 'ru_server']
new_tmpl = json.dumps(cfg, ensure_ascii=False, indent=2).replace("'","''")
r2 = sp.run(['sqlite3', db, f"UPDATE settings SET value='{new_tmpl}' WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
print("  OK: ru_server удалён" if r2.returncode == 0 else f"  ERR: {r2.stderr}")
PYEOF3
    systemctl restart x-ui > /dev/null 2>&1
    echo -e "  ${GREEN}✓ РФ outbound удалён${NC}"
    read -p "  Enter..." < /dev/tty
}

_3xui_add_geo_routing() {
    local db="/etc/x-ui/x-ui.db"
    command -v sqlite3 &>/dev/null || apt-get install -y sqlite3 > /dev/null 2>&1
    [ -f "$db" ] || { echo -e "  ${RED}✗ БД не найдена: ${db}${NC}"; return 1; }

    # Ищем geosite.dat
    local xray_dir="/usr/local/x-ui/bin"
    [ ! -f "${xray_dir}/geosite.dat" ] && \
        xray_dir=$(find /usr/local -name "geosite.dat" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "/usr/local/x-ui/bin")
    echo -e "  ${WHITE}Путь: ${xray_dir}${NC}"

    # Проверка размера - roscomvpn > 2MB, стандартный < 500KB
    local fsize=0
    [ -f "${xray_dir}/geosite.dat" ] && fsize=$(stat -c%s "${xray_dir}/geosite.dat" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 2000000 ]; then
        echo -e "  ${RED}✗ geosite.dat не является roscomvpn файлом (${fsize}B < 2MB)${NC}"
        echo -e "  ${YELLOW}Сначала обновите файлы — пункт [1]${NC}"
        echo -e "  ${WHITE}Правила с geosite:category-ru-blocked НЕ добавлены${NC}"
        return 1
    fi

    python3 - << 'PYEOF'
import json, subprocess as sp, sys, os

db = '/etc/x-ui/x-ui.db'
xray_dir = '/usr/local/x-ui/bin'
for d in ['/usr/local/x-ui/bin']:
    if os.path.exists(f'{d}/geosite.dat'):
        xray_dir = d; break

r = sp.run(['sqlite3', db, "SELECT value FROM settings WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
tmpl_str = r.stdout.strip()
if not tmpl_str:
    print("  ERR: xrayTemplateConfig не найден")
    sys.exit(1)

cfg = json.loads(tmpl_str)
routing = cfg.setdefault('routing', {})
rules = routing.setdefault('rules', [])

# Определяем реальный outbound для proxy
outbounds = cfg.get('outbounds', [])
proxy_tag = 'direct'
for o in outbounds:
    if o.get('tag','').upper() in ['WARP']:
        proxy_tag = o.get('tag')
        break
    if o.get('tag','').lower() in ['proxy', 'socks']:
        proxy_tag = o.get('tag')
print(f"  Outbound: {proxy_tag}")

# Roscomvpn правила
geosite_size = os.path.getsize(f'{xray_dir}/geosite.dat') if os.path.exists(f'{xray_dir}/geosite.dat') else 0
has_ru = geosite_size > 2_000_000

NEW_RULES = []
if has_ru:
    NEW_RULES.append({
        "type": "field",
        "domain": ["geosite:category-ru"],
        "outboundTag": "direct",
        "_comment": "roscomvpn: РФ/РБ напрямую"
    })
    # Проверяем поддержку category-ru-blocked через xray binary
    import os, subprocess, tempfile
    _geosite_path = f'{xray_dir}/geosite.dat'
    geo_size = os.path.getsize(_geosite_path) if os.path.exists(_geosite_path) else 0

    # Ищем xray binary
    xray_bin = None
    for candidate in [f'{xray_dir}/xray', '/usr/local/x-ui/bin/xray', '/usr/bin/xray']:
        if os.path.isfile(candidate):
            xray_bin = candidate
            break

    has_blocked = False
    if geo_size > 10_000_000 and xray_bin:
        # Тест-конфиг с category-ru-blocked
        test_cfg = {
            "routing": {"rules": [{"type":"field","domain":["geosite:category-ru-blocked"],"outboundTag":"direct"}]},
            "outbounds": [{"tag":"direct","protocol":"freedom"}]
        }
        with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
            import json as _json
            _json.dump(test_cfg, f)
            test_file = f.name
        try:
            r = subprocess.run([xray_bin, '-test', '-c', test_file],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, 'XRAY_LOCATION_ASSET': xray_dir})
            has_blocked = r.returncode == 0
            if not has_blocked:
                print(f"  ℹ category-ru-blocked недоступен в этой версии xray")
        except Exception as e:
            has_blocked = False
        finally:
            os.unlink(test_file)
    elif geo_size <= 10_000_000:
        print(f"  ℹ geosite.dat ({geo_size//1024}KB) — обновите до runetfreedom")

    if has_blocked:
        NEW_RULES.append({
            "type": "field",
            "domain": ["geosite:category-ru-blocked"],
            "outboundTag": proxy_tag,
            "_comment": f"roscomvpn: заблокированные РКН через {proxy_tag}"
        })
    else:
        # Удаляем старое правило если оно есть
        rules = [r for r in rules if "category-ru-blocked" not in str(r.get("domain", []))]

# Свой список доменов
custom_file = "/etc/govpn/custom_domains.txt"
if os.path.exists(custom_file):
    custom_proxy, custom_direct = [], []
    with open(custom_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            parts = line.split()
            domain = parts[0]
            direction = parts[1].lower() if len(parts) > 1 else "direct"
            (custom_proxy if direction == "proxy" else custom_direct).append(domain)
    if custom_direct:
        NEW_RULES.insert(0, {"type":"field","domain":custom_direct,"outboundTag":"direct","_comment":"govpn: custom direct"})
    if custom_proxy:
        NEW_RULES.append({"type":"field","domain":custom_proxy,"outboundTag":proxy_tag,"_comment":f"govpn: custom {proxy_tag}"})

if not NEW_RULES:
    print("  WARN: нечего добавлять")
    sys.exit(0)

# Удаляем старые govpn/roscomvpn правила
rules = [r for r in rules if not any(k in r.get('_comment','') for k in ['roscomvpn','govpn'])]

# Вставляем в начало (до системных правил api/blocked)
insert_pos = 0
for i, rule in enumerate(rules):
    if rule.get('outboundTag') in ('api',) and not rule.get('domain'):
        insert_pos = i; break
    insert_pos = i + 1

for i, rule in enumerate(NEW_RULES):
    rules.insert(insert_pos + i, rule)

routing['rules'] = rules
cfg['routing'] = routing
new_tmpl = json.dumps(cfg, ensure_ascii=False, indent=2).replace("'", "''")
r2 = sp.run(['sqlite3', db, f"UPDATE settings SET value='{new_tmpl}' WHERE key='xrayTemplateConfig';"],
    capture_output=True, text=True)
if r2.returncode == 0:
    print(f"  OK: добавлено {len(NEW_RULES)} правил")
else:
    print(f"  ERR: {r2.stderr}"); sys.exit(1)
PYEOF
    local ret=$?
    if [ "$ret" -eq 0 ]; then
        systemctl restart x-ui > /dev/null 2>&1; sleep 2
        echo -e "  ${GREEN}✓ Правила добавлены, xray перезапущен${NC}"
        echo -e "  ${CYAN}Проверь: 3X-UI → Настройки → Xray → Routing${NC}"
    fi
    return $ret
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
    raw=$(docker exec "$AWG_CONTAINER" sh -c         "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" 2>/dev/null)

    local result
    result=$(echo "$raw" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for c in d:
        ip = c.get('userData', {}).get('allowedIps', '')
        if ip and ip[0].isdigit():
            print(ip if '/' in ip else ip + '/32')
except Exception:
    pass
" 2>/dev/null)

    # Fallback — конфиг awg
    if [ -z "$result" ]; then
        local conf; conf=$(_awg_conf)
        result=$(docker exec "$AWG_CONTAINER" sh -c             "grep 'AllowedIPs' '$conf' 2>/dev/null" 2>/dev/null |             grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/32')
    fi

    echo "$result"
}

_awg_client_name() {
    local ip="${1%/32}"
    local raw
    raw=$(docker exec "$AWG_CONTAINER" sh -c         "cat /opt/amnezia/awg/clientsTable 2>/dev/null || true" 2>/dev/null)
    echo "$raw" | python3 -c "
import json, sys
target = '$ip'
try:
    d = json.load(sys.stdin)
    for c in d:
        ud = c.get('userData', {})
        if ud.get('allowedIps', '').split('/')[0] == target:
            print(ud.get('clientName', ''))
            break
except Exception:
    pass
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

# Эндпоинты WARP
# Примечание: конкретные IP не работают с AmneziaWG — только авто DNS
declare -A WARP_REGIONS=(
    ["Авто (ближайший)"]="engage.cloudflareclient.com:2408"
)
WARP_REGION_ORDER=("Авто (ближайший)")

# ── Cloudflare IP Scanner ────────────────────────────────────
_cf_scanner_install() {
    local bin="/usr/local/bin/cfscanner"
    [ -x "$bin" ] && return 0

    echo -e "  ${CYAN}Скачиваю Cloudflare Scanner...${NC}"
    local arch; arch=$(uname -m)
    local cf_arch="amd64"
    [ "$arch" = "aarch64" ] && cf_arch="arm64"

    # Пробуем бинарник от bia-pain-bache
    local url="https://github.com/bia-pain-bache/Cloudflare-Clean-IP-Scanner/releases/latest/download/cfscanner-linux-${cf_arch}"
    if curl -fsSL --connect-timeout 10 "$url" -o "$bin" 2>/dev/null; then
        chmod +x "$bin"
        "$bin" --help &>/dev/null && return 0
    fi

    # Fallback: оригинальный CloudflareScanner
    local tmp_dir; tmp_dir=$(mktemp -d)
    url="https://github.com/Ptechgithub/CloudflareScanner/releases/latest/download/CloudflareScanner_linux_${cf_arch}.zip"
    if curl -fsSL --connect-timeout 10 "$url" -o "${tmp_dir}/cf.zip" 2>/dev/null; then
        unzip -q "${tmp_dir}/cf.zip" -d "$tmp_dir" 2>/dev/null
        local found; found=$(find "$tmp_dir" -name "CloudflareScanner" -type f | head -1)
        if [ -n "$found" ]; then
            mv "$found" "$bin" && chmod +x "$bin"
            rm -rf "$tmp_dir"
            return 0
        fi
    fi
    rm -rf "$tmp_dir"
    return 1
}

_cf_scanner_run() {
    local bin="/usr/local/bin/cfscanner"
    local result_file="/tmp/cf_result.csv"
    rm -f "$result_file"

    echo -e "  ${CYAN}Сканирую IP диапазоны Cloudflare...${NC}"
    echo -e "  ${WHITE}~100 IP, занимает 30-60 секунд${NC}\n"

    timeout 90 "$bin" \
        -n 100 -t 4 \
        -o "$result_file" \
        -tl 300 \
        2>/dev/null

    if [ ! -f "$result_file" ] || [ ! -s "$result_file" ]; then
        echo -e "  ${RED}✗ Нет результатов${NC}"
        return 1
    fi

    echo -e "\n  ${GREEN}Топ результаты:${NC}\n"
    printf "  ${WHITE}%-18s %-10s %-8s\n${NC}" "IP" "Задержка" "Потери"
    head -6 "$result_file" | tail -5 | while IFS=, read -r ip latency loss _rest; do
        printf "  ${GREEN}%-18s${NC} %-10s %-8s\n" "$ip" "${latency}ms" "${loss}%"
    done

    # Возвращаем лучший IP последней строкой
    head -2 "$result_file" | tail -1 | cut -d',' -f1
}

_awg_ping_endpoint() {
    local endpoint="$1"
    local host="${endpoint%%:*}"
    # Убираем IPv6 скобки
    host="${host//[/}"; host="${host//]/}"
    # ICMP ping — реальная RTT
    local ms
    ms=$(ping -c 3 -W 2 -q "$host" 2>/dev/null | \
        awk -F'/' '/^rtt|^round-trip/{printf "%d", $5; exit}')
    if [ -n "$ms" ] && [[ "$ms" =~ ^[0-9]+$ ]] && [ "$ms" -gt 0 ] 2>/dev/null; then
        echo "$ms"; return
    fi
    # Fallback TCP 443
    ms=$(python3 -c "
import socket, time
try:
    t = time.time()
    socket.create_connection(('$host', 443), timeout=2).close()
    print(int((time.time()-t)*1000))
except: print(9999)
" 2>/dev/null || echo 9999)
    echo "$ms"
}




_awg_select_region() {
    # Показываем регионы с пингом и даём выбрать
    clear
    echo -e "\n${CYAN}━━━ Выбор региона WARP ━━━${NC}\n"
    echo -e "  ${YELLOW}Тестирую задержку до эндпоинтов...${NC}\n"

    local -a pings=()
    local i=1
    for region in "${WARP_REGION_ORDER[@]}"; do
        local endpoint="${WARP_REGIONS[$region]}"
        local ms
        if [ "$region" = "Авто" ]; then
            ms=0
        else
            ms=$(_awg_ping_endpoint "$endpoint")
        fi
        pings+=("$ms")
        local ping_str ms_color
        if [ "$ms" -eq 9999 ]; then
            ping_str="недоступен"; ms_color="${RED}"
        elif [ "$ms" -eq 0 ]; then
            ping_str="авто"; ms_color="${CYAN}"
        elif [ "$ms" -lt 80 ]; then
            ping_str="${ms}ms"; ms_color="${GREEN}"
        elif [ "$ms" -lt 150 ]; then
            ping_str="${ms}ms"; ms_color="${YELLOW}"
        else
            ping_str="${ms}ms"; ms_color="${RED}"
        fi
        printf "  ${YELLOW}[%-2d]${NC}  %-28s  %b%s${NC}
"             "$i" "$region" "$ms_color" "$ping_str"
        (( i++ ))
    done

    echo ""
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор [1]: " region_ch < /dev/tty
    [ -z "$region_ch" ] && region_ch=1
    [ "$region_ch" = "0" ] && return 1

    if [[ "$region_ch" =~ ^[0-9]+$ ]] && \
       (( region_ch >= 1 && region_ch <= ${#WARP_REGION_ORDER[@]} )); then
        local selected_region="${WARP_REGION_ORDER[$((region_ch-1))]}"
        local selected_endpoint="${WARP_REGIONS[$selected_region]}"
        echo -e "\n  ${GREEN}✓ Выбран регион: ${selected_region}${NC}"
        echo -e "  ${WHITE}Эндпоинт: ${CYAN}${selected_endpoint}${NC}"
        # Экспортируем выбор
        WARP_SELECTED_REGION="$selected_region"
        WARP_SELECTED_ENDPOINT="$selected_endpoint"
        return 0
    fi
    return 1
}

_awg_change_region() {
    # Смена региона для уже установленного WARP
    clear
    echo -e "\n${CYAN}━━━ Смена региона WARP ━━━${NC}\n"

    if ! _awg_warp_running; then
        echo -e "  ${RED}✗ WARP не запущен${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    WARP_SELECTED_REGION=""
    WARP_SELECTED_ENDPOINT=""
    _awg_select_region || return

    local endpoint="$WARP_SELECTED_ENDPOINT"
    local host="${endpoint%%:*}"
    local port="${endpoint##*:}"

    echo -e "\n  ${YELLOW}Меняю регион...${NC}"

    # Обновляем Endpoint в warp.conf
    docker exec "$AWG_CONTAINER" sh -c "
        if [ -f '${AWG_WARP_CONF}' ]; then
            sed -i 's|^Endpoint = .*|Endpoint = ${host}:${port}|g' '${AWG_WARP_CONF}'
            echo 'ok'
        else
            echo 'no_conf'
        fi
    " 2>/dev/null | grep -q 'ok' || {
        echo -e "  ${RED}✗ Файл конфига не найден${NC}"
        read -p "  Enter..." < /dev/tty; return
    }

    # Перезапускаем туннель
    echo -e "  ${CYAN}↻ Перезапускаю туннель...${NC}"
    docker exec "$AWG_CONTAINER" sh -c "
        wg-quick down '${AWG_WARP_CONF}' 2>/dev/null || true
        sleep 1
        wg-quick up '${AWG_WARP_CONF}' 2>/dev/null
    " 2>/dev/null
    sleep 3

    # Восстанавливаем маршрут в таблице 100 (он исчезает при перезапуске туннеля)
    docker exec "$AWG_CONTAINER" sh -c "
        ip route add default dev warp table 100 2>/dev/null ||         ip route replace default dev warp table 100 2>/dev/null || true
    " 2>/dev/null

    # Проверяем новый IP
    local new_ip; new_ip=$(_awg_warp_ip)
    if [ -n "$new_ip" ]; then
        echo -e "  ${GREEN}✓ Регион изменён!${NC}"
        echo -e "  ${WHITE}Новый WARP IP: ${GREEN}${new_ip}${NC}"
        log_action "AWG WARP REGION: ${WARP_SELECTED_REGION} → ${new_ip}"
    else
        echo -e "  ${YELLOW}⚠ Туннель поднялся но IP не определён${NC}"
    fi
    read -p "  Enter..." < /dev/tty
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

    # Применяем выбранный регион если был выбран
    if [ -n "${WARP_SELECTED_ENDPOINT:-}" ] && [ "${WARP_SELECTED_REGION:-}" != "Авто" ]; then
        local host="${WARP_SELECTED_ENDPOINT%%:*}"
        local port="${WARP_SELECTED_ENDPOINT##*:}"
        docker exec "$AWG_CONTAINER" sh -c             "sed -i 's|^Endpoint = .*|Endpoint = ${host}:${port}|g' '${AWG_WARP_CONF}'" 2>/dev/null
        echo -e "  ${GREEN}✓ Эндпоинт: ${WARP_SELECTED_ENDPOINT}${NC}"
    fi
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

    # Полная очистка старых правил
    docker exec "$AWG_CONTAINER" sh -c "
        ip rule del fwmark 100 table 100 2>/dev/null || true
        ip rule del fwmark 0x64 table 100 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i ${iface} -j MARK --set-mark 100 2>/dev/null || true
        ip rule list | grep 'lookup 100' | awk '{print \$1}' | sed 's/://' | sort -rn | \
            while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done
        iptables -t nat -S POSTROUTING 2>/dev/null | grep ' warp ' | \
            sed 's/^-A /-D /' | while read -r r; do iptables -t nat \$r 2>/dev/null || true; done
        ip route flush table 100 2>/dev/null || true
    " > /dev/null 2>&1

    [ "${#selected[@]}" -eq 0 ] && return 0

    # Проверяем warp интерфейс внутри контейнера
    if ! docker exec "$AWG_CONTAINER" sh -c "ip link show warp > /dev/null 2>&1"; then
        echo -e "  ${RED}✗ warp интерфейс не найден в контейнере${NC}"
        return 1
    fi

    # Получаем всех клиентов чтобы найти исключённых
    local -a all_ips=()
    while IFS= read -r ip; do [ -n "$ip" ] && all_ips+=("$ip"); done <<< "$(_awg_all_clients)"

    # Убеждаемся что warp интерфейс поднят
    if ! docker exec "$AWG_CONTAINER" sh -c "ip link show warp > /dev/null 2>&1" 2>/dev/null; then
        docker exec "$AWG_CONTAINER" sh -c             "wg-quick up '${AWG_WARP_CONF}' 2>/dev/null || true" 2>/dev/null
        sleep 2
    fi

    # fwmark маршрутизация
    docker exec "$AWG_CONTAINER" sh -c "
        ip route add default dev warp table 100 2>/dev/null ||             ip route replace default dev warp table 100 2>/dev/null || true
        ip rule add fwmark 100 table 100 priority 100 2>/dev/null || true
        iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null ||             iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE 2>/dev/null || true
        iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||         iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN             -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    " 2>/dev/null

    # Сначала сбрасываем цепочку AWG_WARP
    docker exec "$AWG_CONTAINER" sh -c "
        iptables -t mangle -F AWG_WARP 2>/dev/null || true
        iptables -t mangle -N AWG_WARP 2>/dev/null || true
        iptables -t mangle -D PREROUTING -i ${iface} -j AWG_WARP 2>/dev/null || true
        iptables -t mangle -I PREROUTING 1 -i ${iface} -j AWG_WARP
    " 2>/dev/null

    # Добавляем RETURN для исключённых клиентов (не в списке selected)
    for ip in "${all_ips[@]}"; do
        local in_sel=0
        for s in "${selected[@]}"; do [ "$s" = "$ip" ] && in_sel=1 && break; done
        if [ "$in_sel" -eq 0 ]; then
            local bare="${ip%/32}"
            docker exec "$AWG_CONTAINER" sh -c                 "iptables -t mangle -A AWG_WARP -s ${bare} -j RETURN" 2>/dev/null
        fi
    done

    # Для включённых — ставим MARK
    docker exec "$AWG_CONTAINER" sh -c         "iptables -t mangle -A AWG_WARP -j MARK --set-mark 100" 2>/dev/null

    echo -e "  ${GREEN}✓ WARP маршрутизация для ${#selected[@]} из ${#all_ips[@]} клиентов${NC}"
}


_awg_setup_redsocks() {
    local warp_socks="$1"; shift
    local -a client_ips=("$@")
    local warp_host="${warp_socks%%:*}"
    local warp_port="${warp_socks##*:}"
    local iface; iface=$(_awg_iface)
    local REDSOCKS_PORT=12345

    # Устанавливаем redsocks если нет
    if ! command -v redsocks &>/dev/null; then
        echo -e "  ${CYAN}Устанавливаю redsocks...${NC}"
        apt-get install -y redsocks > /dev/null 2>&1 || {
            echo -e "  ${YELLOW}⚠ redsocks не установлен — WARP для клиентов недоступен${NC}"
            return 1
        }
    fi

    # Конфиг redsocks
    cat > /etc/redsocks.conf << REDSOCKS_EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = on;
    redirector = iptables;
}
redsocks {
    local_ip = 0.0.0.0;
    local_port = ${REDSOCKS_PORT};
    ip = ${warp_host};
    port = ${warp_port};
    type = socks5;
}
REDSOCKS_EOF

    systemctl restart redsocks > /dev/null 2>&1 || redsocks -c /etc/redsocks.conf &

    # iptables правила на ХОСТЕ — перехватываем трафик от AWG клиентов
    iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS
    # Не проксируем локальные адреса
    iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A REDSOCKS -d 162.159.192.0/24 -j RETURN  # Cloudflare WARP
    # Перенаправляем TCP трафик клиентов через redsocks
    for ip in "${client_ips[@]}"; do
        local bare="${ip%/32}"
        iptables -t nat -A REDSOCKS -s "${bare}" -p tcp -j REDIRECT --to-port ${REDSOCKS_PORT}
    done
    iptables -t nat -C PREROUTING -j REDSOCKS 2>/dev/null ||         iptables -t nat -I PREROUTING 1 -j REDSOCKS

    echo -e "  ${GREEN}✓ WARP через redsocks (socks5://${warp_socks})${NC}"
    log_action "AWG: WARP через redsocks настроен для ${#client_ips[@]} клиентов"
}

_awg_patch_start_sh() {
    local start_sh="/opt/amnezia/start.sh"
    local -a selected=("$@")

    # Стандартная основа start.sh (всегда надёжная)
    local base_sh
    base_sh=$(cat << 'BASESH'
#!/bin/bash
echo "Container startup"

awg-quick down /opt/amnezia/awg/awg0.conf
if [ -f /opt/amnezia/awg/awg0.conf ]; then
    awg-quick up /opt/amnezia/awg/awg0.conf
fi

iptables -A INPUT -i awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -j ACCEPT
iptables -A OUTPUT -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o eth0 -s 10.8.1.0/24 -j ACCEPT
iptables -A FORWARD -i awg0 -o eth1 -s 10.8.1.0/24 -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.8.1.0/24 -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.8.1.0/24 -o eth1 -j MASQUERADE
BASESH
)

    # Пробуем читать из контейнера (убираем GOVPN блоки и tail)
    local orig
    orig=$(docker exec "$AWG_CONTAINER" sh -c         "sed '/# --- GOVPN WARP BEGIN ---/,/# --- GOVPN WARP END ---/d; /# --- WARP-MANAGER BEGIN ---/,/# --- WARP-MANAGER END ---/d; /# --- WARP BEGIN ---/,/# --- WARP END ---/d' '${start_sh}' 2>/dev/null" 2>/dev/null)
    orig=$(echo "$orig" | grep -v '^tail -f /dev/null')

    # Если orig пустой или слишком короткий — используем стандартную базу
    local orig_lines; orig_lines=$(echo "$orig" | wc -l)
    if [ "$orig_lines" -lt 5 ]; then
        echo -e "  ${YELLOW}⚠ start.sh в контейнере пустой — использую стандартный шаблон${NC}"
        orig="$base_sh"
    fi

    local iface; iface=$(_awg_iface)

    # Строим WARP блок с fwmark маршрутизацией
    local warp_block="# --- GOVPN WARP BEGIN ---"$'\n'
    warp_block+="if [ -f '${AWG_WARP_CONF}' ]; then"$'\n'
    warp_block+="  wg-quick up '${AWG_WARP_CONF}' 2>/dev/null || true"$'\n'
    warp_block+="  sleep 2"$'\n'
    if [ "${#selected[@]}" -gt 0 ]; then
        # Получаем всех клиентов для определения исключённых
        local -a all_for_patch=()
        while IFS= read -r ip; do [ -n "$ip" ] && all_for_patch+=("$ip"); done <<< "$(_awg_all_clients)"

        warp_block+="  ip route add default dev warp table 100 2>/dev/null || ip route replace default dev warp table 100 2>/dev/null || true"$'\n'
        warp_block+="  sleep 1"$'\n'
        warp_block+="  ip rule add fwmark 100 table 100 priority 100 2>/dev/null || true"$'\n'
        warp_block+="  iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -o warp -j MASQUERADE 2>/dev/null || true"$'\n'
        warp_block+="  iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true"$'\n'
        # Создаём цепочку AWG_WARP с исключениями
        warp_block+="  iptables -t mangle -F AWG_WARP 2>/dev/null || true"$'\n'
        warp_block+="  iptables -t mangle -N AWG_WARP 2>/dev/null || true"$'\n'
        warp_block+="  iptables -t mangle -D PREROUTING -i ${iface} -j AWG_WARP 2>/dev/null || true"$'\n'
        warp_block+="  iptables -t mangle -I PREROUTING 1 -i ${iface} -j AWG_WARP"$'\n'
        # RETURN для исключённых
        for ip in "${all_for_patch[@]}"; do
            local in_sel=0
            for s in "${selected[@]}"; do [ "$s" = "$ip" ] && in_sel=1 && break; done
            if [ "$in_sel" -eq 0 ]; then
                local bare="${ip%/32}"
                warp_block+="  iptables -t mangle -A AWG_WARP -s ${bare} -j RETURN"$'\n'
            fi
        done
        warp_block+="  iptables -t mangle -A AWG_WARP -j MARK --set-mark 100"$'\n'
    fi
    warp_block+="fi"$'\n'
    warp_block+="# --- GOVPN WARP END ---"

    # Записываем новый start.sh через docker cp (надёжнее чем echo внутри контейнера)
    local new_content="${orig}"$'\n\n'"${warp_block}"$'\n\n'"tail -f /dev/null"$'\n'
    local tmp_file; tmp_file=$(mktemp)
    echo "$new_content" > "$tmp_file"

    # Копируем во все overlay слои
    for f in /var/lib/docker/overlay2/*/diff/opt/amnezia/start.sh; do
        cp "$tmp_file" "$f" && chmod +x "$f"
    done
    rm -f "$tmp_file"

    # Сохраняем бэкап хорошего start.sh
    cp "$tmp_file" /etc/govpn/start.sh.backup 2>/dev/null || true

    echo -e "  ${GREEN}✓ start.sh обновлён (${#selected[@]} клиентов через WARP)${NC}"
}


_awg_install_warp() {
    echo -e "\n${CYAN}[Amnezia] Установка WARP в контейнер ${AWG_CONTAINER}...${NC}\n"

    # Регион выбирается автоматически Cloudflare
    WARP_SELECTED_REGION="Авто"
    WARP_SELECTED_ENDPOINT="engage.cloudflareclient.com:2408"

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

# Cloudflare WARP эндпоинты по регионам (Colo коды)
# Диапазоны: 162.159.192.0/22 и 188.114.96.0/22
# Cloudflare WARP эндпоинты по регионам
# IPv4: прямые датацентры Cloudflare
# NAT64: меняет страну определения через IPv6 туннель
# Источник NAT64: github.com/bia-pain-bache/BPB-Worker-Panel/blob/main/docs/NAT64Prefixes.md
declare -A WARP_COLO_ENDPOINTS=(
    ["FRA — Франкфурт (DE)  [IPv4]"]="162.159.198.2:2408"
    ["AMS — Амстердам (NL)  [IPv4]"]="162.159.198.1:2408"
    ["LHR — Лондон (UK)     [IPv4]"]="188.114.96.1:2408"
    ["CDG — Париж (FR)      [IPv4]"]="188.114.97.1:2408"
    ["LAX — США West        [IPv4]"]="162.159.193.1:2408"
    ["EWR — США East        [IPv4]"]="162.159.195.1:2408"
    ["SIN — Сингапур        [IPv4]"]="162.159.194.1:2408"
    ["NRT — Токио (JP)      [IPv4]"]="162.159.196.1:2408"
    ["NL — Нидерланды       [NAT64]"]="[2a02:898:146:64::a29f:c702]:2408"
    ["US West               [NAT64]"]="[2602:fc59:b0:64::a29f:c702]:2408"
    ["US East               [NAT64]"]="[2602:fc59:11:64::a29f:c702]:2408"
)
WARP_COLO_ORDER=(
    "FRA — Франкфурт (DE)  [IPv4]"
    "AMS — Амстердам (NL)  [IPv4]"
    "LHR — Лондон (UK)     [IPv4]"
    "CDG — Париж (FR)      [IPv4]"
    "LAX — США West        [IPv4]"
    "EWR — США East        [IPv4]"
    "SIN — Сингапур        [IPv4]"
    "NRT — Токио (JP)      [IPv4]"
    "NL — Нидерланды       [NAT64]"
    "US West               [NAT64]"
    "US East               [NAT64]"
)

_3xui_warp_change_region() {
    clear
    echo -e "\n${CYAN}━━━ Смена региона WARP ━━━${NC}\n"

    if ! command -v warp-cli &>/dev/null; then
        echo -e "  ${RED}✗ warp-cli не установлен${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    # Показываем текущий датацентр
    local cur_stats; cur_stats=$(warp-cli tunnel stats 2>/dev/null)
    local cur_colo; cur_colo=$(echo "$cur_stats" | grep 'Colo:' | awk '{print $2}')
    local cur_ep; cur_ep=$(echo "$cur_stats" | grep 'Endpoints:' | awk '{print $2}')
    local cur_ip; cur_ip=$(_3xui_warp_ip)
    echo -e "  ${WHITE}Текущий датацентр:${NC} ${GREEN}${cur_colo:-?}${NC}  IP: ${GREEN}${cur_ip:-?}${NC}"
    echo -e "  ${WHITE}Эндпоинт:${NC} ${CYAN}${cur_ep:-?}${NC}\n"

    # Тестируем задержку до каждого эндпоинта
    local has_ipv6=0
    ip -6 addr show 2>/dev/null | grep -q "scope global" && has_ipv6=1
    [ "$has_ipv6" -eq 0 ] &&         echo -e "  ${YELLOW}⚠ IPv6 недоступен — NAT64 опции скрыты${NC}\n" ||         echo -e "  ${GREEN}✓ IPv6 доступен — NAT64 опции активны${NC}\n"
    echo -e "  ${YELLOW}Тестирую задержку...${NC}\n"

    local i=1
    for colo in "${WARP_COLO_ORDER[@]}"; do
        # Скрываем NAT64 если нет IPv6
        if [[ "$colo" == *"[NAT64]"* ]]; then
            [ "$has_ipv6" -eq 0 ] && continue
            # NAT64 — не пингуем IPv6, просто показываем
            printf "  ${CYAN}[%-2d]${NC}  %-32s  %b(NAT64 — через IPv6)${NC}\n"                 "$i" "$colo" "${CYAN}"
            (( i++ ))
            continue
        fi
        local ep="${WARP_COLO_ENDPOINTS[$colo]}"
        local host="${ep%%:*}"
        local ms; ms=$(_awg_ping_endpoint "$ep")
        [ -z "$ms" ] && ms=9999
        local ms_color
        if [ "$ms" -lt 50 ]; then ms_color="${GREEN}"
        elif [ "$ms" -lt 100 ]; then ms_color="${YELLOW}"
        else ms_color="${RED}"; fi
        local cur_mark=""
        [[ "$cur_ep" == "$host"* ]] && cur_mark=" ${CYAN}← текущий${NC}"
        printf "  ${YELLOW}[%-2d]${NC}  %-32s  %b%sms${NC}%b\n"             "$i" "$colo" "$ms_color" "$ms" "$cur_mark"
        (( i++ ))
    done

    echo ""
    echo -e "  ${YELLOW}[$i]${NC}  Авто (сбросить)"
    echo -e "  ${CYAN}[s]${NC}  Найти лучший IP (Cloudflare Scanner)"
    # NAT64 только если есть глобальный IPv6
    local has_ipv6=0
    ip -6 addr show 2>/dev/null | grep -q "scope global" && has_ipv6=1
    if [ "$has_ipv6" -eq 1 ]; then
        echo -e "  ${CYAN}[n]${NC}  Конвертировать IPv4 → NAT64 (смена страны)"
        echo -e "  ${WHITE}[NAT64] меняет страну определения, [IPv4] меняет датацентр${NC}"
    else
        echo -e "  ${YELLOW}⚠ NAT64 недоступен (нет IPv6 на сервере)${NC}"
    fi
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор: " reg_ch < /dev/tty
    [ "$reg_ch" = "0" ] || [ -z "$reg_ch" ] && return

    local chosen_ep="" chosen_colo=""

    if [[ "$reg_ch" =~ ^[sS]$ ]]; then
        if _cf_scanner_install; then
            local best_ip; best_ip=$(_cf_scanner_run)
            best_ip=$(echo "$best_ip" | tail -1 | tr -d '[:space:]')
            if [[ "$best_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                chosen_ep="${best_ip}:2408"
                chosen_colo="Scanner: ${best_ip}"
                echo -e "\n  ${GREEN}✓ Лучший IP: ${best_ip}${NC}"
                echo -ne "  Применить ${best_ip}:2408? (y/n): "
                read -r confirm < /dev/tty
                [ "$confirm" != "y" ] && read -p "  Enter..." < /dev/tty && return
            else
                echo -e "  ${RED}✗ Не удалось получить IP${NC}"
                read -p "  Enter..." < /dev/tty; return
            fi
        else
            echo -e "  ${RED}✗ Не удалось установить cfscanner${NC}"
            read -p "  Enter..." < /dev/tty; return
        fi
    elif [[ "$reg_ch" =~ ^[nN]$ ]]; then
        # Конвертация своего IPv4 в NAT64
        echo -e "\n  ${WHITE}Введите IPv4 WARP эндпоинта (например 162.159.199.2):${NC}"
        read -r custom_ipv4 < /dev/tty
        echo -e "  ${WHITE}Выберите NAT64 префикс:${NC}"
        echo -e "  [1] 2a02:898:146:64::  Нидерланды"
        echo -e "  [2] 2602:fc59:b0:64::  США (West)"
        echo -e "  [3] 2602:fc59:11:64::  США (East)"
        read -r nat64_ch < /dev/tty
        local nat64_prefix=""
        case "$nat64_ch" in
            1) nat64_prefix="2a02:898:146:64::" ;;
            2) nat64_prefix="2602:fc59:b0:64::" ;;
            3) nat64_prefix="2602:fc59:11:64::" ;;
            *) echo -e "  ${RED}✗ Неверный выбор${NC}"; read -p "  Enter..." < /dev/tty; return ;;
        esac
        if [[ "$custom_ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            local nat64_ep
            nat64_ep=$(python3 -c "
parts = list(map(int, '${custom_ipv4}'.split('.')))
hex_ip = '{:02x}{:02x}:{:02x}{:02x}'.format(*parts)
print('[${nat64_prefix}' + hex_ip + ']:2408')
" 2>/dev/null)
            chosen_ep="$nat64_ep"
            chosen_colo="NAT64 custom: ${custom_ipv4}"
            echo -e "  ${GREEN}✓ IPv6 эндпоинт: ${nat64_ep}${NC}"
        else
            echo -e "  ${RED}✗ Неверный IPv4${NC}"; read -p "  Enter..." < /dev/tty; return
        fi
    elif [[ "$reg_ch" =~ ^[0-9]+$ ]] && (( reg_ch >= 1 && reg_ch <= ${#WARP_COLO_ORDER[@]} )); then
        chosen_colo="${WARP_COLO_ORDER[$((reg_ch-1))]}"
        chosen_ep="${WARP_COLO_ENDPOINTS[$chosen_colo]}"
        if [[ "$chosen_colo" == *"[NAT64]"* ]] && [ "$has_ipv6" -eq 0 ]; then
            echo -e "  ${RED}✗ NAT64 требует IPv6. На этом сервере IPv6 недоступен.${NC}"
            read -p "  Enter..." < /dev/tty; return
        fi
        echo -e "\n  ${YELLOW}Применяю: ${chosen_colo}...${NC}"
    elif (( reg_ch == i )); then
        echo -e "\n  ${YELLOW}Сбрасываю на авто...${NC}"
        warp-cli tunnel endpoint reset 2>/dev/null || \
            warp-cli set-custom-endpoint "" 2>/dev/null
    fi

    [ -n "$chosen_ep" ] && {
        warp-cli tunnel endpoint set "$chosen_ep" 2>/dev/null ||             warp-cli set-custom-endpoint "$chosen_ep" 2>/dev/null
    }

    # Переподключаем с ожиданием
    echo -e "  ${CYAN}↻ Переподключаю...${NC}"
    echo -e "  ${WHITE}Примечание: не все датацентры доступны — Cloudflare выберет ближайший рабочий${NC}"
    warp-cli disconnect 2>/dev/null
    sleep 2
    warp-cli connect 2>/dev/null

    # Ждём подключения до 30 сек
    local new_colo="" new_ip=""
    for _w in $(seq 1 10); do
        sleep 3
        local st; st=$(warp-cli status 2>/dev/null | head -1)
        echo -ne "  ${YELLOW}${st}${NC}
"
        if echo "$st" | grep -qi "Connected"; then
            echo ""
            local new_stats; new_stats=$(warp-cli tunnel stats 2>/dev/null)
            new_colo=$(echo "$new_stats" | grep 'Colo:' | awk '{print $2}' | cut -d'(' -f1 | tr -d ' ')
            new_ip=$(_3xui_warp_ip)
            break
        fi
        (( _w % 3 == 0 )) && warp-cli connect 2>/dev/null
    done
    echo ""

    echo -e "  ${GREEN}✓ Готово!${NC}"
    if [ -n "$new_colo" ]; then
        echo -e "  ${WHITE}Датацентр:${NC} ${GREEN}${new_colo}${NC}  IP: ${GREEN}${new_ip:-?}${NC}"
        [ "$new_colo" != "${cur_colo}" ] &&             echo -e "  ${CYAN}(было: ${cur_colo} → стало: ${new_colo})${NC}" ||             echo -e "  ${YELLOW}⚠ Датацентр не изменился — Cloudflare выбрал ближайший${NC}"
    else
        echo -e "  ${YELLOW}⚠ Подключение не установлено — попробуйте позже${NC}"
        warp-cli status 2>/dev/null | head -2 | while read -r l; do echo "    $l"; done
    fi
    log_action "WARP region: ${chosen_colo:-авто} → ${new_colo:-?} (${new_ip:-?})"
    read -p "  Enter..." < /dev/tty
}

_3xui_warp_instruction() {
    clear
    local socks_port="${WARP_SOCKS_PORT:-40000}"
    local wip; wip=$(_3xui_warp_ip 2>/dev/null || echo "?")

    echo -e "\n${CYAN}━━━ Инструкция: WARP в 3X-UI ━━━${NC}\n"
    echo -e "${WHITE}WARP работает как SOCKS5 прокси на ${CYAN}127.0.0.1:${socks_port}${NC}"
    echo -e "${WHITE}Текущий WARP IP: ${GREEN}${wip}${NC}\n"

    echo -e "${MAGENTA}━━ Способ 1: Outbound для всех клиентов ━━${NC}"
    echo -e "${WHITE}В панели 3X-UI:${NC}"
    echo -e "  ${CYAN}1.${NC} Настройки → Xray конфигурация → Outbounds"
    echo -e "  ${CYAN}2.${NC} Добавить outbound:"
    echo -e '     {
       "tag": "WARP",
       "protocol": "socks",
       "settings": {
         "servers": [{
           "address": "127.0.0.1",
           "port": '"${socks_port}"'
         }]
       }
     }'
    echo -e "  ${CYAN}3.${NC} Routing → Добавить правило (заблокированные сайты → WARP):"
    echo -e ""

    echo -e "     ${WHITE}Для России (блокировки РКН через WARP):${NC}"
    echo -e '     { "outboundTag": "WARP", "domain": ["youtube.com","instagram.com","twitter.com","facebook.com","tiktok.com"] }'
    echo -e ""
    echo -e "     ${WHITE}Или через roscomvpn geosite (рекомендуется):${NC}"
    echo -e '     { "outboundTag": "WARP", "domain": ["geosite:category-ru-blocked"] }'
    echo -e "  ${CYAN}4.${NC} Сохранить → Перезапустить Xray\n"

    echo -e "  ${YELLOW}💡 Совет:${NC} Установите roscomvpn geoip/geosite (Система → Установка → [g])"
    echo -e "     Тогда работает правило ${CYAN}geosite:category-ru${NC} для прямых РФ сайтов\n"

    echo -e "${MAGENTA}━━ Способ 2: Только для конкретного inbound ━━${NC}"
    echo -e "${WHITE}В настройках нужного inbound:${NC}"
    echo -e "  ${CYAN}1.${NC} Открыть inbound → Sniffing → включить"
    echo -e "  ${CYAN}2.${NC} Routing → Источник: inbound tag → Назначение: WARP\n"

    echo -e "${MAGENTA}━━ Способ 3: Автоматически (наш скрипт уже добавил) ━━${NC}"
    # Проверяем добавлен ли outbound
    local db="/etc/x-ui/x-ui.db"
    if [ -f "$db" ] && command -v sqlite3 &>/dev/null; then
        local has_warp
        has_warp=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null | \
            python3 -c "import json,sys; cfg=json.load(sys.stdin); outs=[o for o in cfg.get('outbounds',[]) if o.get('tag','').upper()=='WARP']; print(len(outs))" 2>/dev/null)
        if [ "${has_warp:-0}" -gt 0 ]; then
            echo -e "  ${GREEN}✓ Outbound WARP уже добавлен в xray конфигурацию${NC}"
            echo -e "  ${WHITE}Осталось только настроить routing в 3X-UI панели.${NC}"
        else
            echo -e "  ${YELLOW}⚠ Outbound не добавлен. Нажмите [a] чтобы добавить автоматически.${NC}"
        fi
    fi

    echo ""
    echo -e "  ${YELLOW}[a]${NC}  Добавить outbound WARP автоматически"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "Выбор: " instr_choice
    case "$instr_choice" in
        a|A)
            echo -e "${YELLOW}Применяю...${NC}"
            _3xui_patch_db && echo -e "${GREEN}✓ Outbound WARP добавлен. Перезапустите Xray в 3X-UI.${NC}" || \
                echo -e "${RED}Ошибка. Добавьте вручную по инструкции выше.${NC}"
            read -p "Нажмите Enter..." ;;
    esac
}

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
        is_3xui && [ "$xui_running" -eq 1 ] &&             echo -e "  ${CYAN}[r]${NC}  Переподключить WARP (обновить датацентр)"
        echo -e "  ${RED}[4]${NC}  Удалить WARP"
        is_3xui && echo -e "  ${CYAN}[i]${NC}  Инструкция — как подключить трафик через WARP в 3X-UI"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " warp_action
        case "$warp_action" in
            1) warp_test; return ;;
            [rRрР])
                if is_3xui; then
                    echo -e "  ${CYAN}↻ Переподключаю WARP...${NC}"
                    warp-cli disconnect 2>/dev/null; sleep 2; warp-cli connect 2>/dev/null
                    sleep 6
                    local new_ip; new_ip=$(_3xui_warp_ip)
                    local new_colo; new_colo=$(warp-cli tunnel stats 2>/dev/null | grep Colo | awk '{print $2}')
                    echo -e "  ${GREEN}✓ ${new_colo:-?}  IP: ${new_ip:-?}${NC}"
                    read -p "  Enter..." < /dev/tty
                fi ;;
            i|I) is_3xui && { _3xui_warp_instruction; return; } ;;
            4) # Удаление WARP
                echo -ne "\n  ${RED}Удалить WARP полностью? (y/n): ${NC}"
                read -r c < /dev/tty
                [ "$c" != "y" ] && continue
                echo -e "\n${YELLOW}Удаляю WARP...${NC}"
                if is_amnezia && [ -n "$AWG_CONTAINER" ]; then
                    echo -e "  ${CYAN}Останавливаю WARP туннель...${NC}"
                    # Опускаем warp интерфейс внутри контейнера
                    docker exec "$AWG_CONTAINER" sh -c "
                        wg-quick down warp 2>/dev/null || true
                        wg-quick down /opt/warp/warp.conf 2>/dev/null || true
                        wg-quick down /etc/amnezia/amneziawg/warp.conf 2>/dev/null || true
                        ip link delete warp 2>/dev/null || true
                    " 2>/dev/null
                    # Удаляем все WARP файлы
                    docker exec "$AWG_CONTAINER" sh -c "
                        rm -f /opt/warp/warp.conf /opt/warp/clients.list
                        rm -f /etc/amnezia/amneziawg/warp.conf
                        rm -f /opt/warp/wgcf-account.toml /root/wgcf-account.toml
                        rm -f /opt/warp/wgcf-profile.conf /root/wgcf-profile.conf
                    " 2>/dev/null
                    # Убираем ip rules для клиентов (только таблица 100, не трогаем основные)
                    docker exec "$AWG_CONTAINER" sh -c "
                        ip rule list | awk '/lookup 100/{print \$1}' | sed 's/://' | \
                            while read -r pr; do ip rule del priority \"\$pr\" 2>/dev/null || true; done
                        ip route flush table 100 2>/dev/null || true
                        # Удаляем только WARP MASQUERADE правила, не трогаем базовые
                        iptables -t nat -S POSTROUTING 2>/dev/null | grep 'warp' | \
                            sed 's/^-A /-D /' | while read -r r; do iptables -t nat \$r 2>/dev/null || true; done
                    " 2>/dev/null
                    # Убираем WARP из start.sh
                    docker exec "$AWG_CONTAINER" sh -c "
                        sed -i '/warp/Id' /opt/amnezia/start.sh 2>/dev/null || true
                        sed -i '/wg-quick.*warp/d' /opt/amnezia/start.sh 2>/dev/null || true
                    " 2>/dev/null
                    echo -e "  ${GREEN}✓ WARP туннель удалён${NC}"
                fi
                if is_3xui; then
                    warp-cli disconnect 2>/dev/null || true
                    systemctl stop warp-svc 2>/dev/null
                    systemctl disable warp-svc 2>/dev/null
                    apt-get remove -y cloudflare-warp 2>/dev/null
                    echo -e "  ${GREEN}✓ warp-cli удалён${NC}"
                fi
                sed -i '/^WARP_/d' /etc/govpn/config 2>/dev/null
                log_action "WARP: удалён"
                echo -e "  ${GREEN}✓ Готово. Перезапустите govpn.${NC}"
                read -p "  Enter..." < /dev/tty
                return ;;
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
                # ── Бэкап перед изменениями ──────────────────
                local bk_dir="/etc/govpn/backups"
                mkdir -p "$bk_dir"
                local bk_ts; bk_ts=$(date +%s)
                local bk_clients="${bk_dir}/awg_clients.bak.${bk_ts}"
                local bk_start="${bk_dir}/awg_start.bak.${bk_ts}"

                # Сохраняем текущий список клиентов WARP
                local _awg_cf; _awg_cf=$(_awg_conf)
                local _awg_clients_file="${_awg_cf%/*}/warp_clients.txt"
                docker exec "$AWG_CONTAINER" sh -c                     "cat '${_awg_clients_file}' 2>/dev/null || echo ''" > "$bk_clients" 2>/dev/null
                # Сохраняем start.sh
                docker exec "$AWG_CONTAINER" sh -c                     "cat /opt/amnezia/start.sh 2>/dev/null || echo ''" > "$bk_start" 2>/dev/null
                echo -e "${YELLOW}[0/4]${NC} Бэкап → ${bk_clients##*/}  ${GREEN}✓${NC}"

                echo -e "${YELLOW}[1/4]${NC} Сохраняем список клиентов..."
                _awg_save_clients "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[2/4]${NC} Применяем правила маршрутизации..."
                _awg_apply_rules "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                echo -e "${YELLOW}[3/4]${NC} Патчим start.sh..."
                _awg_patch_start_sh "${sel_ips[@]}"
                echo -e "${GREEN}  ✓${NC}"

                # ── Верификация ───────────────────────────────
                echo -e "${YELLOW}[4/4]${NC} Проверка туннеля..."
                local verify_ok=1
                if _awg_warp_running; then
                    # Проверяем что WARP IP отвечает
                    local warp_test
                    warp_test=$(docker exec "$AWG_CONTAINER" sh -c                         "curl -s4 --max-time 5 --interface warp https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -c 'warp=on'"                         2>/dev/null || echo 0)
                    if [ "${warp_test:-0}" -gt 0 ]; then
                        local wip; wip=$(_awg_warp_ip)
                        echo -e "${GREEN}  ✓ WARP активен (${wip})${NC}"
                    else
                        # WARP запущен но trace не прошёл — не критично
                        echo -e "${YELLOW}  ⚠ WARP запущен, trace недоступен — правила применены${NC}"
                    fi
                else
                    echo -e "${YELLOW}  ⚠ WARP не запущен — правила сохранены, активируются при запуске WARP${NC}"
                fi

                # Проверяем что selected клиенты имеют ip rule
                if [ "${#sel_ips[@]}" -gt 0 ] && _awg_warp_running; then
                    local missing=0
                    for chk_ip in "${sel_ips[@]}"; do
                        local bare="${chk_ip%/32}"
                        local has_rule
                        has_rule=$(docker exec "$AWG_CONTAINER" sh -c                             "ip rule list | grep -c 'from ${bare}'" 2>/dev/null || echo 0)
                        [ "${has_rule:-0}" -eq 0 ] && (( missing++ ))
                    done
                    if [ "$missing" -gt 0 ]; then
                        echo -e "${RED}  ✗ ${missing} клиент(ов) без маршрута! Откат...${NC}"
                        # Откат
                        local old_clients
                        old_clients=$(cat "$bk_clients" 2>/dev/null)
                        if [ -n "$old_clients" ]; then
                            local -a old_ips=()
                            while IFS= read -r _ip; do [ -n "$_ip" ] && old_ips+=("$_ip"); done <<< "$old_clients"
                            _awg_save_clients "${old_ips[@]}"
                            _awg_apply_rules "${old_ips[@]}"
                            echo -e "${YELLOW}  Откат выполнен. Бэкап: ${bk_clients##*/}${NC}"
                        fi
                        read -p "  Enter..." < /dev/tty
                        continue
                    fi
                fi

                log_action "AWG CLIENTS: ${#sel_ips[@]} через WARP (бэкап: ${bk_ts})"
                echo -e "\n${GREEN}✅ Применено. Изменения активны.${NC}"
                echo -e "${WHITE}Бэкап сохранён: ${bk_clients##*/}${NC}"
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

_iptables_hosts_setup() {
    clear
    echo -e "\n${CYAN}━━━ Настройка /etc/hosts ━━━${NC}\n"

    local hostname; hostname=$(hostname)
    local main_ip; main_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')

    echo -e "  ${WHITE}Текущий hostname:${NC} ${CYAN}${hostname}${NC}"
    echo -e "  ${WHITE}Основной IP:${NC}     ${CYAN}${main_ip}${NC}\n"

    echo -e "  ${WHITE}Текущий /etc/hosts:${NC}"
    cat /etc/hosts | while read -r l; do echo "    $l"; done

    echo ""
    echo -e "  ${WHITE}Рекомендуемые записи:${NC}"
    echo -e "    ${CYAN}127.0.0.1${NC}  localhost"
    echo -e "    ${CYAN}127.0.1.1${NC}  ${hostname}"
    echo -e "    ${CYAN}::1${NC}        localhost ip6-localhost ip6-loopback\n"

    echo -e "  ${YELLOW}[1]${NC}  Добавить стандартные записи"
    echo -e "  ${YELLOW}[2]${NC}  Открыть в редакторе (nano)"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор: " hosts_ch < /dev/tty

    case "$hosts_ch" in
        1)
            # Добавляем если нет
            grep -q "^127.0.1.1" /etc/hosts || \
                echo "127.0.1.1 ${hostname}" >> /etc/hosts
            grep -q "^::1.*ip6-loopback" /etc/hosts || \
                echo "::1 localhost ip6-localhost ip6-loopback" >> /etc/hosts
            echo -e "  ${GREEN}✓ Записи добавлены${NC}"
            cat /etc/hosts ;;
        2)
            nano /etc/hosts ;;
    esac
    read -p "  Enter..." < /dev/tty
}

_iptables_diagnose() {
    clear
    echo -e "\n${CYAN}━━━ Диагностика iptables ━━━${NC}\n"

    # Занятые порты
    echo -e "  ${WHITE}Занятые порты (443, 8443, MTProto):${NC}"
    for port in 443 8443 25 587; do
        local proc; proc=$(ss -tlnp | grep ":${port} " | grep -oP '"[^"]+"' | head -1 | tr -d '"')
        if [ -n "$proc" ]; then
            echo -e "    ${CYAN}:${port}${NC} → ${proc}"
        else
            echo -e "    ${GREEN}:${port}${NC} → свободен"
        fi
    done

    echo ""
    echo -e "  ${WHITE}REDIRECT правила (UDP диапазоны):${NC}"
    local has_redirect=0
    iptables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT | while read -r rule; do
        local dport; dport=$(echo "$rule" | grep -oP '(?<=--dport )[^ ]+')
        local toport; toport=$(echo "$rule" | grep -oP '(?<=--to-port )[^ ]+')
        local proto; proto=$(echo "$rule" | grep -oP '(?<=-p )[^ ]+')
        echo -e "    ${YELLOW}${proto}:${dport}${NC} → ${GREEN}:${toport}${NC}"
        has_redirect=1

        # Анализ
        if echo "$dport" | grep -q ':'; then
            local from_p; from_p="${dport%:*}"
            local to_p; to_p="${dport#*:}"
            local range=$((to_p - from_p))
            echo -e "    ${WHITE}Диапазон: ${range} портов${NC}"
        fi
        if [ "$toport" = "443" ]; then
            echo -e "    ${YELLOW}⚠ Редирект на 443 — порт должен быть свободен или слушать xray${NC}"
            # Проверяем что слушает на 443
            local p443; p443=$(ss -tlnp | grep ':443 ' | grep -oP '"[^"]+"' | head -1 | tr -d '"')
            if [ -n "$p443" ]; then
                echo -e "    ${GREEN}✓ 443 слушает: ${p443}${NC}"
            else
                echo -e "    ${RED}✗ 443 никто не слушает! Редирект бесполезен${NC}"
            fi
        fi
    done

    echo ""
    echo -e "  ${WHITE}Рекомендации:${NC}"
    echo -e "  ${CYAN}•${NC} UDP 25300:25400 → 443 полезен только если Xray слушает UDP:443"
    echo -e "  ${CYAN}•${NC} Для MTProto используй порты 443, 8443 напрямую"
    echo -e "  ${CYAN}•${NC} REDIRECT правила теряются при перезагрузке если не сохранены"
    echo -e "  ${CYAN}•${NC} Проверь: iptables-save | grep REDIRECT"

    echo ""
    echo -ne "  ${YELLOW}Удалить все UDP REDIRECT правила? (y/n):${NC} "
    read -r c < /dev/tty
    if [ "$c" = "y" ]; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT | \
            sed 's/^-A /-D /' | while read -r r; do
            iptables -t nat $r 2>/dev/null && echo -e "  ${GREEN}✓ Удалено: ${r}${NC}"
        done
        save_iptables 2>/dev/null
        echo -e "  ${GREEN}✓ REDIRECT правила удалены${NC}"
    fi
    read -p "  Enter..." < /dev/tty
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

        # Показываем REDIRECT правила (UDP порт-диапазоны → 443)
        local redirects; redirects=$(iptables -t nat -S PREROUTING 2>/dev/null | grep REDIRECT)
        if [ -n "$redirects" ]; then
            echo -e "${WHITE}UDP REDIRECT правила:${NC}"
            echo "$redirects" | while read -r rule; do
                local dport; dport=$(echo "$rule" | grep -oP '(?<=--dport )[^ ]+')
                local toport; toport=$(echo "$rule" | grep -oP '(?<=--to-port )[^ ]+')
                local proto; proto=$(echo "$rule" | grep -oP '(?<=-p )[^ ]+')
                echo -e "  ${YELLOW}${proto}:${dport}${NC} → ${GREEN}:${toport}${NC}  ${YELLOW}[REDIRECT]${NC}"
            done
            echo ""
        fi

        echo -e "  ${WHITE}── Добавить правило ──────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  AmneziaWG / WireGuard (UDP)"
        echo -e "  ${YELLOW}[2]${NC}  VLESS / XRay (TCP)"
        echo -e "  ${YELLOW}[3]${NC}  MTProto (TCP)"
        echo -e "  ${YELLOW}[4]${NC}  Кастомное правило"
        echo -e "  ${YELLOW}[9]${NC}  REDIRECT диапазон портов → xray inbound"
        echo -e "  ${WHITE}── Управление ────────────────────────${NC}"
        echo -e "  ${CYAN}[7]${NC}  Диагностика и рекомендации"
        echo -e "  ${CYAN}[8]${NC}  Настройка /etc/hosts (localhost записи)"
        echo -e "  ${YELLOW}[5]${NC}  Удалить правило"
        echo -e "  ${RED}[6]${NC}  Сбросить все govpn правила"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")

        case "$ch" in
            1) _add_rule "udp" "AmneziaWG/WireGuard" ;;
            2) _add_rule "tcp" "VLESS/XRay" ;;
            3) _add_rule "tcp" "MTProto" ;;
            4) _add_custom_rule ;;
            5) _delete_rule ;;
            7) _iptables_diagnose ;;
            8) _iptables_hosts_setup ;;
            9)
                clear
                echo -e "\n${CYAN}━━━ REDIRECT диапазон портов → xray inbound ━━━${NC}\n"
                python3 -c "
import sqlite3
try:
    conn = sqlite3.connect('/etc/x-ui/x-ui.db')
    conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
    for r in conn.execute('SELECT id, remark, port FROM inbounds WHERE port>0 ORDER BY id'):
        print(f'  [{r[0]}] {r[1]} :{r[2]}')
    conn.close()
except: pass
" 2>/dev/null
                echo ""
                echo -ne "  Целевой порт xray inbound: "; read -r redir_target < /dev/tty
                [[ -z "$redir_target" ]] && continue
                echo -ne "  Протокол (tcp/udp/both) [tcp]: "; read -r redir_proto < /dev/tty
                redir_proto="${redir_proto:-tcp}"
                echo -ne "  Диапазон портов (например 25400:25500): "; read -r redir_range < /dev/tty
                [[ -z "$redir_range" ]] && continue
                if [[ "$redir_proto" == "both" ]]; then
                    iptables -t nat -A PREROUTING -p tcp --dport "$redir_range" -j REDIRECT --to-port "$redir_target" 2>/dev/null
                    iptables -t nat -A PREROUTING -p udp --dport "$redir_range" -j REDIRECT --to-port "$redir_target" 2>/dev/null
                    ufw allow "$redir_range/tcp" 2>/dev/null || true
                    ufw allow "$redir_range/udp" 2>/dev/null || true
                else
                    iptables -t nat -A PREROUTING -p "$redir_proto" --dport "$redir_range" -j REDIRECT --to-port "$redir_target" 2>/dev/null
                    ufw allow "$redir_range/$redir_proto" 2>/dev/null || true
                fi
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                echo -e "  ${GREEN}✓ REDIRECT ${redir_proto}:${redir_range} → ${redir_target} добавлен${NC}"
                sleep 2
                ;;
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
                if [ "$ip" = "$MY_IP" ]; then
                    # Текущий сервер — всегда онлайн
                    echo -e "  ${GREEN}●${NC} ${WHITE}${label}${NC}  ${CYAN}← этот сервер${NC}"
                else
                    # Удалённый сервер — пингуем
                    local ms; ms=$(tcp_ping "$ip" "22" 2 2>/dev/null)
                    [ -z "$ms" ] && ms=$(tcp_ping "$ip" "443" 2 2>/dev/null)
                    [ -z "$ms" ] && ms=$(ping -c 1 -W 2 "$ip" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
                    [ -n "$ms" ] && \
                        echo -e "  ${GREEN}●${NC} ${WHITE}${label}${NC}  ${GREEN}${ms}ms${NC}" || \
                        echo -e "  ${RED}●${NC} ${WHITE}${label}${NC}  ${RED}недоступен${NC}"
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

    local scanner_bin="/usr/local/bin/RealiTLScanner"
    if [ ! -f "$scanner_bin" ]; then
        echo -e "${YELLOW}Установка RealiTLScanner...${NC}"
        local arch; case "$(uname -m)" in x86_64) arch="64" ;; aarch64) arch="arm64" ;; *) arch="" ;; esac
        if [ -n "$arch" ]; then
            curl -fsSL --max-time 30 \
                "https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-linux-${arch}" \
                -o "$scanner_bin" 2>/dev/null && chmod +x "$scanner_bin" || rm -f "$scanner_bin"
        fi
        if [ ! -f "$scanner_bin" ]; then
            command -v go &>/dev/null || {
                local ga; [ "$(uname -m)" = "x86_64" ] && ga="amd64" || ga="arm64"
                curl -fsSL "https://go.dev/dl/go1.22.4.linux-${ga}.tar.gz" -o /tmp/go.tar.gz 2>/dev/null
                tar -C /usr/local -xzf /tmp/go.tar.gz 2>/dev/null; rm -f /tmp/go.tar.gz
                export PATH="/usr/local/go/bin:$PATH"
            }
            GOPATH=/tmp/go_build go install github.com/xtls/RealiTLScanner@latest 2>/dev/null && \
                cp /tmp/go_build/bin/RealiTLScanner "$scanner_bin" 2>/dev/null
        fi
        [ ! -f "$scanner_bin" ] && {
            echo -e "${RED}Не удалось установить.${NC}"
            echo -e "${WHITE}wget https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.1/RealiTLScanner-linux-64 -O /usr/local/bin/RealiTLScanner && chmod +x /usr/local/bin/RealiTLScanner${NC}"
            read -p "Enter..."; return
        }
        chmod +x "$scanner_bin"
        echo -e "${GREEN}  ✓ Готов${NC}\n"
    fi

    # Собираем свои серверы
    local -a srv_ips=() srv_names=()
    [ -n "$MY_IP" ] && {
        local my_name; my_name=$(grep "^${MY_IP}=" "$ALIASES_FILE" 2>/dev/null | cut -d'=' -f2 | cut -d'|' -f1)
        srv_ips+=("$MY_IP"); srv_names+=("${my_name:-этот сервер}")
    }
    if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
        while IFS='=' read -r ip val; do
            [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3} ]] || continue
            [ "$ip" = "$MY_IP" ] && continue
            local n; n=$(echo "$val" | cut -d'|' -f1)
            srv_ips+=("$ip"); srv_names+=("${n:-$ip}")
        done < "$ALIASES_FILE"
    fi

    # Строим меню динамически
    clear
    echo -e "\n${CYAN}━━━ Reality SNI Scanner ━━━${NC}"
    echo -e "${WHITE}Ищем серверы с TLS 1.3 + ALPN h2 для маскировки Reality.${NC}\n"

    local idx=1
    local -a menu_ips=() menu_labels=()

    # Мои серверы — каждый отдельным пунктом
    if [ ${#srv_ips[@]} -gt 0 ]; then
        echo -e "${CYAN}  Мои серверы:${NC}"
        for i in "${!srv_ips[@]}"; do
            local ip="${srv_ips[$i]}" name="${srv_names[$i]}"
            echo -e "  ${GREEN}[${idx}]${NC}  ${WHITE}${name}${NC}  ${CYAN}(${ip})${NC}"
            menu_ips+=("$ip"); menu_labels+=("server")
            ((idx++))
        done
        echo ""
    fi

    # Разделитель
    echo -e "  ${YELLOW}[${idx}]${NC}  🌍 CDN  ${WHITE}Cloudflare / Fastly / Akamai${NC}"
    menu_ips+=("cdn"); menu_labels+=("cdn")
    local cdn_idx=$idx; ((idx++))

    echo -e "  ${YELLOW}[${idx}]${NC}  🔍 Свой IP / домен"
    menu_ips+=("custom"); menu_labels+=("custom")
    local custom_idx=$idx; ((idx++))

    echo -e "  ${YELLOW}[0]${NC}  ↩  Назад"
    echo ""
    read -p "Выбор [1]: " choice
    [ -z "$choice" ] && choice=1
    [ "$choice" = "0" ] && return

    local -a scan_ips=()
    local threads=5

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < idx )); then
        local sel_type="${menu_labels[$((choice-1))]}"
        case "$sel_type" in
            server)
                scan_ips=("${menu_ips[$((choice-1))]}")
                threads=5
                ;;
            cdn)
                scan_ips=("1.1.1.1" "151.101.1.1" "23.32.0.1")
                threads=8
                ;;
            custom)
                echo -e "${WHITE}Введите IP или домен:${NC}"
                read -p "> " custom_ip
                [ -z "$custom_ip" ] && return
                scan_ips=("$custom_ip"); threads=5
                ;;
        esac
    else
        return
    fi

    _reality_do_scan "$scanner_bin" 10 "$threads" "${scan_ips[@]}"
}

_reality_do_scan() {
    local scanner_bin="$1" max_results="$2" threads="$3"
    shift 3
    local scan_ips=("$@")
    local time_per_ip=25

    clear
    echo -e "\n${CYAN}━━━ Сканирование ━━━${NC}\n"

    local combined_file="/tmp/reality_combined_$$.csv"
    echo "IP,ORIGIN,CERT_DOMAIN,CERT_ISSUER,GEO_CODE" > "$combined_file"

    local t_num=0 total_t=${#scan_ips[@]}
    for ip in "${scan_ips[@]}"; do
        ((t_num++))
        echo -ne "  ${CYAN}[${t_num}/${total_t}]${NC} ${WHITE}${ip}${NC} … "
        local t_file="/tmp/reality_t${t_num}_$$.csv"
        timeout "$time_per_ip" "$scanner_bin" \
            -addr "$ip" -thread "$threads" -timeout 4 \
            -out "$t_file" > /dev/null 2>&1 || true
        local found=0
        [ -f "$t_file" ] && found=$(( $(wc -l < "$t_file") - 1 )) && \
            tail -n +2 "$t_file" >> "$combined_file" && rm -f "$t_file"
        [ "$found" -gt 0 ] && echo -e "${GREEN}${found} SNI${NC}" || echo -e "${YELLOW}0 SNI${NC}"
    done

    echo ""
    _reality_show_results "$combined_file" "$max_results" "$scanner_bin" "$threads" "${scan_ips[@]}"
}

_reality_show_results() {
    local combined_file="$1" max_results="$2" scanner_bin="$3" threads="$4"
    shift 4
    local scan_ips=("$@")

    if [ ! -f "$combined_file" ] || [ "$(wc -l < "$combined_file")" -le 1 ]; then
        echo -e "${RED}Результатов нет.${NC}"
        echo -e "${WHITE}Эти IP не поддерживают TLS 1.3 + h2. Попробуйте CDN.${NC}"
        rm -f "$combined_file"
        echo ""; read -p "Enter..."; return
    fi

    local clean
    clean=$(tail -n +2 "$combined_file" | \
        awk -F',' '{
            d=$3; gsub(/"/, "", d); gsub(/^\*\./, "", d)
            ip=$1; gsub(/"/, "", ip)
            if (d != "" && d != "N/A" && ip != "") print ip"\t"d
        }' | sort -t$'\t' -k2 -u | head -"$max_results")

    local total; total=$(echo "$clean" | grep -c "." 2>/dev/null || echo 0)

    echo -e "${GREEN}✅ Найдено: ${total} SNI${NC}\n"
    printf "  ${WHITE}%-20s %s${NC}\n" "IP" "Домен (SNI)"
    echo -e "  $(printf '─%.0s' {1..55})"
    echo "$clean" | while IFS=$'\t' read -r ip domain; do
        printf "  ${GREEN}✓${NC} %-18s ${CYAN}%s${NC}\n" "$ip" "$domain"
    done

    echo ""
    echo -e "${MAGENTA}━━ Скопируйте в 3X-UI → Reality → serverName: ━━${NC}"
    echo "$clean" | awk -F$'\t' '{print $2}' | sort -u | \
        while read -r d; do echo -e "  ${GREEN}▶${NC} ${CYAN}${d}${NC}"; done

    echo ""
    echo -e "  ${YELLOW}[+]${NC}  Найти ещё (сканируем дольше)"
    echo -e "  ${YELLOW}[0]${NC}  ↩  Назад"
    echo ""
    read -p "Выбор: " more_choice

    if [ "$more_choice" = "+" ]; then
        local new_max=$(( max_results + 10 ))
        local new_time=45
        echo -e "\n${CYAN}Сканируем дольше (${new_time}с на каждый IP)...${NC}"
        local new_combined="/tmp/reality_more_$$.csv"
        echo "IP,ORIGIN,CERT_DOMAIN,CERT_ISSUER,GEO_CODE" > "$new_combined"
        local t_num=0
        for ip in "${scan_ips[@]}"; do
            ((t_num++))
            echo -ne "  ${CYAN}[${t_num}/${#scan_ips[@]}]${NC} ${ip} … "
            local t_file="/tmp/reality_more${t_num}_$$.csv"
            timeout "$new_time" "$scanner_bin" \
                -addr "$ip" -thread "$threads" -timeout 4 \
                -out "$t_file" > /dev/null 2>&1 || true
            local found=0
            [ -f "$t_file" ] && found=$(( $(wc -l < "$t_file") - 1 )) && \
                tail -n +2 "$t_file" >> "$new_combined" && rm -f "$t_file"
            echo -e "${GREEN}${found} SNI${NC}"
        done
        rm -f "$combined_file"
        _reality_show_results "$new_combined" "$new_max" "$scanner_bin" "$threads" "${scan_ips[@]}"
        return
    fi

    rm -f "$combined_file"
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

# ═══════════════════════════════════════════════════════════════
#  HYSTERIA2 — МЕНЮ УПРАВЛЕНИЯ
# ═══════════════════════════════════════════════════════════════

# ─── Вспомогательные функции для управления пользователями Hy2 ───

_hy2_list_users() {
    python3 /tmp/hy2_list.py 2>/dev/null
}

_hy2_ensure_userpass() {
    python3 /tmp/hy2_migrate.py 2>/dev/null
}

_hy2_add_user() {
    python3 /tmp/hy2_adduser.py "$1" "$2" 2>/dev/null
}

_hy2_del_user() {
    python3 /tmp/hy2_deluser.py "$1" 2>/dev/null
}

_hy2_user_uri() {
    local username="$1" password="$2"
    local port sni obfs_pass
    port=$(grep -oP '^listen: :\K[0-9]+' /etc/hysteria/config.yaml 2>/dev/null || echo "443")
    sni=$(python3 -c "import yaml; c=yaml.safe_load(open('/etc/hysteria/config.yaml')); print(c.get('masquerade',{}).get('proxy',{}).get('url','').replace('https://',''))" 2>/dev/null || echo "")
    obfs_pass=$(python3 -c "import yaml; c=yaml.safe_load(open('/etc/hysteria/config.yaml')); print(c.get('obfs',{}).get('salamander',{}).get('password',''))" 2>/dev/null || echo "")
    # Чистый URI без пустых параметров (insecure=1 вместо allowInsecure=true для совместимости)
    local uri="hy2://${password}@${MY_IP}:${port}?insecure=1"
    [ -n "$sni" ] && uri="${uri}&sni=${sni}"
    [ -n "$obfs_pass" ] && uri="${uri}&obfs=salamander&obfs-password=${obfs_pass}"
    uri="${uri}#${username}"
    echo "$uri"
}

_hy2_write_helpers() {
    python3 - << 'PYEOF'
import os

list_py = """import yaml,sys
try:
    cfg=yaml.safe_load(open('/etc/hysteria/config.yaml'))
    auth=cfg.get('auth',{})
    if auth.get('type')=='userpass':
        for u,p in auth.get('userpass',{}).items(): print(f"{u}:{p}")
    elif auth.get('type')=='password':
        print(f"default:{auth.get('password','')}")
except Exception as e: print(f"ERR:{e}",file=sys.stderr)
"""

migrate_py = """import yaml,sys
p='/etc/hysteria/config.yaml'
try:
    cfg=yaml.safe_load(open(p))
    auth=cfg.get('auth',{})
    if auth.get('type')=='password':
        cfg['auth']={'type':'userpass','userpass':{'default':auth.get('password','')}}
        yaml.dump(cfg,open(p,'w'),default_flow_style=False,allow_unicode=True)
        print("migrated")
    else: print("ok")
except Exception as e: print(f"err:{e}",file=sys.stderr); sys.exit(1)
"""

adduser_py = """import yaml,sys
p='/etc/hysteria/config.yaml'
u,pw=sys.argv[1],sys.argv[2]
try:
    cfg=yaml.safe_load(open(p))
    cfg['auth']['userpass'][u]=pw
    yaml.dump(cfg,open(p,'w'),default_flow_style=False,allow_unicode=True)
    print("ok")
except Exception as e: print(f"err:{e}",file=sys.stderr); sys.exit(1)
"""

deluser_py = """import yaml,sys
p='/etc/hysteria/config.yaml'
u=sys.argv[1]
try:
    cfg=yaml.safe_load(open(p))
    users=cfg['auth'].get('userpass',{})
    if u not in users: print("err:not found"); sys.exit(1)
    del users[u]
    cfg['auth']['userpass']=users
    yaml.dump(cfg,open(p,'w'),default_flow_style=False,allow_unicode=True)
    print("ok")
except Exception as e: print(f"err:{e}",file=sys.stderr); sys.exit(1)
"""

for fname, code in [('/tmp/hy2_list.py',list_py),('/tmp/hy2_migrate.py',migrate_py),
                     ('/tmp/hy2_adduser.py',adduser_py),('/tmp/hy2_deluser.py',deluser_py)]:
    with open(fname,'w') as f: f.write(code)
print("ok")
PYEOF
}

_hy2_users_menu() {
    _hy2_write_helpers > /dev/null 2>&1
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Hysteria2 — пользователи ━━━${NC}\n"
        command -v python3 &>/dev/null || { echo -e "${RED}python3 не найден${NC}"; read -p "Enter..."; return; }
        python3 -c "import yaml" 2>/dev/null || apt-get install -y python3-yaml > /dev/null 2>&1
        _hy2_ensure_userpass > /dev/null 2>&1
        local -a users=()
        while IFS= read -r line; do
            [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && users+=("$line")
        done < <(_hy2_list_users)
        if [ ${#users[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}Пользователей нет${NC}\n"
        else
            local i=1
            for u in "${users[@]}"; do
                echo -e "  ${YELLOW}[$i]${NC}  ${WHITE}${u%%:*}${NC}  ${CYAN}${u##*:}${NC}"
                (( i++ ))
            done
            echo ""
        fi
        echo -e "  ${GREEN}[a]${NC}  Добавить пользователя"
        echo -e "  ${RED}[d]${NC}  Удалить пользователя"
        echo -e "  ${YELLOW}[q]${NC}  QR-код пользователя"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        case "$ch" in
            a|A|а|А)
                echo -ne "\n  Имя пользователя: "; read -r uname
                [ -z "$uname" ] && continue
                local upass; upass=$(date +%s%N | md5sum | cut -c 1-12)
                echo -ne "  Пароль [авто: ${upass}]: "; read -r inp
                [ -n "$inp" ] && upass="$inp"
                local res; res=$(_hy2_add_user "$uname" "$upass")
                if [[ "$res" == "ok" ]]; then
                    systemctl restart hysteria-server > /dev/null 2>&1
                    local uri; uri=$(_hy2_user_uri "$uname" "$upass")
                    echo -e "\n  ${GREEN}✓ Добавлен: ${uname}${NC}"
                    echo -e "  ${CYAN}${uri}${NC}"
                    echo "$uri" > "/root/hysteria2_${uname}.txt"
                    command -v qrencode &>/dev/null && { echo ""; qrencode -t ANSIUTF8 "$uri"; }
                    log_action "HY2: добавлен ${uname}"
                else
                    echo -e "  ${RED}✗ ${res}${NC}"
                fi
                read -p "  Enter..."
                ;;
            d|D|д|Д)
                [ ${#users[@]} -eq 0 ] && continue
                echo -ne "\n  Номер для удаления: "; read -r num
                [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#users[@]} )) || continue
                local tname="${users[$((num-1))]%%:*}"
                echo -ne "  ${RED}Удалить ${tname}? (y/n): ${NC}"; read -r c
                [[ "$c" != "y" ]] && continue
                local res; res=$(_hy2_del_user "$tname")
                if [[ "$res" == "ok" ]]; then
                    systemctl restart hysteria-server > /dev/null 2>&1
                    rm -f "/root/hysteria2_${tname}.txt"
                    echo -e "  ${GREEN}✓ Удалён: ${tname}${NC}"
                    log_action "HY2: удалён ${tname}"
                else
                    echo -e "  ${RED}✗ ${res}${NC}"
                fi
                read -p "  Enter..."
                ;;
            q|Q|й|Й)
                [ ${#users[@]} -eq 0 ] && continue
                echo -ne "\n  Номер пользователя: "; read -r num
                [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#users[@]} )) || continue
                local target="${users[$((num-1))]}"
                local uri; uri=$(_hy2_user_uri "${target%%:*}" "${target##*:}")
                echo -e "\n  ${CYAN}${uri}${NC}\n"
                command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$uri"
                read -p "  Enter..."
                ;;
            0|"") return ;;
        esac
    done
}

_install_hui() {
    clear
    echo -e "\n${CYAN}━━━ Установка H-UI (веб-панель для Hysteria2) ━━━${NC}\n"
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^h-ui$'; then
        echo -e "  ${YELLOW}H-UI уже установлен${NC}"
        local hui_port; hui_port=$(docker inspect h-ui 2>/dev/null | python3 -c "import json,sys,re; c=json.load(sys.stdin); cmd=' '.join(c[0].get('Config',{}).get('Cmd',[])); m=re.search(r'-p (\d+)',cmd); print(m.group(1) if m else '8081')" 2>/dev/null || echo "8081")
        echo -e "  ${WHITE}Панель:${NC} ${CYAN}http://${MY_IP}:${hui_port}${NC}"
        echo -ne "  Переустановить? (y/n): "; read -r c
        if [[ "$c" == "y" ]]; then
            docker stop h-ui > /dev/null 2>&1; docker rm h-ui > /dev/null 2>&1
        else
            read -p "  Enter..."; return
        fi
    fi
    _install_docker || { read -p "  Enter..."; return 1; }
    local hui_port="8081" hui_tz="Europe/Moscow"
    echo -ne "\n  Порт H-UI [8081]: "; read -r inp; [ -n "$inp" ] && hui_port="$inp"
    echo -ne "  Часовой пояс [Europe/Moscow]: "; read -r inp; [ -n "$inp" ] && hui_tz="$inp"
    echo ""
    echo -e "  ${CYAN}→ Загрузка образа H-UI...${NC}"
    docker pull jonssonyan/h-ui > /dev/null 2>&1
    echo -e "  ${CYAN}→ Запуск контейнера...${NC}"
    docker run -d --cap-add=NET_ADMIN \
        --name h-ui --restart always \
        --network=host \
        -e TZ="${hui_tz}" \
        -v /h-ui/bin:/h-ui/bin \
        -v /h-ui/data:/h-ui/data \
        -v /h-ui/export:/h-ui/export \
        -v /h-ui/logs:/h-ui/logs \
        jonssonyan/h-ui ./h-ui -p "${hui_port}" > /dev/null 2>&1
    sleep 4
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^h-ui$'; then
        local creds; creds=$(docker exec h-ui ./h-ui reset 2>/dev/null || echo "sysadmin / sysadmin")
        echo -e "\n  ${GREEN}✅ H-UI установлен!${NC}"
        echo -e "  ${WHITE}Панель:${NC}       ${CYAN}http://${MY_IP}:${hui_port}${NC}"
        echo -e "  ${WHITE}Данные входа:${NC} ${CYAN}${creds}${NC}"
        echo ""
        echo -e "  ${YELLOW}После входа: настройте Hysteria2 в 'Hysteria Manage',${NC}"
        echo -e "  ${YELLOW}добавьте пользователей в 'Account Manage'${NC}"
        command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'active' && \
            ufw allow "${hui_port}/tcp" > /dev/null 2>&1 && \
            echo -e "  ${GREEN}✓ UFW: ${hui_port}/tcp открыт${NC}"
        log_action "INSTALL: H-UI port=${hui_port}"
    else
        echo -e "\n  ${RED}✗ H-UI не запустился. docker logs h-ui${NC}"
    fi
    read -p "  Enter..."
}

hysteria2_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Hysteria2 ━━━${NC}\n"
        local hy2_port hy2_sni
        hy2_port=$(grep -oP '^listen: :\K[0-9]+' /etc/hysteria/config.yaml 2>/dev/null || echo "?")
        hy2_sni=$(python3 -c "import yaml; c=yaml.safe_load(open('/etc/hysteria/config.yaml')); print(c.get('masquerade',{}).get('proxy',{}).get('url','?').replace('https://',''))" 2>/dev/null || echo "?")

        # Статус сервиса
        if systemctl is-active --quiet hysteria-server; then
            echo -e "  ${WHITE}Статус:${NC} ${GREEN}● запущен${NC}"
        else
            echo -e "  ${WHITE}Статус:${NC} ${RED}● остановлен${NC}"
        fi
        echo -e "  ${WHITE}Порт:${NC}   ${CYAN}${hy2_port}/udp${NC}"
        echo -e "  ${WHITE}SNI:${NC}    ${CYAN}${hy2_sni}${NC}"

        # WARP статус
        if _hy2_warp_running; then
            local wip; wip=$(_hy2_warp_ip)
            echo -e "  ${WHITE}WARP:${NC}   ${GREEN}● ${wip:-подключён}${NC}"
        else
            echo -e "  ${WHITE}WARP:${NC}   ${YELLOW}● не настроен${NC}"
        fi

        # H-UI статус
        local hui_info
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^h-ui$'; then
            local hp; hp=$(docker inspect h-ui 2>/dev/null | python3 -c "import json,sys,re; c=json.load(sys.stdin); cmd=' '.join(c[0].get('Config',{}).get('Cmd',[])); m=re.search(r'-p (\d+)',cmd); print(m.group(1) if m else '8081')" 2>/dev/null || echo "8081")
            hui_info="${GREEN}● http://${MY_IP}:${hp}${NC}"
        else
            hui_info="${YELLOW}● не установлен${NC}"
        fi
        echo -e "  ${WHITE}H-UI:${NC}   ${hui_info}"
        echo ""

        [ -f /root/hysteria2.txt ] && echo -e "  ${WHITE}Ключ (default):${NC}\n  ${CYAN}$(cat /root/hysteria2.txt)${NC}\n"

        echo -e "  ${YELLOW}[1]${NC}  QR-код (default ключ)"
        echo -e "  ${YELLOW}[2]${NC}  Управление пользователями"
        echo -e "  ${YELLOW}[3]${NC}  Установить / открыть H-UI"
        echo -e "  ${YELLOW}[4]${NC}  Настроить WARP"
        echo -e "  ${YELLOW}[5]${NC}  Перезапустить сервис"
        echo -e "  ${YELLOW}[6]${NC}  Лог (30 строк)"
        echo -e "  ${YELLOW}[7]${NC}  Создать бэкап"
        echo -e "  ${YELLOW}[8]${NC}  Переустановить / изменить конфиг"
        echo -e "  ${RED}[x]${NC}  Удалить Hysteria2"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        case "$ch" in
            1)
                [ -f /root/hysteria2.txt ] || { echo -e "  ${YELLOW}Нет ключа${NC}"; read -p "  Enter..."; continue; }
                command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
                echo ""; qrencode -t ANSIUTF8 "$(cat /root/hysteria2.txt)"
                read -p "  Enter..."
                ;;
            2) _hy2_users_menu ;;
            3) _install_hui ;;
            4) _hy2_install_warp ;;
            5)
                echo -ne "  ${YELLOW}Перезапуск...${NC} "
                systemctl restart hysteria-server; sleep 2
                systemctl is-active --quiet hysteria-server && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
                read -p "  Enter..."
                ;;
            6)
                echo ""; journalctl -u hysteria-server -n 30 --no-pager 2>/dev/null || \
                    echo -e "${YELLOW}journalctl недоступен${NC}"
                read -p "  Enter..."
                ;;
            7)
                echo -e "\n  ${CYAN}Создание бэкапа...${NC}"
                do_backup 0
                read -p "  Enter..."
                ;;
            8)
                _install_hysteria2
                systemctl is-active --quiet hysteria-server && HY2_RUNNING=1 || HY2_RUNNING=0
                ;;
            x|X)
                echo -ne "\n  ${RED}Удалить Hysteria2 полностью? (y/n): ${NC}"; read -r c
                [[ "$c" != "y" ]] && continue
                echo -e "  ${CYAN}Создаю бэкап перед удалением...${NC}"
                do_backup 1 > /dev/null 2>&1
                systemctl stop hysteria-server 2>/dev/null || true
                systemctl disable hysteria-server 2>/dev/null || true
                systemctl stop hysteria-warp 2>/dev/null || true
                systemctl disable hysteria-warp 2>/dev/null || true
                wg-quick down "$HY2_WARP_IFACE" 2>/dev/null || true
                rm -f /etc/systemd/system/hysteria-server.service
                rm -f /etc/systemd/system/hysteria-warp.service
                rm -f /usr/local/bin/hysteria
                rm -rf /etc/hysteria
                rm -f /etc/wireguard/${HY2_WARP_IFACE}.conf
                rm -f /root/hysteria2.txt /root/hysteria2_*.txt
                systemctl daemon-reload > /dev/null 2>&1
                HY2_RUNNING=0
                log_action "UNINSTALL: Hysteria2"
                echo -e "  ${GREEN}✓ Hysteria2 удалён${NC}"
                read -p "  Enter..."
                return
                ;;
            0|"") return ;;
        esac
    done
}

#  МАСТЕР УСТАНОВКИ СЕРВЕРОВ
# ═══════════════════════════════════════════════════════════════

# Проверяет/устанавливает Docker
_install_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Docker уже установлен${NC}  $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
        return 0
    fi
    echo -e "  ${YELLOW}Docker не найден — устанавливаю...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://get.docker.com | sh 2>&1 | tail -5
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo -e "  ${GREEN}✓ Docker установлен${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Не удалось установить Docker${NC}"
        return 1
    fi
}

# Установка AmneziaWG
_install_amnezia_awg() {
    clear
    echo -e "\n${CYAN}━━━ Установка AmneziaWG ━━━${NC}\n"

    # Проверка — уже установлен?
    if command -v docker &>/dev/null; then
        local existing
        existing=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i 'amnezia-awg' | head -1)
        if [ -n "$existing" ]; then
            echo -e "  ${YELLOW}Уже установлен контейнер: ${existing}${NC}"
            echo -ne "  Переустановить? (y/n): "; read -r c
            [[ "$c" != "y" ]] && return
            docker stop "$existing" > /dev/null 2>&1
            docker rm "$existing" > /dev/null 2>&1
        fi
    fi

    # Параметры
    local container_name="amnezia-awg2"
    local awg_port subnet

    echo -ne "  Имя контейнера [${container_name}]: "; read -r inp
    [ -n "$inp" ] && container_name="$inp"

    echo -ne "  UDP-порт WireGuard [47684]: "; read -r inp
    awg_port="${inp:-47684}"

    echo -ne "  Подсеть клиентов [10.8.1.0/24]: "; read -r inp
    subnet="${inp:-10.8.1.0/24}"
    local server_ip="${subnet%.*}.1"

    echo ""

    # Docker
    _install_docker || { read -p "  Enter..."; return 1; }

    # Включаем IP forwarding
    echo -e "  ${CYAN}→ IP forwarding...${NC}"
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    grep -q 'net.ipv4.ip_forward' /etc/sysctl.conf 2>/dev/null || \
        echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

    # Генерируем ключи
    echo -e "  ${CYAN}→ Генерация ключей...${NC}"
    local privkey pubkey
    privkey=$(wg genkey 2>/dev/null || docker run --rm lscr.io/linuxserver/wireguard wg genkey 2>/dev/null)
    if [ -z "$privkey" ]; then
        echo -e "  ${RED}✗ Не удалось сгенерировать ключи (нет wg и docker)${NC}"
        read -p "  Enter..."; return 1
    fi
    pubkey=$(echo "$privkey" | wg pubkey 2>/dev/null)

    # Запускаем контейнер
    echo -e "  ${CYAN}→ Запуск контейнера ${container_name}...${NC}"

    local awg_conf_dir="/opt/amnezia/awg"
    mkdir -p "$awg_conf_dir"

    # Создаём начальный конфиг
    cat > "${awg_conf_dir}/awg0.conf" << EOF
[Interface]
PrivateKey = ${privkey}
Address = ${server_ip}/24
ListenPort = ${awg_port}
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -A FORWARD -o awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -D FORWARD -o awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF
    chmod 600 "${awg_conf_dir}/awg0.conf"

    # Создаём пустой clientsTable
    echo '[]' > "${awg_conf_dir}/clientsTable"

    docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        --cap-add NET_ADMIN \
        --cap-add SYS_MODULE \
        --sysctl net.ipv4.ip_forward=1 \
        --sysctl net.ipv4.conf.all.src_valid_mark=1 \
        -p "${awg_port}:${awg_port}/udp" \
        -v "${awg_conf_dir}:/opt/amnezia/awg" \
        -v /lib/modules:/lib/modules:ro \
        ghcr.io/amnezia-vpn/amnezia-wg:latest \
        awg-quick up /opt/amnezia/awg/awg0.conf 2>&1 | tail -3

    sleep 3

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${container_name}$"; then
        echo -e "\n  ${GREEN}✅ AmneziaWG установлен!${NC}"
        echo -e "  ${WHITE}Контейнер:${NC} ${CYAN}${container_name}${NC}"
        echo -e "  ${WHITE}Порт:${NC}      ${CYAN}${awg_port}/udp${NC}"
        echo -e "  ${WHITE}Подсеть:${NC}   ${CYAN}${subnet}${NC}"
        echo -e "  ${WHITE}Pubkey:${NC}    ${CYAN}${pubkey}${NC}"
        log_action "INSTALL: AmneziaWG container=${container_name} port=${awg_port}"

        # Открываем порт в ufw если есть
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'active'; then
            ufw allow "${awg_port}/udp" > /dev/null 2>&1
            echo -e "  ${GREEN}✓ UFW: порт ${awg_port}/udp открыт${NC}"
        fi

        echo -e "\n  ${YELLOW}Перезапустите govpn для определения нового режима.${NC}"
    else
        echo -e "\n  ${RED}✗ Контейнер не запустился. Проверьте: docker logs ${container_name}${NC}"
    fi

    read -p "  Enter..."
}

# Установка 3X-UI
# Установка/обновление roscomvpn geoip+geosite для 3X-UI
_3xui_backup_geofiles() {
    # Создаёт локальный бэкап geofiles и проверяет их работоспособность
    local xray_dir="/usr/local/x-ui/bin"
    local backup_dir="/etc/govpn/geofiles_backup"
    mkdir -p "$backup_dir"

    echo -e "
${CYAN}━━━ Бэкап GeoFiles ━━━${NC}
"

    # Тестируем текущие файлы через xray если доступен
    local xray_bin; xray_bin=$(find /usr/local/x-ui -name "xray" -type f 2>/dev/null | head -1)
    local files_ok=0
    if [ -n "$xray_bin" ] && [ -f "${xray_dir}/geosite.dat" ] && [ -f "${xray_dir}/geoip.dat" ]; then
        # Создаём минимальный тест-конфиг
        local test_cfg; test_cfg=$(mktemp /tmp/xray_test_XXXX.json)
        cat > "$test_cfg" << 'TCFG'
{"routing":{"rules":[{"type":"field","domain":["geosite:category-ru"],"outboundTag":"direct"}]},"outbounds":[{"tag":"direct","protocol":"freedom"}]}
TCFG
        if timeout 5 "$xray_bin" -test -c "$test_cfg" > /dev/null 2>&1; then
            files_ok=1
            echo -e "  ${GREEN}✓ Текущие файлы протестированы — работают${NC}"
        else
            echo -e "  ${YELLOW}⚠ Тест файлов не прошёл (возможно стандартные v2fly)${NC}"
        fi
        rm -f "$test_cfg"
    fi

    if [ -f "${xray_dir}/geosite.dat" ] && [ -f "${xray_dir}/geoip.dat" ]; then
        cp "${xray_dir}/geosite.dat" "${backup_dir}/geosite.dat"
        cp "${xray_dir}/geoip.dat"   "${backup_dir}/geoip.dat"
        echo "$(date '+%Y-%m-%d %H:%M') files_ok=${files_ok}" > "${backup_dir}/meta.txt"
        echo -e "  ${GREEN}✓ Бэкап сохранён: ${backup_dir}${NC}"
    else
        echo -e "  ${RED}✗ Файлы не найдены${NC}"
        read -p "  Enter..." < /dev/tty; return 1
    fi
    read -p "  Enter..." < /dev/tty
}

_3xui_restore_geofiles() {
    local xray_dir="/usr/local/x-ui/bin"
    local backup_dir="/etc/govpn/geofiles_backup"

    echo -e "
${CYAN}Восстановление из бэкапа...${NC}"
    if [ ! -f "${backup_dir}/geosite.dat" ] || [ ! -f "${backup_dir}/geoip.dat" ]; then
        echo -e "  ${RED}✗ Бэкап не найден${NC}"
        read -p "  Enter..." < /dev/tty; return 1
    fi
    local meta; meta=$(cat "${backup_dir}/meta.txt" 2>/dev/null || echo "?")
    echo -e "  ${WHITE}Бэкап:${NC} ${CYAN}${meta}${NC}"
    echo -ne "  Восстановить? (y/n): "
    read -r c < /dev/tty
    [ "$c" != "y" ] && return

    cp "${backup_dir}/geosite.dat" "${xray_dir}/geosite.dat"
    cp "${backup_dir}/geoip.dat"   "${xray_dir}/geoip.dat"
    systemctl restart x-ui > /dev/null 2>&1
    echo -e "  ${GREEN}✓ Восстановлено и xray перезапущен${NC}"
    read -p "  Enter..." < /dev/tty
}

_3xui_qr_happ_urls() {
    command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
    clear
    echo -e "\n${CYAN}━━━ Настройка Happ: roscomvpn маршрутизация ━━━${NC}\n"
    echo -e "  ${WHITE}Шаг 1:${NC} Отсканируй QR — откроется Happ с настройками roscomvpn"
    echo -e "  ${WHITE}Шаг 2:${NC} Нажми Apply / Применить в Happ\n"
    echo "https://routing.help" | qrencode -t ANSIUTF8 2>/dev/null
    echo -e "\n  ${CYAN}https://routing.help${NC}\n"
    echo -e "  ${GREEN}✓${NC} РФ/РБ сайты напрямую"
    echo -e "  ${GREEN}✓${NC} Заблокированные через VPN"
    echo -e "  ${GREEN}✓${NC} Реклама заблокирована"
    echo -e "  ${GREEN}✓${NC} Автообновление правил"
    read -p "  Enter..." < /dev/tty
}


_3xui_export_bypass_list() {
    local custom_file="/etc/govpn/custom_domains.txt"
    clear
    echo -e "\n${CYAN}━━━ Список доменов (bypass) ━━━${NC}\n"

    if [ ! -f "$custom_file" ]; then
        echo -e "  ${YELLOW}Файл не найден. Добавьте домены через [4]${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    # Показываем только домены без direct/proxy
    echo -e "  ${WHITE}Домены (для копирования в Happ):${NC}\n"
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        [ -z "$line" ] && continue
        local domain="${line%% *}"
        [ -n "$domain" ] && echo "  $domain"
    done < "$custom_file"

    echo ""
    read -p "  Enter..." < /dev/tty
}


_3xui_yukikras_info() {
    clear
    echo -e "\n${CYAN}━━━ YukiKras/vless-scripts ━━━${NC}\n"
    echo -e "  ${WHITE}Автор:${NC} YukiKras"
    echo -e "  ${WHITE}Репо:${NC}  ${CYAN}https://github.com/YukiKras/vless-scripts${NC}\n"
    echo -e "  ${WHITE}Скрипты:${NC}"
    echo -e "  ${CYAN}3xinstall.sh${NC}   — установка 3X-UI с настройкой Reality"
    echo -e "  ${CYAN}fakesite.sh${NC}    — установка сайта-заглушки"
    echo -e "  ${CYAN}3xuiportfix.sh${NC} — исправление портов 3X-UI\n"
    echo -e "  ${YELLOW}[1]${NC}  Запустить 3xinstall.sh (установка 3X-UI)"
    echo -e "  ${YELLOW}[2]${NC}  Запустить fakesite.sh (заглушка)"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор: " yk_ch < /dev/tty
    case "$yk_ch" in
        1) bash <(curl -fsSL https://raw.githubusercontent.com/YukiKras/vless-scripts/main/3xinstall.sh) ;;
        2) bash <(curl -fsSL https://raw.githubusercontent.com/YukiKras/vless-scripts/main/fakesite.sh) ;;
    esac
    read -p "  Enter..." < /dev/tty
}



# ═══════════════════════════════════════════════════════════════
#  ПРОВЕРКА КЛИЕНТОВ (IP лимиты + Flow)
# ═══════════════════════════════════════════════════════════════

_xui_check_clients() {
    clear
    echo -e "
${CYAN}━━━ Проверка клиентов x-ui ━━━${NC}
"
    echo -e "  ${YELLOW}Анализирую клиентов...${NC}
"

    cat > /tmp/_xui_check.py << 'PYEOF'
import sqlite3, json, sys
from datetime import datetime

XUIDB = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(XUIDB)
conn.text_factory = lambda b: b.decode("utf-8", errors="surrogateescape")

GREEN  = '[0;32m'
RED    = '[0;31m'
YELLOW = '[1;33m'
CYAN   = '[0;36m'
WHITE  = '[1;37m'
NC     = '[0m'
MAGENTA= '[0;35m'

# Получаем inbound'ы
inbounds = {}
for r in conn.execute("SELECT id, remark, protocol, stream_settings, settings FROM inbounds"):
    ib_id, remark, protocol, stream_s, settings_s = r
    try:
        ss = json.loads(stream_s)
        s  = json.loads(settings_s)
    except:
        continue
    network  = ss.get('network', 'tcp')
    security = ss.get('security', 'none')
    is_reality_tcp = (security == 'reality' and network == 'tcp')
    inbounds[ib_id] = {
        'remark':       remark,
        'protocol':     protocol,
        'is_reality':   is_reality_tcp,
        'clients':      s.get('clients', []),
    }

# IP данные из БД
client_ips = {}
for r in conn.execute("SELECT client_email, ips FROM inbound_client_ips"):
    email, ips_raw = r
    try:
        ips = json.loads(ips_raw) if ips_raw else []
    except:
        ips = []
    client_ips[email] = ips if isinstance(ips, list) else [ips]

# Трафик и last_online
client_stats = {}
for r in conn.execute("SELECT email, up, down, total, expiry_time, enable, last_online FROM client_traffics"):
    email, up, down, total, expiry, enable, last_online = r
    client_stats[email] = {
        'up': up, 'down': down, 'total': total,
        'expiry': expiry, 'enable': bool(enable),
        'last_online': last_online
    }

problems = []
ok_count = 0
total_clients = 0

for ib_id, ib in inbounds.items():
    for client in ib['clients']:
        email     = client.get('email', '?')
        limit_ip  = int(client.get('limitIp') or 0)
        flow      = client.get('flow', '')
        enable    = client.get('enable', True)
        total_clients += 1

        if not enable:
            continue

        ips      = client_ips.get(email, [])
        ip_count = len(ips)
        stats    = client_stats.get(email, {})

        issues  = []
        warns   = []

        # 1. IP лимит превышен
        if limit_ip > 0 and ip_count > limit_ip:
            issues.append(f"IP превышен: {ip_count}/{limit_ip} → {', '.join(ips[:5])}")

        # 2. Flow для Reality TCP
        if ib['is_reality'] and flow != 'xtls-rprx-vision':
            if flow:
                issues.append(f"Flow неверный: '{flow}'  нужен xtls-rprx-vision")
            else:
                issues.append("Flow не задан!  нужен xtls-rprx-vision")

        # 3. Срок истёк
        expiry = stats.get('expiry', 0)
        if expiry and expiry > 0:
            exp_dt = datetime.fromtimestamp(expiry / 1000)
            if exp_dt < datetime.now():
                issues.append(f"Срок истёк: {exp_dt.strftime('%Y-%m-%d')}")
            elif (exp_dt - datetime.now()).days < 3:
                warns.append(f"Срок истекает: {exp_dt.strftime('%Y-%m-%d')}")

        # 4. Лимит трафика
        total_limit = stats.get('total', 0)
        used = stats.get('up', 0) + stats.get('down', 0)
        if total_limit > 0 and used >= total_limit:
            issues.append(f"Трафик исчерпан: {used//1024//1024}МБ / {total_limit//1024//1024}МБ")
        elif total_limit > 0 and used >= total_limit * 0.9:
            warns.append(f"Трафик почти исчерпан: {used*100//total_limit}%")

        if issues or warns:
            problems.append({
                'inbound': ib['remark'],
                'email':   email,
                'issues':  issues,
                'warns':   warns,
                'ips':     ips,
                'limit_ip': limit_ip,
            })
        else:
            ok_count += 1

# Вывод
    print("  Всего клиентов: " + str(total_clients) + "  |  OK: " + str(ok_count) + "  |  Проблем: " + str(len(problems)))
    print()

    if not problems:
        print("  " + GREEN + "OK — нарушений не найдено" + NC)
    else:
        critical = [p for p in problems if p['issues']]
        warnings = [p for p in problems if not p['issues'] and p['warns']]

        if critical:
            print("  " + RED + "Критические проблемы (" + str(len(critical)) + "):" + NC)
            print()
            for p in critical:
                print("  " + RED + "●" + NC + " " + WHITE + p['email'] + NC + "  " + CYAN + "[" + p['inbound'] + "]" + NC)
                for issue in p['issues']:
                    print("    " + RED + "x" + NC + " " + issue)
                if p['warns']:
                    for w in p['warns']:
                        print("    " + YELLOW + "!" + NC + " " + w)
                print()

        if warnings:
            print("  " + YELLOW + "Предупреждения (" + str(len(warnings)) + "):" + NC)
            print()
            for p in warnings:
                print("  " + YELLOW + "!" + NC + " " + WHITE + p['email'] + NC + "  " + CYAN + "[" + p['inbound'] + "]" + NC)
                for w in p['warns']:
                    print("    " + YELLOW + "!" + NC + " " + w)
                print()

    conn.close()
PYEOF
    python3 /tmp/_xui_check.py

    echo ""
    echo -e "  ${WHITE}── Действия ─────────────────────────${NC}"
    echo -e "  ${YELLOW}[f]${NC}  Исправить Flow для Reality клиентов"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    local ch; ch=$(read_choice "Выбор: ")

    case "$ch" in
        f|F|ф|Ф)
            echo -e "
  ${CYAN}Исправляю Flow для Reality клиентов...${NC}"
            systemctl stop x-ui
            sleep 1
            systemctl stop x-ui
            sleep 1
            python3 << PYEOF2
import sqlite3, json
XUIDB = "/etc/x-ui/x-ui.db"
conn = sqlite3.connect(XUIDB, timeout=30)
conn.text_factory = lambda b: b.decode("utf-8", errors="surrogateescape")
fixed = 0
for r in conn.execute("SELECT id, stream_settings, settings FROM inbounds"):
    ib_id, stream_s, settings_s = r
    try:
        ss = json.loads(stream_s)
        s  = json.loads(settings_s)
    except:
        continue
    if not (ss.get("security") == "reality" and ss.get("network") == "tcp"):
        continue
    changed = False
    for client in s.get("clients", []):
        if client.get("flow") != "xtls-rprx-vision":
            client["flow"] = "xtls-rprx-vision"
            changed = True
            fixed += 1
            print("  OK: " + client.get("email","?") + " flow исправлен")
    if changed:
        conn.execute("UPDATE inbounds SET settings=? WHERE id=?", (json.dumps(s), ib_id))
conn.commit()
conn.close()
print("Исправлено: " + str(fixed))
PYEOF2
            rm -f /dev/shm/uds2023.sock 2>/dev/null
            systemctl start x-ui
            sleep 2
            sleep 2
            ;;
    esac
    read -p "  Enter для продолжения..." < /dev/tty
}

# ═══════════════════════════════════════════════════════════════
#  ПЕРЕИМЕНОВАНИЕ INBOUND'ОВ (авто-флаг по выходному IP)
# ═══════════════════════════════════════════════════════════════

# Получить emoji флага по IP через ip-api.com
_get_flag_by_ip() {
    local ip="$1"
    python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://ip-api.com/json/${ip}?fields=countryCode', timeout=5)
    d = json.loads(r.read())
    cc = d.get('countryCode','')
    # Конвертируем код страны в emoji флага
    flag = ''.join(chr(0x1F1E0 + ord(c) - ord('A')) for c in cc.upper()) if len(cc)==2 else '🌐'
    print(flag)
except: print('🌐')
" 2>/dev/null
}

# Определить протокол inbound по network/protocol
_get_proto_label() {
    local protocol="$1"
    local network="$2"
    local remark="$3"

    case "$network" in
        tcp)
            if [[ "$protocol" == "trojan" ]]; then
                echo "TCP(trojan)"
            else
                echo "TCP"
            fi
            ;;
        xhttp) echo "xHTTP" ;;
        grpc)
            if echo "$remark" | grep -qi "trojan"; then
                echo "gRCP(trojan)"
            else
                echo "gRCP"
            fi
            ;;
        ws)   echo "WS" ;;
        h2)   echo "H2" ;;
        quic) echo "QUIC" ;;
        *)    echo "$network" ;;
    esac
}

# Определить выходной IP для inbound через xray outbound
_get_inbound_exit_ip() {
    local inbound_tag="$1"
    # Смотрим routing правила
    local outbound_tag
    outbound_tag=$(python3 -c "
import json
try:
    d = json.load(open('/usr/local/x-ui/bin/config.json'))
    for r in d.get('routing',{}).get('rules',[]):
        tags = r.get('inboundTag', [])
        if '${inbound_tag}' in tags:
            print(r.get('outboundTag','direct'))
            break
    else:
        print('direct')
except: print('direct')
" 2>/dev/null)

    # Определяем IP для каждого outbound
    case "$outbound_tag" in
        direct|"")
            # Прямой выход — IP сервера
            echo "$MY_IP"
            ;;
        *[Ww][Aa][Rr][Pp]*|*warp*)
            # WARP — Cloudflare IP
            curl -s --max-time 5 --interface warp https://ifconfig.me 2>/dev/null ||             curl -s --max-time 5 --proxy socks5://127.0.0.1:40000 https://ifconfig.me 2>/dev/null ||             echo "104.28.0.1"
            ;;
        *[Bb]ridge*|*bridge*)
            # Bridge — IP удалённого сервера
            python3 -c "
import json
try:
    d = json.load(open('/usr/local/x-ui/bin/config.json'))
    for o in d.get('outbounds',[]):
        if o.get('tag','') == '${outbound_tag}':
            addr = o.get('settings',{}).get('address','')
            # Резолвим домен если нужно
            import socket
            try:
                ip = socket.gethostbyname(addr)
                print(ip)
            except:
                print(addr)
            break
except: print('')
" 2>/dev/null
            ;;
        *)
            echo "$MY_IP"
            ;;
    esac
}

# Проверить является ли IP адресом WARP/Cloudflare
_is_warp_ip() {
    local ip="$1"
    # Cloudflare диапазоны: 104.16.0.0/12, 172.64.0.0/13, 162.158.0.0/15
    python3 -c "
import ipaddress
try:
    ip = ipaddress.ip_address('${ip}')
    warp_ranges = ['104.16.0.0/12', '172.64.0.0/13', '162.158.0.0/15',
                   '104.24.0.0/14', '198.41.128.0/17']
    for r in warp_ranges:
        if ip in ipaddress.ip_network(r):
            print('yes'); exit()
    print('no')
except: print('no')
" 2>/dev/null
}

# Переименовать один inbound
_xui_rename_one() {
    local ib_id="$1"
    local exit_ip="$2"  # если пустой — определяем автоматически

    python3 << PYEOF
import sqlite3, json, subprocess, sys

XUIDB = '/etc/x-ui/x-ui.db'
conn = sqlite3.connect(XUIDB, timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')

row = conn.execute('SELECT id, remark, port, protocol, stream_settings, tag FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
if not row:
    print("Inbound не найден"); conn.close(); exit(1)

ib_id, remark, port, protocol, stream_s, tag = row
ss = json.loads(stream_s)
network = ss.get('network', 'tcp')

# Протокол
if network == 'tcp' and protocol == 'trojan':
    proto = 'TCP(trojan)'
elif network == 'tcp':
    proto = 'TCP'
elif network == 'xhttp':
    proto = 'xHTTP'
elif network == 'grpc':
    proto = 'gRCP(trojan)' if 'trojan' in remark.lower() else 'gRCP'
elif network == 'ws':
    proto = 'WS'
else:
    proto = network.upper()

print(f"id={ib_id} proto={proto} network={network} tag={tag}")
conn.close()
PYEOF

    if [ $? -ne 0 ]; then return 1; fi

    # Получаем exit IP
    local tag; tag=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
r = conn.execute('SELECT tag FROM inbounds WHERE id=${ib_id}').fetchone()
print(r[0] if r else '')
conn.close()
" 2>/dev/null)

    if [ -z "$exit_ip" ]; then
        exit_ip=$(_get_inbound_exit_ip "$tag")
    fi

    local flag; flag=$(_get_flag_by_ip "$exit_ip")
    local is_warp; is_warp=$(_is_warp_ip "$exit_ip")

    # Получаем протокол
    local proto; proto=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT remark, protocol, stream_settings FROM inbounds WHERE id=${ib_id}').fetchone()
if not row: conn.close(); exit()
remark, protocol, stream_s = row
ss = json.loads(stream_s)
network = ss.get('network','tcp')
if network == 'tcp' and protocol == 'trojan': print('TCP(trojan)')
elif network == 'tcp': print('TCP')
elif network == 'xhttp': print('xHTTP')
elif network == 'grpc': print('gRCP(trojan)' if 'trojan' in remark.lower() else 'gRCP')
elif network == 'ws': print('WS')
else: print(network.upper())
conn.close()
" 2>/dev/null)

    # Формируем новый remark
    local new_remark
    if [ "$is_warp" = "yes" ]; then
        new_remark="${flag} ${proto}(warp)-_"
    else
        new_remark="${flag} ${proto}-_"
    fi

    echo -e "  ${CYAN}#${ib_id}${NC}: ${WHITE}→${NC} ${GREEN}${new_remark}${NC}  ${YELLOW}(exit: ${exit_ip})${NC}"

    # Обновляем в БД
    systemctl stop x-ui
    sleep 1
    python3 -c "
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
conn.execute('UPDATE inbounds SET remark=? WHERE id=?', ('${new_remark}', ${ib_id}))
conn.commit()
conn.close()
print('OK')
" 2>/dev/null
    rm -f /dev/shm/uds2023.sock 2>/dev/null
    systemctl start x-ui
}

# Переименовать все inbound'ы
_xui_rename_all() {
    clear
    echo -e "
${CYAN}━━━ Автопереименование inbound'ов ━━━${NC}
"
    echo -e "  ${YELLOW}Определяю выходные IP для каждого inbound...${NC}
"

    # Получаем список всех inbound'ов
    local ids; ids=$(python3 -c "
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
for r in conn.execute('SELECT id FROM inbounds ORDER BY id'):
    print(r[0])
conn.close()
" 2>/dev/null)

    local first_restart=true
    for ib_id in $ids; do
        local tag; tag=$(python3 -c "
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
r = conn.execute('SELECT tag FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
print(r[0] if r else '')
conn.close()
" 2>/dev/null)
        local exit_ip; exit_ip=$(_get_inbound_exit_ip "$tag")
        local flag; flag=$(_get_flag_by_ip "$exit_ip")
        local is_warp; is_warp=$(_is_warp_ip "$exit_ip")

        local proto; proto=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT remark, protocol, stream_settings FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
if not row: conn.close(); exit()
remark, protocol, stream_s = row
ss = json.loads(stream_s)
network = ss.get('network','tcp')
if network == 'tcp' and protocol == 'trojan': print('TCP(trojan)')
elif network == 'tcp': print('TCP')
elif network == 'xhttp': print('xHTTP')
elif network == 'grpc': print('gRCP(trojan)' if 'trojan' in remark.lower() else 'gRCP')
elif network == 'ws': print('WS')
else: print(network.upper())
conn.close()
" 2>/dev/null)

        local new_remark
        if [ "$is_warp" = "yes" ]; then
            new_remark="${flag} ${proto}(warp)-_"
        else
            new_remark="${flag} ${proto}-_"
        fi

        echo -e "  ${CYAN}#${ib_id}${NC}: ${new_remark}  ${YELLOW}← ${exit_ip}${NC}"

        python3 -c "
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
conn.execute('UPDATE inbounds SET remark=? WHERE id=?', ('${new_remark}', ${ib_id}))
conn.commit()
conn.close()
" 2>/dev/null
    done

    echo ""
    rm -f /dev/shm/uds2023.sock 2>/dev/null
    systemctl restart x-ui
    sleep 2
    echo -e "  ${GREEN}✓ Все inbound'ы переименованы${NC}"
    read -p "  Enter для продолжения..." < /dev/tty
}

# Меню переименования
_xui_rename_menu() {
    while true; do
        clear
        echo -e "
${CYAN}━━━ Переименование inbound'ов ━━━${NC}
"

        # Показываем текущие
        python3 << 'PYEOF' 2>/dev/null
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute("SELECT id, remark, port, listen FROM inbounds ORDER BY id").fetchall()
for idx, (ib_id, remark, port, listen) in enumerate(rows, 1):
    loc = f":{port}" if port else "UDS"
    print(f"  [{idx}] #{ib_id} {remark}  {loc}")
conn.close()
PYEOF

        echo ""
        echo -e "  ${YELLOW}[a]${NC}  Переименовать все автоматически"
        echo -e "  ${YELLOW}[номер]${NC}  Переименовать один inbound"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            0|"") return ;;
            a|A|а|А) _xui_rename_all ;;
            *)
                # Выбор по порядковому номеру
                local ib_id; ib_id=$(python3 -c "
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute('SELECT id FROM inbounds ORDER BY id').fetchall()
idx = ${ch} - 1
print(rows[idx][0] if 0 <= idx < len(rows) else '')
conn.close()
" 2>/dev/null)
                [ -n "$ib_id" ] && _xui_rename_one "$ib_id" ""
                sleep 2
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  СОЗДАНИЕ INBOUND'ОВ (x-ui-pro структура)
# ═══════════════════════════════════════════════════════════════

XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
XUIDB_PATH="/etc/x-ui/x-ui.db"

# Генерация Reality ключей через xray
_xui_gen_reality_keys() {
    local output; output=$("$XRAY_BIN" x25519 2>/dev/null)
    REALITY_PRIVATE=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    REALITY_PUBLIC=$(echo "$output" | grep "^Password" | awk '{print $3}')
}

# Генерация UUID через xray
_xui_gen_uuid() {
    "$XRAY_BIN" uuid 2>/dev/null | tr -d '[:space:]'
}

# Получить emoji флаг страны
_xui_get_flag() {
    curl -s --max-time 5 https://ipwho.is/ 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(d.get('flag',{}).get('emoji','🌐'))" 2>/dev/null || echo "🌐"
}

# Получить домен из существующего inbound
_xui_get_domain() {
    python3 -c "
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT stream_settings FROM inbounds LIMIT 1').fetchone()
if row:
    ss = json.loads(row[0])
    ext = ss.get('externalProxy', [{}])
    if ext: print(ext[0].get('dest',''))
conn.close()
" 2>/dev/null
}

# Получить Reality настройки из основного inbound (port 8443)
_xui_get_reality_settings() {
    python3 -c "
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT stream_settings FROM inbounds WHERE port=8443').fetchone()
if row:
    ss = json.loads(row[0])
    rs = ss.get('realitySettings', {})
    print(rs.get('privateKey',''))
    print(rs.get('settings',{}).get('publicKey',''))
    print(rs.get('serverNames',[''])[0])
    print(rs.get('target','127.0.0.1:9443'))
conn.close()
" 2>/dev/null
}

# Создать inbound в БД с остановкой x-ui
_xui_db_insert() {
    local remark="$1" port="$2" listen="$3" protocol="$4" settings="$5" stream="$6" tag="$7" sniffing="$8"
    systemctl stop x-ui
    sleep 1
    rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
conn.execute("DELETE FROM inbounds WHERE port=? AND port!=0", (${port},)) if ${port} != 0 else None
conn.execute("""
    INSERT INTO inbounds
        (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
    VALUES (1,0,0,0,?,1,0,?,?,'${protocol}',?,?,?,?)
""", ('${remark}', '${listen}', ${port}, '''${settings}''', '''${stream}''', '${tag}', '''${sniffing}'''))
conn.commit()
conn.close()
print("OK")
PYEOF
    systemctl start x-ui
    sleep 3
}

# Генерация ссылки для клиента
_xui_gen_link() {
    local port="$1"
    python3 << PYEOF
import sqlite3, json
from urllib.parse import urlencode
conn = sqlite3.connect('${XUIDB_PATH}')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT settings, stream_settings FROM inbounds WHERE port=?', (${port},)).fetchone()
if not row:
    print("Inbound не найден"); conn.close(); exit()
s = json.loads(row[0])
ss = json.loads(row[1])
uid = s['clients'][0]['id']
net = ss.get('network')
sec = ss.get('security')
ext = ss.get('externalProxy', [{}])[0]
host = ext.get('dest','')
eport = ext.get('port', 443)
rs = ss.get('realitySettings', {})
params = {'type': net, 'security': sec}
if sec == 'reality':
    params['pbk'] = rs.get('settings',{}).get('publicKey','')
    params['sid'] = rs.get('shortIds',[''])[0]
    params['sni'] = rs.get('serverNames',[''])[0]
    params['fp'] = 'chrome'
if net == 'tcp':
    params['flow'] = 'xtls-rprx-vision'
if net == 'xhttp':
    params['path'] = ss.get('xhttpSettings',{}).get('path','/')
link = f"vless://{uid}@{host}:{eport}?{urlencode(params)}#inbound-{${port}}"
print(link)
conn.close()
PYEOF
}

# Добавить iptables REDIRECT для inbound
_xui_add_redirect() {
    local target_port="$1"
    echo ""
    echo -e "  ${CYAN}Добавить iptables REDIRECT на порт ${target_port}?${NC}"
    echo -e "  ${WHITE}Клиенты смогут подключаться через диапазон портов → ${target_port}${NC}"
    echo -ne "  Добавить редирект? (y/n): "; read -r add_redir < /dev/tty
    [[ "$add_redir" != "y" ]] && return

    echo -ne "  Протокол (tcp/udp/both) [tcp]: "; read -r proto < /dev/tty
    proto="${proto:-tcp}"
    echo -ne "  Диапазон портов (например 25400:25500): "; read -r dport_range < /dev/tty
    [[ -z "$dport_range" ]] && return

    if [[ "$proto" == "both" ]]; then
        iptables -t nat -A PREROUTING -p tcp --dport "$dport_range" -j REDIRECT --to-port "$target_port" 2>/dev/null
        iptables -t nat -A PREROUTING -p udp --dport "$dport_range" -j REDIRECT --to-port "$target_port" 2>/dev/null
    else
        iptables -t nat -A PREROUTING -p "$proto" --dport "$dport_range" -j REDIRECT --to-port "$target_port" 2>/dev/null
    fi

    ufw allow "$dport_range/$proto" 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    echo -e "  ${GREEN}✓ Редирект ${proto}:${dport_range} → ${target_port} добавлен${NC}"
}

# Создать Reality TCP inbound (по образцу x-ui-pro)
_xui_create_reality_tcp() {
    clear
    echo -e "\n${CYAN}━━━ Создание Reality TCP inbound ━━━${NC}\n"

    # Читаем параметры из существующего 8443
    local rs_params; rs_params=$(_xui_get_reality_settings)
    local exist_privkey exist_pubkey exist_sni exist_target
    exist_privkey=$(echo "$rs_params" | sed -n '1p')
    exist_pubkey=$(echo  "$rs_params" | sed -n '2p')
    exist_sni=$(echo     "$rs_params" | sed -n '3p')
    exist_target=$(echo  "$rs_params" | sed -n '4p')

    local domain; domain=$(_xui_get_domain)
    domain="${domain:-your-domain.com}"

    echo -e "  ${WHITE}Домен:${NC} ${CYAN}${domain}${NC}"
    echo -e "  ${WHITE}SNI (Reality target domain):${NC} ${CYAN}${exist_sni}${NC}"
    echo -e "  ${WHITE}Target:${NC} ${CYAN}${exist_target}${NC}\n"

    echo -e "  ${YELLOW}Режим ключей:${NC}"
    echo -e "  ${WHITE}[1]${NC}  Использовать ключи от inbound 8443 (рекомендуется — nginx балансирует)"
    echo -e "  ${WHITE}[2]${NC}  Генерировать новые ключи (нужен отдельный nginx маршрут)"
    echo ""
    local key_mode; key_mode=$(read_choice "Выбор [1]: ")
    key_mode="${key_mode:-1}"

    local privkey pubkey
    if [[ "$key_mode" == "2" ]]; then
        _xui_gen_reality_keys
        privkey="$REALITY_PRIVATE"
        pubkey="$REALITY_PUBLIC"
        echo -e "  ${GREEN}✓ Новые ключи сгенерированы${NC}"
    else
        privkey="$exist_privkey"
        pubkey="$exist_pubkey"
        echo -e "  ${GREEN}✓ Используем ключи от 8443${NC}"
    fi

    echo -ne "\n  Порт для нового inbound [14444]: "; read -r new_port < /dev/tty
    new_port="${new_port:-14444}"

    echo -ne "  Email клиента [user1]: "; read -r email < /dev/tty
    email="${email:-user1}"

    local client_id; client_id=$(_xui_gen_uuid)
    local ts; ts=$(date +%s%3N)
    local flag; flag=$(_xui_get_flag)

    # Генерируем уникальные shortIds (16 символов каждый)
    local short_ids=()
    for i in {1..8}; do
        short_ids+=("$(openssl rand -hex 8)")
    done
    local sids_json; sids_json=$(printf '"%s",' "${short_ids[@]}" | sed 's/,$//')

    local settings='{
  "clients": [{
    "id": "'"$client_id"'",
    "flow": "xtls-rprx-vision",
    "email": "'"$email"'",
    "limitIp": 0,
    "totalGB": 0,
    "expiryTime": 0,
    "enable": true,
    "tgId": "",
    "subId": "first",
    "reset": 0,
    "created_at": '"$ts"',
    "updated_at": '"$ts"'
  }],
  "decryption": "none",
  "fallbacks": []
}'

    local stream='{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [{"forceTls": "same", "dest": "'"$domain"'", "port": 443, "remark": ""}],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "'"$exist_target"'",
    "serverNames": ["'"$exist_sni"'"],
    "privateKey": "'"$privkey"'",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": ['"$sids_json"'],
    "settings": {
      "publicKey": "'"$pubkey"'",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {"acceptProxyProtocol": true, "header": {"type": "none"}}
}'

    local sniffing='{"enabled": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false, "routeOnly": false}'

    echo -e "\n  ${CYAN}Создаём inbound...${NC}"

    systemctl stop x-ui; sleep 1; rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
conn.execute("DELETE FROM inbounds WHERE port=?", (${new_port},))
conn.execute("""INSERT INTO inbounds
    (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
    VALUES (1,0,0,0,?,1,0,'',?,'vless',?,?,?,?)""",
    ('${flag} reality', ${new_port}, '''${settings}''', '''${stream}''', 'inbound-${new_port}', '''${sniffing}'''))
conn.commit(); conn.close(); print("OK")
PYEOF

    systemctl start x-ui; sleep 3

    if ss -tlnp | grep -q ":${new_port}"; then
        echo -e "  ${GREEN}✓ Inbound создан, порт ${new_port} слушает${NC}"
    else
        echo -e "  ${RED}✗ Порт ${new_port} не поднялся — проверь логи: journalctl -u x-ui -n 20${NC}"
    fi

    # Если использовали те же ключи — добавить в nginx upstream
    if [[ "$key_mode" == "1" ]]; then
        echo -e "\n  ${YELLOW}Добавить ${new_port} в nginx upstream xray (балансировка с 8443)?${NC}"
        echo -ne "  (y/n): "; read -r add_nginx < /dev/tty
        if [[ "$add_nginx" == "y" ]]; then
            if ! grep -q "127.0.0.1:${new_port}" /etc/nginx/stream-enabled/stream.conf 2>/dev/null; then
                sed -i "s|server 127.0.0.1:8443;|server 127.0.0.1:8443;\n    server 127.0.0.1:${new_port};|" \
                    /etc/nginx/stream-enabled/stream.conf
                nginx -t && systemctl reload nginx && \
                    echo -e "  ${GREEN}✓ nginx обновлён — балансировка 8443 + ${new_port}${NC}"
            else
                echo -e "  ${YELLOW}Уже добавлен в nginx${NC}"
            fi
        fi
    fi

    # Предложить iptables редирект
    _xui_add_redirect "$new_port"

    # Ссылка
    echo -e "\n  ${WHITE}VLESS ссылка:${NC}"
    local link="vless://${client_id}@${domain}:443?type=tcp&security=reality&pbk=${pubkey}&sid=${short_ids[0]}&sni=${exist_sni}&fp=chrome&flow=xtls-rprx-vision#reality-${new_port}"
    echo -e "  ${CYAN}${link}${NC}"
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}

# Создать xHTTP inbound (по образцу x-ui-pro — через Unix socket)
_xui_create_xhttp() {
    clear
    echo -e "\n${CYAN}━━━ Создание xHTTP inbound ━━━${NC}\n"

    local domain; domain=$(_xui_get_domain)
    domain="${domain:-your-domain.com}"

    # Проверяем nginx конфиг — есть ли уже настроенный path для xHTTP
    local xhttp_path
    local nginx_xhttp_path
    nginx_xhttp_path=$(grep -r "grpc_pass.*uds2023\|proxy_pass.*uds2023" /etc/nginx/ 2>/dev/null |         grep -oP "location \K/[a-zA-Z0-9]+" | head -1)
    if [ -n "$nginx_xhttp_path" ]; then
        xhttp_path="${nginx_xhttp_path#/}"
        echo -e "  ${GREEN}✓ Найден path из nginx: ${nginx_xhttp_path}${NC}"
    else
        xhttp_path=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)
    fi
    local client_id; client_id=$(_xui_gen_uuid)
    local ts; ts=$(date +%s%3N)
    local flag; flag=$(_xui_get_flag)

    echo -e "  ${WHITE}Домен:${NC} ${CYAN}${domain}${NC}"
    echo -e "  ${WHITE}Path:${NC}  ${CYAN}/${xhttp_path}${NC}\n"
    echo -ne "  Email клиента [xhttp-user]: "; read -r email < /dev/tty
    email="${email:-xhttp-user}"

    local settings='{
  "clients": [{
    "id": "'"$client_id"'",
    "flow": "",
    "email": "'"$email"'",
    "limitIp": 0,
    "totalGB": 0,
    "expiryTime": 0,
    "enable": true,
    "tgId": "",
    "subId": "first",
    "reset": 0,
    "created_at": '"$ts"',
    "updated_at": '"$ts"'
  }],
  "decryption": "none",
  "fallbacks": []
}'

    local stream='{
  "network": "xhttp",
  "security": "none",
  "externalProxy": [{"forceTls": "tls", "dest": "'"$domain"'", "port": 443, "remark": ""}],
  "xhttpSettings": {
    "path": "/'"$xhttp_path"'",
    "host": "'"$domain"'",
    "headers": {},
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "mode": "packet-up"
  },
  "sockopt": {
    "acceptProxyProtocol": false,
    "tcpFastOpen": true,
    "mark": 0,
    "tproxy": "off",
    "tcpMptcp": true,
    "tcpNoDelay": true,
    "domainStrategy": "UseIP",
    "tcpMaxSeg": 1440,
    "dialerProxy": "",
    "tcpKeepAliveInterval": 0,
    "tcpKeepAliveIdle": 300,
    "tcpUserTimeout": 10000,
    "tcpcongestion": "bbr",
    "V6Only": false,
    "tcpWindowClamp": 600,
    "interface": ""
  }
}'

    local sniffing='{"enabled": true, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false, "routeOnly": false}'
    local sock="/dev/shm/uds2023.sock,0666"
    local tag="inbound-/dev/shm/uds2023.sock,0666:0|"

    echo -e "  ${CYAN}Создаём xHTTP inbound через Unix socket...${NC}"

    systemctl stop x-ui; sleep 1; rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
# Удаляем старый xhttp если есть
conn.execute("DELETE FROM inbounds WHERE listen='/dev/shm/uds2023.sock,0666'")
conn.execute("""INSERT INTO inbounds
    (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
    VALUES (1,0,0,0,?,1,0,?,0,'vless',?,?,?,?)""",
    ('${flag} xhttp', '/dev/shm/uds2023.sock,0666', '''${settings}''', '''${stream}''',
     'inbound-/dev/shm/uds2023.sock,0666:0|', '''${sniffing}'''))
conn.commit(); conn.close(); print("OK")
PYEOF

    systemctl start x-ui; sleep 3

    if [ -S "/dev/shm/uds2023.sock" ]; then
        echo -e "  ${GREEN}✓ xHTTP inbound создан, Unix socket активен${NC}"
    else
        echo -e "  ${YELLOW}Socket не найден — проверь: journalctl -u x-ui -n 20${NC}"
    fi

    echo -e "\n  ${WHITE}Клиент подключается через:${NC}"
    echo -e "  ${CYAN}https://${domain}//${xhttp_path}${NC}"
    echo -e "\n  ${WHITE}VLESS ссылка:${NC}"
    echo -e "  ${CYAN}vless://${client_id}@${domain}:443?type=xhttp&security=tls&path=/${xhttp_path}&host=${domain}#xhttp${NC}"
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}

# Создать gRPC inbound
_xui_create_grpc() {
    clear
    echo -e "\n${CYAN}━━━ Создание gRPC inbound ━━━${NC}\n"
    echo -e "  ${YELLOW}⚠ gRPC deprecated в новых версиях Xray — рекомендуется xHTTP${NC}\n"

    local domain; domain=$(_xui_get_domain)
    domain="${domain:-your-domain.com}"

    local svc_name; svc_name=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)
    local client_id; client_id=$(_xui_gen_uuid)
    local ts; ts=$(date +%s%3N)
    local flag; flag=$(_xui_get_flag)

    echo -ne "  Порт [$(shuf -i 20000-40000 -n 1)]: "; read -r new_port < /dev/tty
    new_port="${new_port:-28077}"
    echo -ne "  Email клиента [grpc-user]: "; read -r email < /dev/tty
    email="${email:-grpc-user}"

    local settings='{
  "clients": [{
    "id": "'"$client_id"'",
    "flow": "",
    "email": "'"$email"'",
    "limitIp": 0,
    "totalGB": 0,
    "expiryTime": 0,
    "enable": true,
    "tgId": "",
    "subId": "first",
    "reset": 0,
    "created_at": '"$ts"',
    "updated_at": '"$ts"'
  }],
  "decryption": "none",
  "fallbacks": []
}'

    local stream='{
  "network": "grpc",
  "security": "none",
  "externalProxy": [{"forceTls": "tls", "dest": "'"$domain"'", "port": 443, "remark": ""}],
  "grpcSettings": {
    "serviceName": "/'"$svc_name"'",
    "multiMode": false,
    "idle_timeout": 60,
    "health_check_timeout": 20,
    "permit_without_stream": false,
    "initial_windows_size": 0
  }
}'

    local sniffing='{"enabled": false, "destOverride": ["http","tls","quic","fakedns"], "metadataOnly": false, "routeOnly": false}'

    echo -e "  ${CYAN}Создаём gRPC inbound...${NC}"
    systemctl stop x-ui; sleep 1; rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
conn.execute("DELETE FROM inbounds WHERE port=?", (${new_port},))
conn.execute("""INSERT INTO inbounds
    (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing)
    VALUES (1,0,0,0,?,1,0,'',?,'vless',?,?,?,?)""",
    ('${flag} grpc', ${new_port}, '''${settings}''', '''${stream}''', 'inbound-${new_port}', '''${sniffing}'''))
conn.commit(); conn.close(); print("OK")
PYEOF

    systemctl start x-ui; sleep 3

    if ss -tlnp | grep -q ":${new_port}"; then
        echo -e "  ${GREEN}✓ gRPC inbound создан, порт ${new_port} слушает${NC}"
    else
        echo -e "  ${RED}✗ Порт ${new_port} не поднялся${NC}"
    fi

    _xui_add_redirect "$new_port"
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}

# Главное меню управления inbound'ами
_3xui_inbound_templates() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Управление inbound'ами (x-ui-pro) ━━━${NC}\n"

        # Показываем текущие inbound'ы с порядковой нумерацией
        python3 << 'PYEOF' 2>/dev/null
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute("SELECT id, remark, port, listen, enable FROM inbounds ORDER BY id").fetchall()
for idx, r in enumerate(rows, 1):
    ib_id, remark, port, listen, enable = r
    status = "\033[32m✓\033[0m" if enable else "\033[31m✗\033[0m"
    loc = f":{port}" if port else "UDS"
    print(f"  {status} [{idx}] {remark:<30} {loc}")
conn.close()
PYEOF

        echo ""
        echo -e "  ${WHITE}── Создать ─────────────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  Reality TCP  ${GREEN}(самый скрытный)${NC}"
        echo -e "  ${YELLOW}[2]${NC}  xHTTP        ${CYAN}(через Unix socket → nginx)${NC}"
        echo -e "  ${YELLOW}[3]${NC}  gRPC         ${YELLOW}(deprecated, но работает)${NC}"
        echo -e "  ${WHITE}── Управление ──────────────────────${NC}"
        echo -e "  ${CYAN}[4]${NC}  Добавить клиента в inbound"
        echo -e "  ${CYAN}[5]${NC}  Показать ссылки inbound'а"
        echo -e "  ${YELLOW}[7]${NC}  Диагностика и починка inbound'а"
        echo -e "  ${RED}[6]${NC}  Удалить inbound"
        echo -e "  ${YELLOW}[r]${NC}  Переименовать inbound'ы (авто-флаг)"
        echo -e "  ${CYAN}[c]${NC}  Проверить клиентов (IP лимиты + Flow)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1) _xui_create_reality_tcp ;;
            2) _xui_create_xhttp ;;
            3) _xui_create_grpc ;;
            4) _xui_add_client_to_existing ;;
            5) _xui_show_links ;;
            6) _xui_delete_inbound ;;
            7) _xui_diagnose_fix ;;
            r|R|р|Р) _xui_rename_menu ;;
            c|C|с|С) _xui_check_clients ;;
            0|"") return ;;
        esac
    done
}

# Добавить клиента в существующий inbound
_xui_add_client_to_existing() {
    clear
    echo -e "\n${CYAN}━━━ Добавить клиента в inbound ━━━${NC}\n"

    # Список inbound'ов с порядковой нумерацией
    local inbounds_raw; inbounds_raw=$(python3 -c "
import sqlite3
conn = sqlite3.connect('${XUIDB_PATH}')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute('SELECT id, remark, port FROM inbounds ORDER BY id').fetchall()
for idx, r in enumerate(rows, 1):
    print(f'{idx}|{r[0]}|{r[1]}|{r[2]}')
conn.close()
" 2>/dev/null)

    echo "$inbounds_raw" | while IFS='|' read -r num id remark port; do
        local loc="${port:-UDS}"
        echo -e "  ${YELLOW}[${num}]${NC}  ${remark} :${loc}  ${WHITE}(id:${id})${NC}"
    done
    echo ""
    echo -ne "  Номер inbound'а: "; read -r ib_num < /dev/tty
    [[ -z "$ib_num" ]] && return
    local ib_id; ib_id=$(echo "$inbounds_raw" | awk -F'|' -v n="$ib_num" '$1==n{print $2}')
    [[ -z "$ib_id" ]] && { echo -e "  ${RED}Неверный номер${NC}"; sleep 2; return; }

    echo -ne "  Email нового клиента: "; read -r email < /dev/tty
    [[ -z "$email" ]] && return

    local client_id; client_id=$(_xui_gen_uuid)
    local ts; ts=$(date +%s%3N)

    systemctl stop x-ui; sleep 1; rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3, json
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT settings, stream_settings FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
if not row:
    print("Inbound не найден"); conn.close(); exit()
s = json.loads(row[0])
ss = json.loads(row[1])
net = ss.get('network', 'tcp')
flow = 'xtls-rprx-vision' if net == 'tcp' and ss.get('security') == 'reality' else ''
s['clients'].append({
    'id': '${client_id}',
    'flow': flow,
    'email': '${email}',
    'limitIp': 0,
    'totalGB': 0,
    'expiryTime': 0,
    'enable': True,
    'tgId': '',
    'subId': 'first',
    'reset': 0,
    'created_at': ${ts},
    'updated_at': ${ts}
})
conn.execute('UPDATE inbounds SET settings=? WHERE id=?', (json.dumps(s), ${ib_id}))
conn.commit(); conn.close()
print(f"OK! UUID: ${client_id}")
PYEOF

    systemctl start x-ui; sleep 2
    echo -e "  ${GREEN}✓ Клиент ${email} добавлен${NC}"
    echo -e "  ${WHITE}UUID: ${CYAN}${client_id}${NC}"
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}

# Показать ссылки для inbound'а
_xui_show_links() {
    clear
    echo -e "\n${CYAN}━━━ Ссылки inbound'а ━━━${NC}\n"

    python3 << 'PYEOF'
import sqlite3, json
from urllib.parse import urlencode
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute("SELECT id, remark, port FROM inbounds ORDER BY id").fetchall()
for r in rows:
    print(f"  [{r[0]}] {r[1]} :{r[2]}")
conn.close()
PYEOF
    echo ""
    echo -ne "  ID inbound'а: "; read -r ib_id < /dev/tty
    [[ -z "$ib_id" ]] && return

    python3 << PYEOF
import sqlite3, json
from urllib.parse import urlencode
conn = sqlite3.connect('${XUIDB_PATH}')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT settings, stream_settings FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
if not row:
    print("Inbound не найден"); conn.close(); exit()
s = json.loads(row[0])
ss = json.loads(row[1])
net = ss.get('network','tcp')
sec = ss.get('security','none')
ext = ss.get('externalProxy', [{}])[0]
host = ext.get('dest','')
eport = ext.get('port', 443)
rs = ss.get('realitySettings', {})
for c in s.get('clients', []):
    uid = c['id']
    email = c.get('email','')
    params = {'type': net, 'security': sec}
    if sec == 'reality':
        params['pbk'] = rs.get('settings',{}).get('publicKey','')
        params['sid'] = rs.get('shortIds',[''])[0]
        params['sni'] = rs.get('serverNames',[''])[0]
        params['fp'] = 'chrome'
    if net == 'tcp':
        params['flow'] = 'xtls-rprx-vision'
    if net == 'xhttp':
        xhs = ss.get('xhttpSettings',{})
        params['path'] = xhs.get('path','/')
        params['host'] = xhs.get('host','')
    link = f"vless://{uid}@{host}:{eport}?{urlencode(params)}#{email}"
    print(f"\n  [{email}]")
    print(f"  {link}")
conn.close()
PYEOF
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}


# Диагностика и автопочинка inbound'а
_xui_diagnose_fix() {
    clear
    echo -e "\n${CYAN}━━━ Диагностика и починка inbound'а ━━━${NC}\n"

    # Список inbound'ов с порядковой нумерацией
    local rows_data; rows_data=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
rows = conn.execute('SELECT id, remark, port, listen, enable FROM inbounds ORDER BY id').fetchall()
for idx, r in enumerate(rows, 1):
    ib_id, remark, port, listen, enable = r
    loc = str(port) if port else 'UDS'
    print(f'{idx}|{ib_id}|{remark}|{loc}|{enable}')
conn.close()
" 2>/dev/null)

    local -a ib_ids=() ib_ports=() ib_names=()
    while IFS='|' read -r idx ib_id remark loc enable; do
        ib_ids+=("$ib_id")
        ib_ports+=("$loc")
        ib_names+=("$remark")
        local status_icon
        [ "$enable" = "1" ] && status_icon="${GREEN}✓${NC}" || status_icon="${RED}✗${NC}"
        echo -e "  ${status_icon} [${idx}] ${remark} :${loc}"
    done <<< "$rows_data"

    echo ""
    echo -ne "  Номер inbound для диагностики: "; read -r sel < /dev/tty
    [[ -z "$sel" || ! "$sel" =~ ^[0-9]+$ ]] && return
    local idx_real=$(( sel - 1 ))
    local ib_id="${ib_ids[$idx_real]}"
    local ib_port="${ib_ports[$idx_real]}"
    local ib_name="${ib_names[$idx_real]}"
    [[ -z "$ib_id" ]] && { echo -e "  ${RED}Неверный номер${NC}"; sleep 2; return; }

    clear
    echo -e "\n${CYAN}━━━ Диагностика: ${ib_name} ━━━${NC}\n"

    # Получаем полные данные inbound'а
    local ib_data; ib_data=$(python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT port, listen, protocol, settings, stream_settings, enable FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
if row:
    port, listen, proto, settings, stream, enable = row
    ss = json.loads(stream)
    s = json.loads(settings)
    print(f'PORT={port}')
    print(f'LISTEN={listen}')
    print(f'PROTO={proto}')
    print(f'NETWORK={ss.get(\"network\",\"\")}')
    print(f'SECURITY={ss.get(\"security\",\"\")}')
    print(f'ENABLE={enable}')
    print(f'CLIENTS={len(s.get(\"clients\",[]))}')
    ext = ss.get(\"externalProxy\",[{}])
    print(f'EXT_DEST={ext[0].get(\"dest\",\"\") if ext else \"\"}')
    print(f'EXT_PORT={ext[0].get(\"port\",443) if ext else 443}')
    rs = ss.get(\"realitySettings\",{})
    print(f'REALITY_TARGET={rs.get(\"target\",\"\")}')
    print(f'REALITY_SID_COUNT={len(rs.get(\"shortIds\",[]))}')
    print(f'HAS_EXTERNAL_PROXY={1 if ext and ext[0].get(\"dest\") else 0}')
    print(f'HAS_TESTSEED={1 if \"testseed\" in s else 0}')
    print(f'HAS_FALLBACKS={1 if \"fallbacks\" in s else 0}')
conn.close()
" 2>/dev/null)

    local PORT LISTEN PROTO NETWORK SECURITY ENABLE CLIENTS
    local EXT_DEST EXT_PORT REALITY_TARGET REALITY_SID_COUNT
    local HAS_EXTERNAL_PROXY HAS_TESTSEED HAS_FALLBACKS
    eval "$ib_data"

    # ── Результаты проверок ──
    local issues=0
    local fixes=()

    echo -e "  ${WHITE}Параметры:${NC}"
    echo -e "  Протокол:  ${CYAN}${PROTO}${NC}  Сеть: ${CYAN}${NETWORK}${NC}  Безопасность: ${CYAN}${SECURITY}${NC}"
    echo -e "  Клиентов:  ${CYAN}${CLIENTS}${NC}  Enable: ${CYAN}${ENABLE}${NC}"
    echo -e "  ExternalProxy: ${CYAN}${EXT_DEST}:${EXT_PORT}${NC}"
    [ -n "$REALITY_TARGET" ] && echo -e "  Reality target: ${CYAN}${REALITY_TARGET}${NC}"
    echo ""

    echo -e "  ${WHITE}Проверки:${NC}"

    # 1. Порт слушает?
    if [ "$LISTEN" = "/dev/shm/uds2023.sock,0666" ]; then
        if [ -S "/dev/shm/uds2023.sock" ]; then
            echo -e "  ${GREEN}✓${NC} Unix socket активен"
        else
            echo -e "  ${RED}✗${NC} Unix socket не существует"
            issues=$(( issues + 1 ))
            fixes+=("socket")
        fi
    elif [ -n "$PORT" ] && [ "$PORT" != "0" ]; then
        if ss -tlnp 2>/dev/null | grep -q ":${PORT}"; then
            echo -e "  ${GREEN}✓${NC} Порт ${PORT} слушает"
        else
            echo -e "  ${RED}✗${NC} Порт ${PORT} не слушает"
            issues=$(( issues + 1 ))
            fixes+=("restart")
        fi
    fi

    # 2. externalProxy есть?
    if [ "$HAS_EXTERNAL_PROXY" = "1" ]; then
        echo -e "  ${GREEN}✓${NC} externalProxy настроен (${EXT_DEST}:${EXT_PORT})"
    else
        echo -e "  ${RED}✗${NC} externalProxy отсутствует — клиент не знает куда подключаться"
        issues=$(( issues + 1 ))
        fixes+=("ext_proxy")
    fi

    # 3. Reality shortIds достаточно?
    if [ "$SECURITY" = "reality" ]; then
        if [ "${REALITY_SID_COUNT}" -ge 8 ]; then
            echo -e "  ${GREEN}✓${NC} shortIds: ${REALITY_SID_COUNT} штук"
        else
            echo -e "  ${YELLOW}⚠${NC} shortIds: только ${REALITY_SID_COUNT} (рекомендуется 8)"
            issues=$(( issues + 1 ))
            fixes+=("shortids")
        fi
        # Reality target доступен?
        if [ -n "$REALITY_TARGET" ]; then
            local rt_host="${REALITY_TARGET%:*}"
            local rt_port="${REALITY_TARGET#*:}"
            if nc -z -w2 "$rt_host" "$rt_port" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Reality target ${REALITY_TARGET} доступен"
            else
                echo -e "  ${RED}✗${NC} Reality target ${REALITY_TARGET} недоступен"
                issues=$(( issues + 1 ))
                fixes+=("target")
            fi
        fi
    fi

    # 4. x-ui запущен?
    if systemctl is-active x-ui &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} x-ui запущен"
    else
        echo -e "  ${RED}✗${NC} x-ui не запущен"
        issues=$(( issues + 1 ))
        fixes+=("restart")
    fi

    # 5. nginx слушает 443?
    if ss -tlnp 2>/dev/null | grep -q ":443"; then
        echo -e "  ${GREEN}✓${NC} nginx слушает :443"
    else
        echo -e "  ${RED}✗${NC} nginx не слушает :443"
        issues=$(( issues + 1 ))
        fixes+=("nginx")
    fi

    echo ""

    if [ "$issues" -eq 0 ]; then
        echo -e "  ${GREEN}✅ Проблем не обнаружено!${NC}"
        echo ""
        read -p "  Enter для продолжения..." < /dev/tty
        return
    fi

    echo -e "  ${YELLOW}Обнаружено проблем: ${issues}${NC}"
    echo -e "  Исправить автоматически? ${WHITE}(данные и клиенты сохранятся)${NC}"
    echo -ne "  (y/n): "; read -r do_fix < /dev/tty
    [[ "$do_fix" != "y" ]] && return

    echo ""
    echo -e "  ${CYAN}Исправляем...${NC}"

    for fix in "${fixes[@]}"; do
        case "$fix" in
            socket)
                echo -e "  → Очищаем socket и перезапускаем x-ui..."
                systemctl stop x-ui 2>/dev/null
                rm -f /dev/shm/uds2023.sock
                systemctl start x-ui
                sleep 3
                [ -S "/dev/shm/uds2023.sock" ] && \
                    echo -e "  ${GREEN}✓ Socket восстановлен${NC}" || \
                    echo -e "  ${RED}✗ Socket всё ещё нет — проверь логи${NC}"
                ;;
            restart)
                echo -e "  → Перезапускаем x-ui..."
                rm -f /dev/shm/uds2023.sock 2>/dev/null
                systemctl restart x-ui
                sleep 3
                systemctl is-active x-ui &>/dev/null && \
                    echo -e "  ${GREEN}✓ x-ui запущен${NC}" || \
                    echo -e "  ${RED}✗ x-ui не запустился: $(journalctl -u x-ui -n 3 --no-pager 2>/dev/null | tail -1)${NC}"
                ;;
            ext_proxy)
                echo -e "  → Добавляем externalProxy..."
                local domain; domain=$(_xui_get_domain)
                domain="${domain:-your-domain.com}"
                python3 -c "
import sqlite3, json
conn = sqlite3.connect('/etc/x-ui/x-ui.db', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT stream_settings FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
ss = json.loads(row[0])
tls = 'tls' if ss.get('network') in ('xhttp','grpc','ws') else 'same'
ss['externalProxy'] = [{'forceTls': tls, 'dest': '${domain}', 'port': 443, 'remark': ''}]
conn.execute('UPDATE inbounds SET stream_settings=? WHERE id=?', (json.dumps(ss), ${ib_id}))
conn.commit(); conn.close(); print('OK')
" 2>/dev/null && echo -e "  ${GREEN}✓ externalProxy добавлен${NC}"
                fixes+=("restart")
                ;;
            shortids)
                echo -e "  → Обновляем shortIds (8 штук по 16 символов)..."
                python3 -c "
import sqlite3, json, secrets
conn = sqlite3.connect('/etc/x-ui/x-ui.db', timeout=30)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
row = conn.execute('SELECT stream_settings FROM inbounds WHERE id=?', (${ib_id},)).fetchone()
ss = json.loads(row[0])
ss['realitySettings']['shortIds'] = [secrets.token_hex(8) for _ in range(8)]
conn.execute('UPDATE inbounds SET stream_settings=? WHERE id=?', (json.dumps(ss), ${ib_id}))
conn.commit(); conn.close(); print('OK')
" 2>/dev/null && echo -e "  ${GREEN}✓ shortIds обновлены${NC}"
                fixes+=("restart")
                ;;
            nginx)
                echo -e "  → Перезапускаем nginx..."
                nginx -t 2>/dev/null && systemctl reload nginx && \
                    echo -e "  ${GREEN}✓ nginx перезапущен${NC}" || \
                    echo -e "  ${RED}✗ nginx config error — проверь: nginx -t${NC}"
                ;;
            target)
                echo -e "  ${YELLOW}⚠ Reality target недоступен — возможно nginx не слушает на этом порту${NC}"
                echo -e "  Текущий target: ${REALITY_TARGET}"
                echo -e "  Доступные nginx порты: $(ss -tlnp | grep nginx | grep -oP ':\K\d+' | tr '\n' ' ')"
                ;;
        esac
    done

    echo ""
    echo -e "  ${GREEN}✅ Готово! Проверь подключение.${NC}"
    echo ""
    read -p "  Enter для продолжения..." < /dev/tty
}

# Удалить inbound
_xui_delete_inbound() {
    clear
    echo -e "\n${CYAN}━━━ Удалить inbound ━━━${NC}\n"

    python3 << 'PYEOF'
import sqlite3
conn = sqlite3.connect('/etc/x-ui/x-ui.db')
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')
for r in conn.execute("SELECT id, remark, port FROM inbounds ORDER BY id"):
    print(f"  [{r[0]}] {r[1]} :{r[2]}")
conn.close()
PYEOF
    echo ""
    echo -ne "  ID inbound'а для удаления: "; read -r ib_id < /dev/tty
    [[ -z "$ib_id" ]] && return

    local _yn; _yn=$(read_yn "  ${RED}Удалить inbound #${ib_id}? (y/n): ${NC}")
    [ "$_yn" != "y" ] && return

    systemctl stop x-ui; sleep 1; rm -f /dev/shm/uds2023.sock 2>/dev/null

    python3 << PYEOF
import sqlite3
conn = sqlite3.connect('${XUIDB_PATH}', timeout=30)
conn.execute('DELETE FROM inbounds WHERE id=?', (${ib_id},))
conn.commit(); conn.close()
print("OK")
PYEOF

    systemctl start x-ui; sleep 2
    echo -e "  ${GREEN}✓ Inbound #${ib_id} удалён${NC}"
    sleep 2
}

_3xui_geo_menu() {
    local xray_dir="/usr/local/x-ui/bin"
    [ ! -d "$xray_dir" ] && xray_dir=$(find /usr -name "geoip.dat" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)

    while true; do
        clear
        echo -e "\n${CYAN}━━━ GeoIP / GeoSite (roscomvpn) ━━━${NC}\n"

        # Статус файлов
        local geo_ok=0
        if [ -f "${xray_dir}/geoip.dat" ] && [ -f "${xray_dir}/geosite.dat" ]; then
            local gip_date; gip_date=$(date -r "${xray_dir}/geoip.dat" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
            local gst_date; gst_date=$(date -r "${xray_dir}/geosite.dat" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "?")
            echo -e "  ${GREEN}✓ roscomvpn geoip.dat${NC}   обновлён: ${CYAN}${gip_date}${NC}"
            echo -e "  ${GREEN}✓ roscomvpn geosite.dat${NC} обновлён: ${CYAN}${gst_date}${NC}"
            geo_ok=1
        else
            echo -e "  ${RED}✗ Файлы не установлены${NC}"
        fi


        echo ""
        echo -e "  ${WHITE}Как использовать в 3X-UI панели:${NC}"
        echo -e "  Настройки → Xray конфигурация → Routing → добавить правила:"
        echo -e "  ${CYAN}РФ напрямую:${NC}      geosite:category-ru        → direct"
        echo -e "  ${CYAN}Заблокированные:${NC}  geosite:category-ru-blocked → proxy/WARP"
        if [ "$geo_ok" -eq 1 ]; then
            echo -e "  ${CYAN}Реклама:${NC}          geosite:category-ads-all    → block ${YELLOW}(только roscomvpn)${NC}"
        fi
        echo ""
        if [ "$geo_ok" -eq 1 ]; then
            echo -e "  ${WHITE}Актуальные URL для Happ (если ошибка загрузки):${NC}"
            echo -e "  ${CYAN}github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat${NC}"
            echo -e "  ${CYAN}github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat${NC}"
            echo ""
        fi
        echo -e "  ${WHITE}── Файлы ─────────────────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  Обновить файлы (roscomvpn + авто routing)"
        echo -e "  ${YELLOW}[2]${NC}  Настроить автообновление (ежедневно)"
        echo -e "  ${WHITE}── Routing ───────────────────────────${NC}"
        if [ "$geo_ok" -eq 1 ]; then
            echo -e "  ${GREEN}[3]${NC}  Применить правила routing вручную"
        fi
        echo -e "  ${CYAN}[4]${NC}  Свой список доменов (direct/proxy)"
        echo -e "  ${CYAN}[r]${NC}  РФ сервер как outbound (category-ru + свой список)"
        echo -e "  ${WHITE}── Happ / v2rayTun ───────────────────${NC}"
        echo -e "  ${CYAN}[5]${NC}  QR roscomvpn URL → открыть Happ"
        echo -e "  ${CYAN}[6]${NC}  QR bypass список → открыть Happ"
        echo -e "  ${WHITE}── Бэкап ─────────────────────────────${NC}"
        if [ "$geo_ok" -eq 1 ]; then
            echo -e "  ${YELLOW}[7]${NC}  Сохранить бэкап"
        fi
        if [ -f "/etc/govpn/geofiles_backup/geosite.dat" ]; then
            echo -e "  ${YELLOW}[8]${NC}  Восстановить из бэкапа"
        fi
        if [ "$geo_ok" -eq 1 ]; then
            echo -e "  ${WHITE}── Удаление ──────────────────────────${NC}"
            echo -e "  ${RED}[9]${NC}  Удалить (вернуть стандартные v2fly файлы)"
        fi
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1)
                _3xui_update_geofiles ;;
            2)
                _3xui_setup_geo_autoupdate
                echo -e "  ${GREEN}✓ Автообновление настроено (/etc/cron.daily/govpn-geo-update)${NC}"
                read -p "  Enter..." < /dev/tty ;;
            [rR]) _3xui_setup_ru_outbound ;;
            3)
                if [ "$geo_ok" -eq 1 ]; then
                    echo ""
                    _3xui_add_geo_routing
                    read -p "  Enter..." < /dev/tty
                fi ;;
            4)
                # Свой список доменов
                mkdir -p /etc/govpn
                local cfile="/etc/govpn/custom_domains.txt"
                [ ! -f "$cfile" ] && cat > "$cfile" << 'CEOF'
# Свой список доменов для маршрутизации
# Формат: домен [направление]
#   домен           — через proxy/WARP (по умолчанию)
#   домен proxy     — явно через WARP
#   домен direct    — напрямую без VPN
#
# Примеры:
# rutracker.org           <- через VPN
# kinozal.tv proxy        <- через VPN (явно)
# 2ip.ru direct           <- напрямую
# gosuslugi.ru direct     <- напрямую
CEOF
                nano "$cfile" 2>/dev/null || vi "$cfile" 2>/dev/null || {
                    echo -e "  ${YELLOW}Файл: ${cfile}${NC}"
                    cat "$cfile"
                    echo -e "
  ${WHITE}Редактор не найден. Отредактируй вручную:${NC}"
                    echo -e "  nano ${cfile}"
                    read -p "  Enter..." < /dev/tty
                } ;;
            5) _3xui_qr_happ_urls ;;
            6) _3xui_export_bypass_list ;;
            7) [ "$geo_ok" -eq 1 ] && _3xui_backup_geofiles ;;
            8) [ -f "/etc/govpn/geofiles_backup/geosite.dat" ] && _3xui_restore_geofiles ;;
            9)
                if [ "$geo_ok" -eq 1 ]; then
                    echo -ne "\n  ${RED}Удалить roscomvpn файлы и восстановить стандартные? (y/n): ${NC}"
                    read -r c < /dev/tty
                    if [ "$c" = "y" ]; then
                        # Скачиваем стандартные файлы Cloudflare/v2fly
                        # Сначала удаляем roscomvpn правила из routing
                        echo -e "  ${CYAN}Удаляю roscomvpn правила routing...${NC}"
                        local xui_db="/etc/x-ui/x-ui.db"
                        if [ -f "$xui_db" ]; then
                            sqlite3 "$xui_db" \
                                "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null | \
                            python3 -c "
import json,sys
cfg=json.load(sys.stdin)
rules=cfg.get('routing',{}).get('rules',[])
cfg['routing']['rules']=[r for r in rules if 'roscomvpn' not in r.get('_comment','') and 'govpn' not in r.get('_comment','')]
print(json.dumps(cfg,ensure_ascii=False))
" 2>/dev/null | python3 -c "
import sys
d=sys.stdin.read().replace(chr(39),chr(39)+chr(39))
print(f\"UPDATE settings SET value=\'{d}\' WHERE key=\'xrayTemplateConfig\';\")" 2>/dev/null | \
                            sqlite3 "$xui_db" 2>/dev/null && \
                            echo -e "  ${GREEN}✓ Правила routing удалены${NC}"
                        fi
                        echo -e "  ${CYAN}Восстанавливаю стандартные файлы...${NC}"
                        curl -fsSL --max-time 30 \
                            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" \
                            -o "${xray_dir}/geoip.dat" 2>/dev/null && \
                            echo -e "  ${GREEN}✓ geoip.dat${NC}" || echo -e "  ${RED}✗ geoip.dat${NC}"
                        curl -fsSL --max-time 30 \
                            "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" \
                            -o "${xray_dir}/geosite.dat" 2>/dev/null && \
                            echo -e "  ${GREEN}✓ geosite.dat${NC}" || echo -e "  ${RED}✗ geosite.dat${NC}"
                        # Удаляем автообновление
                        rm -f /etc/cron.daily/govpn-geo-update
                        systemctl restart x-ui > /dev/null 2>&1
                        echo -e "  ${GREEN}✓ Восстановлено, xray перезапущен${NC}"
                        log_action "3XUI: geofiles восстановлены (стандартные)"
                    fi
                    read -p "  Enter..." < /dev/tty
                fi ;;
            0|"") return ;;
        esac
    done
}

_3xui_update_geofiles() {
    local xray_dir="/usr/local/x-ui/bin"
    [ ! -d "$xray_dir" ] && xray_dir=$(find /usr/local -name "xray" -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "/usr/local/x-ui/bin")

    echo -e "\n${CYAN}━━━ Обновление GeoIP / GeoSite (roscomvpn) ━━━${NC}\n"
    echo -e "  ${WHITE}Директория:${NC} ${CYAN}${xray_dir}${NC}"

    local CDN="https://cdn.jsdelivr.net/gh/hydraponique"
    local GH="https://github.com/hydraponique"
    local ok=0

    # geoip.dat
    echo -ne "  ${CYAN}→ geoip.dat...${NC} "
    if curl -fsSL --max-time 30 \
            "${CDN}/roscomvpn-geoip/release/geoip.dat" \
            -o "${xray_dir}/geoip.dat" 2>/dev/null && \
       [ -s "${xray_dir}/geoip.dat" ]; then
        echo -e "${GREEN}✓${NC}"
        (( ok++ ))
    elif curl -fsSL --max-time 30 \
            "${GH}/roscomvpn-geoip/releases/latest/download/geoip.dat" \
            -o "${xray_dir}/geoip.dat" 2>/dev/null && \
       [ -s "${xray_dir}/geoip.dat" ]; then
        echo -e "${GREEN}✓${NC} (GH)"
        (( ok++ ))
    else
        echo -e "${RED}✗${NC}"
    fi


    # geosite.dat — используем -L для следования редиректам GitHub
    echo -ne "  ${CYAN}→ geosite.dat...${NC} "
    local geo_tmp="${xray_dir}/geosite.dat.tmp"
    local geo_ok_site=0
    # Источники в порядке приоритета:
    # 1. runetfreedom — содержит category-ru, работает с -L
    # 2. v2fly — стандартный без category-ru (fallback)
    for geo_url in         "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"         "${CDN}/roscomvpn-geosite/release/geosite.dat"         "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"; do
        curl -fsSL -L --max-time 90 "$geo_url" -o "$geo_tmp" 2>/dev/null || continue
        local sz; sz=$(stat -c%s "$geo_tmp" 2>/dev/null || echo 0)
        if [ "$sz" -gt 500000 ]; then
            mv "$geo_tmp" "${xray_dir}/geosite.dat"
            geo_ok_site=1
            if [ "$sz" -gt 10000000 ]; then
                echo -e "${GREEN}✓${NC} (runetfreedom ${sz}B — содержит category-ru)"
            elif [ "$sz" -gt 2000000 ]; then
                echo -e "${GREEN}✓${NC} (roscomvpn ${sz}B)"
            else
                echo -e "${YELLOW}✓${NC} (v2fly стандартный ${sz}B — без category-ru)"
            fi
            break
        fi
        rm -f "$geo_tmp"
    done
    [ "$geo_ok_site" -eq 1 ] && (( ok++ )) || echo -e "${RED}✗${NC}"


    if [ "$ok" -eq 2 ]; then
        echo -e "\n  ${GREEN}✅ GeoIP и GeoSite обновлены${NC}"
        echo -e "  ${WHITE}Источник:${NC} roscomvpn (Россия+Беларусь прямые, остальное через прокси)"
        log_action "3XUI: обновлены geoip/geosite (roscomvpn)"

        # Применяем правила routing ДО перезапуска xray
        # Проверяем что файл действительно roscomvpn (>2MB)
        local geo_sz; geo_sz=$(stat -c%s "${xray_dir}/geosite.dat" 2>/dev/null || echo 0)
        if [ "$geo_sz" -gt 2000000 ]; then
            echo -e "  ${CYAN}Применяю правила routing...${NC}"
            _3xui_add_geo_routing
        else
            echo -e "  ${YELLOW}⚠ geosite.dat (${geo_sz}B) — правила routing НЕ добавлены${NC}"
            echo -e "  ${WHITE}Файл не содержит category-ru-blocked — повторите обновление${NC}"
        fi

        sleep 1
        systemctl restart x-ui > /dev/null 2>&1
        sleep 3
        echo -e "  ${CYAN}↻ xray перезапущен${NC}"
    else
        echo -e "\n  ${YELLOW}⚠ Обновление частичное — проверьте интернет${NC}"
    fi
    read -p "  Enter..." < /dev/tty
}


# Автообновление geofiles через cron
_3xui_setup_geo_autoupdate() {
    local CDN="https://cdn.jsdelivr.net/gh/hydraponique"
    local xray_dir="/usr/local/x-ui/bin"
    [ ! -d "$xray_dir" ] && xray_dir=$(find /usr -name "geoip.dat" 2>/dev/null | head -1 | xargs dirname)
    [ -z "$xray_dir" ] && return 1

    cat > /etc/cron.daily/govpn-geo-update << CRONEOF
#!/bin/bash
# Автообновление roscomvpn geoip/geosite
curl -fsSL --max-time 60 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" -o "${xray_dir}/geoip.dat" 2>/dev/null || curl -fsSL --max-time 60 "${CDN}/roscomvpn-geoip/release/geoip.dat" -o "${xray_dir}/geoip.dat" 2>/dev/null
curl -fsSL -L --max-time 90 "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" -o "${xray_dir}/geosite.dat" 2>/dev/null || curl -fsSL -L --max-time 60 "${CDN}/roscomvpn-geosite/release/geosite.dat" -o "${xray_dir}/geosite.dat" 2>/dev/null
systemctl restart x-ui > /dev/null 2>&1
CRONEOF
    chmod +x /etc/cron.daily/govpn-geo-update
    echo -e "  ${GREEN}✓ Автообновление настроено (ежедневно)${NC}"
}

_install_3xui() {
    clear
    echo -e "\n${CYAN}━━━ Установка 3X-UI ━━━${NC}\n"

    if systemctl is-active x-ui &>/dev/null 2>&1 || [ -f "/etc/x-ui/x-ui.db" ]; then
        echo -e "  ${YELLOW}3X-UI уже установлен${NC}"
        echo -ne "  Переустановить/обновить? (y/n): "; read -r c
        [[ "$c" != "y" ]] && return
    fi

    echo -e "  ${WHITE}Варианты:${NC}"
    echo -e "  ${YELLOW}[1]${NC}  3X-UI (стандартный)  — github.com/MHSanaei/3x-ui"
    echo -e "  ${YELLOW}[2]${NC}  3X-UI Pro             — github.com/mozaroc/x-ui-pro"
    echo ""
    local ch; ch=$(read_choice "Выбор [1]: ")
    ch="${ch:-1}"

    echo ""
    case "$ch" in
        1)
            echo -e "  ${CYAN}→ Установка 3X-UI...${NC}\n"
            bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) 2>&1
            ;;
        2)
            echo -e "  ${CYAN}→ Установка 3X-UI Pro...${NC}\n"
            bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/x-ui-pro/master/install.sh) 2>&1
            ;;
        *)
            echo -e "  ${YELLOW}Отмена${NC}"; read -p "  Enter..."; return
            ;;
    esac

    if systemctl is-active x-ui &>/dev/null 2>&1; then
        echo -e "\n  ${GREEN}✅ 3X-UI установлен и запущен${NC}"
        local xui_port
        xui_port=$(grep -oP '(?<="port":)\d+' /usr/local/x-ui/bin/config.json 2>/dev/null || echo "2053")
        echo -e "  ${WHITE}Панель:${NC} ${CYAN}http://${MY_IP}:${xui_port}${NC}"

        # Предлагаем сохранить пароль в govpn конфиг
        echo ""
        echo -e "  ${WHITE}Введите пароль от панели 3X-UI (для govpn управления):${NC}"
        echo -e "  ${CYAN}(Это тот пароль что вы задали при установке)${NC}"
        echo -ne "  Пароль: "
        local xui_pass_save
        read -r -s xui_pass_save < /dev/tty
        echo ""
        if [ -n "$xui_pass_save" ]; then
            sed -i "/^XUI_PASS=/d" /etc/govpn/config 2>/dev/null
            echo "XUI_PASS=${xui_pass_save}" >> /etc/govpn/config
            echo -e "  ${GREEN}✓ Пароль сохранён в /etc/govpn/config${NC}"
        fi

        log_action "INSTALL: 3X-UI"
        echo -e "\n  ${YELLOW}Перезапустите govpn для определения нового режима.${NC}"
    else
        echo -e "\n  ${YELLOW}Проверьте статус: systemctl status x-ui${NC}"
    fi

    read -p "  Enter..."
}

# Установка Hysteria2 (по образцу YukiKras/vless-scripts)
_install_hysteria2() {
    clear
    echo -e "\n${CYAN}━━━ Установка Hysteria2 ━━━${NC}\n"

    # Если уже установлен — предлагаем переустановить (удаляем старое)
    if command -v hysteria &>/dev/null || [ -f /usr/local/bin/hysteria ]; then
        local ver; ver=$(hysteria version 2>/dev/null | head -1 || echo "неизвестна")
        echo -e "  ${YELLOW}Hysteria2 уже установлен: ${ver}${NC}"
        echo -ne "  Переустановить? (y/n): "; read -r c
        [[ "$c" != "y" ]] && return
        # Полная очистка
        systemctl stop hysteria-server 2>/dev/null || true
        systemctl disable hysteria-server 2>/dev/null || true
        rm -f /etc/systemd/system/hysteria-server.service
        rm -f /usr/local/bin/hysteria
        rm -rf /etc/hysteria
        rm -f /root/hysteria2.txt
        systemctl daemon-reload
        echo -e "  ${GREEN}✓ Старая версия удалена${NC}\n"
    fi

    # Параметры
    local sni_host port auth_pwd obfs_pwd
    echo -ne "  SNI хост [web.max.ru]: "; read -r inp; sni_host="${inp:-web.max.ru}"
    echo -ne "  Порт [443]: "; read -r inp; port="${inp:-443}"
    auth_pwd=$(date +%s%N | md5sum | cut -c 1-16)
    obfs_pwd=$(date +%s%N | md5sum | cut -c 1-16)
    echo ""

    # Зависимости
    export DEBIAN_FRONTEND=noninteractive
    command -v openssl &>/dev/null || apt-get install -y openssl > /dev/null 2>&1
    command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1

    # Скачиваем бинарник напрямую с GitHub (без get.hy2.sh)
    echo -e "  ${CYAN}→ Загрузка Hysteria2...${NC}"
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="arm"   ;;
        *)       arch="amd64" ;;
    esac

    # Получаем последнюю версию
    local latest_ver
    latest_ver=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/apernet/hysteria/releases/latest" 2>/dev/null \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
        | sed 's|app/||')
    [ -z "$latest_ver" ] && latest_ver="v2.8.1"  # fallback

    local dl_url="https://github.com/apernet/hysteria/releases/download/app/${latest_ver}/hysteria-linux-${arch}"
    echo -e "  ${WHITE}Версия: ${latest_ver}  Архитектура: ${arch}${NC}"

    if ! curl -fsSL --max-time 60 "$dl_url" -o /usr/local/bin/hysteria 2>/dev/null; then
        echo -e "  ${RED}✗ Не удалось загрузить бинарник${NC}"
        read -p "  Enter..."; return 1
    fi
    chmod 755 /usr/local/bin/hysteria
    echo -e "  ${GREEN}✓ Бинарник установлен${NC}"

    # Генерируем self-signed сертификат (prime256v1 как у YukiKras)
    echo -e "  ${CYAN}→ Генерация сертификата (self-signed, SNI: ${sni_host})...${NC}"
    mkdir -p /etc/hysteria
    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key 2>/dev/null
    openssl req -new -x509 -days 36500 \
        -key /etc/hysteria/private.key \
        -out /etc/hysteria/cert.crt \
        -subj "/CN=${sni_host}" 2>/dev/null
    chmod 600 /etc/hysteria/cert.crt /etc/hysteria/private.key
    echo -e "  ${GREEN}✓ Сертификат создан${NC}"

    # Конфиг с obfs salamander
    echo -e "  ${CYAN}→ Конфигурация...${NC}"
    cat > /etc/hysteria/config.yaml << EOF
listen: :${port}

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/private.key

obfs:
  type: salamander
  salamander:
    password: ${obfs_pwd}

auth:
  type: password
  password: ${auth_pwd}

masquerade:
  type: proxy
  proxy:
    url: https://${sni_host}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

    # Systemd юнит
    cat > /etc/systemd/system/hysteria-server.service << 'EOF'
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=~
User=root
Group=root
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable hysteria-server > /dev/null 2>&1
    systemctl restart hysteria-server > /dev/null 2>&1
    sleep 2

    if systemctl is-active --quiet hysteria-server; then
        # Сохраняем ключ подключения
                local hy2_key="hy2://${auth_pwd}@${MY_IP}:${port}?insecure=1&sni=${sni_host}&obfs=salamander&obfs-password=${obfs_pwd}#govpn-hy2"
        echo "$hy2_key" > /root/hysteria2.txt

        echo -e "\n  ${GREEN}✅ Hysteria2 установлен и запущен!${NC}\n"
        echo -e "  ${WHITE}Порт:${NC}    ${CYAN}${port}${NC}"
        echo -e "  ${WHITE}SNI:${NC}     ${CYAN}${sni_host}${NC}"
        echo -e "  ${WHITE}Пароль:${NC}  ${CYAN}${auth_pwd}${NC}"
        echo -e "  ${WHITE}Obfs:${NC}    ${CYAN}${obfs_pwd}${NC}"
        echo ""
        echo -e "  ${WHITE}Ключ подключения:${NC}"
        echo -e "  ${CYAN}${hy2_key}${NC}"
        echo ""
        echo -e "  ${WHITE}Файл:${NC} /root/hysteria2.txt"

        # QR-код
        if command -v qrencode &>/dev/null; then
            echo ""
            qrencode -t ANSIUTF8 "$hy2_key"
        fi

        # UFW
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'active'; then
            ufw allow "${port}/udp" > /dev/null 2>&1
            echo -e "  ${GREEN}✓ UFW: порт ${port}/udp открыт${NC}"
        fi

        log_action "INSTALL: Hysteria2 ver=${latest_ver} port=${port} sni=${sni_host}"
    else
        echo -e "\n  ${RED}✗ Hysteria2 не запустился${NC}"
        echo -e "  Лог: journalctl -u hysteria-server -n 30"
    fi

    read -p "  Enter..."
}

# Главное меню установщика
# ═══════════════════════════════════════════════════════════════
#  HYSTERIA2 — WARP ИНТЕГРАЦИЯ (хостовой уровень)
# ═══════════════════════════════════════════════════════════════

HY2_WARP_CONF="/etc/hysteria/warp.conf"
HY2_WARP_IFACE="warp-hy2"

_hy2_install_wgcf() {
    if command -v wgcf &>/dev/null; then
        echo -e "  ${GREEN}✓ wgcf уже установлен${NC}  $(wgcf --version 2>/dev/null)"
        return 0
    fi
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *) echo -e "  ${RED}✗ Архитектура не поддерживается${NC}"; return 1 ;;
    esac
    echo -ne "  ${CYAN}→ Загрузка wgcf...${NC} "
    local url="https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_${arch}"
    if curl -fsSL --max-time 30 "$url" -o /usr/local/bin/wgcf 2>/dev/null && [ -s /usr/local/bin/wgcf ]; then
        chmod +x /usr/local/bin/wgcf
        echo -e "${GREEN}✓${NC}"; return 0
    else
        echo -e "${RED}✗${NC}"; return 1
    fi
}

_hy2_create_warp_conf() {
    mkdir -p /etc/hysteria
    cd /tmp || return 1
    rm -f wgcf-account.toml wgcf-profile.conf
    echo -ne "  ${CYAN}→ Регистрация WARP аккаунта...${NC} "
    yes | wgcf register --accept-tos > /dev/null 2>&1
    [ -f /tmp/wgcf-account.toml ] || { echo -e "${RED}✗${NC}"; return 1; }
    yes | wgcf generate > /dev/null 2>&1
    [ -f /tmp/wgcf-profile.conf ] || { echo -e "${RED}✗${NC}"; return 1; }
    echo -e "${GREEN}✓${NC}"
    cp /tmp/wgcf-profile.conf "$HY2_WARP_CONF"
    sed -i "s|^\(Address = [0-9.\/]*\),.*|\1|g" "$HY2_WARP_CONF"
    sed -i "s|AllowedIPs = 0\.0\.0\.0/0, ::/0|AllowedIPs = 0.0.0.0/0|g" "$HY2_WARP_CONF"
    sed -i "s|AllowedIPs = ::/0.*|AllowedIPs = 0.0.0.0/0|g" "$HY2_WARP_CONF"
    sed -i "s|^DNS = .*|# DNS disabled|g" "$HY2_WARP_CONF"
    sed -i "/^\[Interface\]/a Table = off" "$HY2_WARP_CONF"
    chmod 600 "$HY2_WARP_CONF"
    mv /tmp/wgcf-account.toml /etc/hysteria/ 2>/dev/null || true
    return 0
}

_hy2_warp_up() {
    command -v wg-quick &>/dev/null || apt-get install -y wireguard-tools > /dev/null 2>&1
    cp "$HY2_WARP_CONF" "/etc/wireguard/${HY2_WARP_IFACE}.conf" 2>/dev/null
    wg-quick down "$HY2_WARP_IFACE" > /dev/null 2>&1 || true
    echo -ne "  ${CYAN}→ Поднимаю WARP туннель...${NC} "
    if wg-quick up "$HY2_WARP_IFACE" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"; return 0
    else
        echo -e "${RED}✗${NC}"; return 1
    fi
}

_hy2_apply_warp_routing() {
    ip route add default dev "$HY2_WARP_IFACE" table 101 2>/dev/null || \
        ip route replace default dev "$HY2_WARP_IFACE" table 101 2>/dev/null || true
    ip rule del fwmark 0x65 table 101 2>/dev/null || true
    ip rule add fwmark 0x65 table 101 priority 101
    echo -e "  ${GREEN}✓ Маршрутизация настроена${NC}  (fwmark 0x65 → ${HY2_WARP_IFACE})"
    # Добавляем outbound в конфиг Hysteria2
    python3 /tmp/hy2_warp_outbound.py 2>/dev/null || true
}

_hy2_warp_running() {
    ip link show "$HY2_WARP_IFACE" &>/dev/null 2>&1
}

_hy2_warp_ip() {
    curl -s --interface "$HY2_WARP_IFACE" --connect-timeout 5 https://api4.ipify.org 2>/dev/null | tr -d '[:space:]'
}

_hy2_warp_persist() {
    cat > /etc/systemd/system/hysteria-warp.service << EOF
[Unit]
Description=WARP tunnel for Hysteria2
Before=hysteria-server.service
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/wg-quick up ${HY2_WARP_IFACE}
ExecStop=/usr/bin/wg-quick down ${HY2_WARP_IFACE}
ExecStartPost=/bin/sh -c 'ip route add default dev ${HY2_WARP_IFACE} table 101 2>/dev/null || true; ip rule add fwmark 0x65 table 101 priority 101 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable hysteria-warp > /dev/null 2>&1
    systemctl start hysteria-warp > /dev/null 2>&1
}

_hy2_warp_write_helper() {
    cat > /tmp/hy2_warp_outbound.py << 'PYEOF'
import yaml, sys
p = '/etc/hysteria/config.yaml'
try:
    with open(p) as f:
        cfg = yaml.safe_load(f)
    outbounds = cfg.get('outbounds', [])
    if not any(o.get('name') == 'warp' for o in outbounds):
        outbounds.insert(0, {'name': 'warp', 'type': 'direct', 'direct': {'bindDevice': 'warp-hy2'}})
        cfg['outbounds'] = outbounds
    with open(p, 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
    print("ok")
except Exception as e:
    print(f"err:{e}", file=sys.stderr); sys.exit(1)
PYEOF
}

_hy2_install_warp() {
    clear
    echo -e "\n${CYAN}━━━ WARP для Hysteria2 ━━━${NC}\n"
    if _hy2_warp_running; then
        local wip; wip=$(_hy2_warp_ip)
        echo -e "  ${GREEN}✓ WARP уже активен${NC}  IP: ${GREEN}${wip:-подключён}${NC}"
        echo -ne "\n  Переустановить? (y/n): "; read -r c
        [[ "$c" != "y" ]] && return
        systemctl stop hysteria-warp 2>/dev/null || true
        wg-quick down "$HY2_WARP_IFACE" > /dev/null 2>&1 || true
        ip rule del fwmark 0x65 table 101 2>/dev/null || true
        ip route flush table 101 2>/dev/null || true
    fi
    _hy2_install_wgcf || { read -p "  Enter..."; return 1; }
    _hy2_create_warp_conf || { read -p "  Enter..."; return 1; }
    _hy2_warp_up || { read -p "  Enter..."; return 1; }
    echo -ne "  ${CYAN}→ Маршрутизация...${NC} "
    _hy2_warp_write_helper
    _hy2_apply_warp_routing
    echo -ne "  ${CYAN}→ Проверка WARP IP...${NC} "
    sleep 2
    local wip; wip=$(_hy2_warp_ip)
    if [ -n "$wip" ] && [ "$wip" != "$MY_IP" ]; then
        echo -e "${GREEN}✓  ${wip}${NC}"
    else
        echo -e "${YELLOW}? ${wip:-не получен}${NC}"
    fi
    echo -ne "  ${CYAN}→ Автостарт...${NC} "
    _hy2_warp_persist && echo -e "${GREEN}✓${NC}"
    echo -ne "  ${CYAN}→ Перезапуск Hysteria2...${NC} "
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart hysteria-server > /dev/null 2>&1
    sleep 2
    systemctl is-active --quiet hysteria-server && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    log_action "HY2: WARP установлен, iface=${HY2_WARP_IFACE}, IP=${wip}"
    echo -e "\n  ${GREEN}✅ WARP для Hysteria2 активен!${NC}"
    echo -e "  ${WHITE}IP через WARP:${NC} ${CYAN}${wip}${NC}"
    read -p "  Enter..."
}

install_wizard() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Установка и компоненты ━━━${NC}\n"

        local status_awg="" status_xui=""

        if command -v docker &>/dev/null; then
            local awg_ct; awg_ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i 'amnezia-awg' | head -1)
            [ -n "$awg_ct" ] && status_awg=" ${GREEN}● запущен (${awg_ct})${NC}" || \
                status_awg=" ${YELLOW}● не установлен${NC}"
        else
            status_awg=" ${YELLOW}● Docker отсутствует${NC}"
        fi

        systemctl is-active x-ui &>/dev/null 2>&1 && \
            status_xui=" ${GREEN}● запущен${NC}" || \
            status_xui=" ${YELLOW}● не установлен${NC}"

        # Hysteria2 статус скрыт

        echo -e "  ${YELLOW}[1]${NC}  AmneziaWG (Docker)     ${status_awg}"
        echo -e "  ${YELLOW}[2]${NC}  3X-UI / 3X-UI Pro      ${status_xui}"
        is_3xui && echo -e "  ${YELLOW}[3]${NC}  GeoIP/GeoSite (roscomvpn)"
        is_3xui && echo -e "  ${CYAN}[4]${NC}  Шаблоны inbound (xHTTP/gRPC/TCP)"
        echo -e "  ${WHITE}── Внешние скрипты ───────────────────${NC}"
        echo -e "  ${CYAN}[y]${NC}  YukiKras/vless-scripts (3X-UI + fakesite)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1) _install_amnezia_awg ;;
            2) _install_3xui ;;
            3) is_3xui && _3xui_geo_menu ;;
            4) is_3xui && _3xui_inbound_templates ;;
            [yY]) _3xui_yukikras_info ;;
            0|"") return ;;
        esac
    done
}


#  ДОМЕНЫ И SSL
# ═══════════════════════════════════════════════════════════════

# Определяет текущий домен сервера (для шапки system_menu)
_domain_detect_short() {
    # 1. cdn-one.org (x-ui-pro автодомен по IP)
    local cdn_one_domain
    cdn_one_domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | grep 'cdn-one\.org' | head -1)
    if [ -n "$cdn_one_domain" ]; then
        local exp days_left
        exp=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${cdn_one_domain}/cert.pem" 2>/dev/null | cut -d= -f2)
        days_left=$(( ( $(date -d "$exp" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        if [ "$days_left" -gt 30 ]; then
            echo -e "${GREEN}${cdn_one_domain}${NC}  ${WHITE}(x-ui-pro, SSL, ${days_left}д)${NC}"
        elif [ "$days_left" -gt 0 ]; then
            echo -e "${YELLOW}${cdn_one_domain}${NC}  ${WHITE}(x-ui-pro, SSL, ${days_left}д — скоро истекает)${NC}"
        else
            echo -e "${RED}${cdn_one_domain}${NC}  ${WHITE}(x-ui-pro, SSL истёк!)${NC}"
        fi
        return
    fi

    # 2. Let's Encrypt (любой другой домен)
    local le_domain
    le_domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
    if [ -n "$le_domain" ]; then
        local exp days_left
        exp=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/${le_domain}/cert.pem" 2>/dev/null | cut -d= -f2)
        days_left=$(( ( $(date -d "$exp" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        [ "$days_left" -gt 30 ] &&             echo -e "${GREEN}${le_domain}${NC}  ${WHITE}(LE SSL, ${days_left}д)${NC}" ||             echo -e "${YELLOW}${le_domain}${NC}  ${WHITE}(LE SSL, ${days_left}д — скоро истекает)${NC}"
        return
    fi

    # 3. nginx конфиги (без SSL)
    local nginx_domain
    nginx_domain=$(grep -rh 'server_name' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null |         grep -v '#\|localhost\|_\|default' | grep -oP 'server_name\s+\K\S+' |         grep '\.' | grep -v 'cdn-one' | head -1)
    [ -n "$nginx_domain" ] && { echo -e "${YELLOW}${nginx_domain}${NC}  ${WHITE}(nginx, без SSL)${NC}"; return; }

    # 4. x-ui конфиг
    local xui_domain
    xui_domain=$(grep -oP '"domain":\s*"\K[^"]+' /usr/local/x-ui/bin/config.json 2>/dev/null | head -1)
    [ -n "$xui_domain" ] && { echo -e "${YELLOW}${xui_domain}${NC}  ${WHITE}(x-ui конфиг)${NC}"; return; }

    echo -e "${YELLOW}не настроен${NC}"
}

# Полное определение состояния домена
_domain_detect_full() {
    echo -e "\n${CYAN}━━━ Анализ домена ━━━${NC}\n"

    # x-ui-pro (cdn-one.org автодомен)
    local xui_pro_domain
    xui_pro_domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | grep 'cdn-one\.org' | head -1)
    if [ -n "$xui_pro_domain" ]; then
        echo -e "  ${CYAN}Схема: x-ui-pro (cdn-one.org)${NC}"
        echo -e "  ${WHITE}Домен панели:${NC}   ${GREEN}https://${xui_pro_domain}${NC}"
        local reality_d
        reality_d=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | grep 'cdn-one\.org' | grep -- '-' | head -1)
        [ -n "$reality_d" ] && echo -e "  ${WHITE}Домен Reality:${NC}  ${GREEN}${reality_d}${NC}"
        echo -e "  ${WHITE}Привязка:${NC}       ${WHITE}автоматически к IP ${MY_IP}${NC}"
        echo -e "  ${GREEN}✓ Домен настроен через x-ui-pro — менять ничего не нужно${NC}"
        echo -e "  ${WHITE}При смене IP домен обновится автоматически (${MY_IP}.cdn-one.org)${NC}"
        echo ""
    fi

    # Let's Encrypt
    echo -e "  ${WHITE}Let's Encrypt сертификаты:${NC}"
    if [ -d /etc/letsencrypt/live ]; then
        local found=0
        for domain_dir in /etc/letsencrypt/live/*/; do
            local d; d=$(basename "$domain_dir")
            [[ "$d" == "README" ]] && continue
            local cert="${domain_dir}cert.pem"
            if [ -f "$cert" ]; then
                local exp days_left
                exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
                days_left=$(( ( $(date -d "$exp" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
                if [ "$days_left" -gt 30 ]; then
                    echo -e "    ${GREEN}✓ ${d}${NC}  истекает через ${days_left} дней"
                elif [ "$days_left" -gt 0 ]; then
                    echo -e "    ${YELLOW}⚠ ${d}${NC}  истекает через ${days_left} дней — нужно продлить"
                else
                    echo -e "    ${RED}✗ ${d}${NC}  сертификат истёк!"
                fi
                # Проверяем резолвинг
                local resolved_ip
                resolved_ip=$(dig +short "$d" 2>/dev/null | tail -1 || nslookup "$d" 2>/dev/null | grep 'Address:' | tail -1 | awk '{print $2}')
                if [ "$resolved_ip" = "$MY_IP" ]; then
                    echo -e "    ${GREEN}✓ DNS резолвится в ${MY_IP}${NC}"
                elif [ -n "$resolved_ip" ]; then
                    echo -e "    ${YELLOW}⚠ DNS: ${resolved_ip} (сервер: ${MY_IP})${NC}"
                else
                    echo -e "    ${YELLOW}⚠ DNS не резолвится${NC}"
                fi
                (( found++ ))
            fi
        done
        [ "$found" -eq 0 ] && echo -e "    ${YELLOW}сертификатов нет${NC}"
    else
        echo -e "    ${YELLOW}Let's Encrypt не установлен${NC}"
    fi

    # nginx
    echo -e "\n  ${WHITE}nginx:${NC}"
    if command -v nginx &>/dev/null; then
        local nginx_status
        nginx_status=$(systemctl is-active nginx 2>/dev/null)
        echo -e "    Статус: $([ "$nginx_status" = "active" ] && echo -e "${GREEN}● запущен${NC}" || echo -e "${YELLOW}● остановлен${NC}")"
        local sites
        sites=$(ls /etc/nginx/sites-enabled/ 2>/dev/null | grep -v default)
        [ -n "$sites" ] && echo -e "    Сайты: ${CYAN}${sites}${NC}" || echo -e "    Сайтов нет"
    else
        echo -e "    ${YELLOW}не установлен${NC}"
    fi

    # certbot
    echo -e "\n  ${WHITE}certbot:${NC}"
    if command -v certbot &>/dev/null; then
        echo -e "    ${GREEN}✓ установлен${NC}  $(certbot --version 2>&1 | head -1)"
    else
        echo -e "    ${YELLOW}не установлен${NC}"
    fi
}

# Устанавливает SSL сертификат через Let's Encrypt
_domain_setup_ssl() {
    local domain="$1"

    echo -e "\n${CYAN}━━━ Настройка SSL для ${domain} ━━━${NC}\n"

    # Проверяем резолвинг
    echo -ne "  ${CYAN}→ Проверка DNS...${NC} "
    local resolved_ip
    resolved_ip=$(dig +short "$domain" 2>/dev/null | tail -1 || \
        nslookup "$domain" 2>/dev/null | grep 'Address:' | tail -1 | awk '{print $2}')
    if [ "$resolved_ip" != "$MY_IP" ]; then
        echo -e "${RED}✗${NC}"
        echo -e "  ${RED}Домен ${domain} резолвится в ${resolved_ip:-???}, а не в ${MY_IP}${NC}"
        echo -e "  ${WHITE}Сначала настройте DNS: A-запись ${domain} → ${MY_IP}${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ ${resolved_ip}${NC}"

    # Устанавливаем certbot если нет
    if ! command -v certbot &>/dev/null; then
        echo -e "  ${CYAN}→ Установка certbot...${NC}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y certbot python3-certbot-nginx > /dev/null 2>&1 || \
        apt-get install -y certbot > /dev/null 2>&1
    fi

    # Устанавливаем nginx если нет
    if ! command -v nginx &>/dev/null; then
        echo -e "  ${CYAN}→ Установка nginx...${NC}"
        apt-get install -y nginx > /dev/null 2>&1
        systemctl enable nginx > /dev/null 2>&1
    fi

    # Базовый nginx конфиг для верификации
    local nginx_conf="/etc/nginx/sites-available/${domain}"
    cat > "$nginx_conf" << EOF
server {
    listen 80;
    server_name ${domain};
    root /var/www/html;
    index index.html;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/${domain}" 2>/dev/null
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1

    # Получаем сертификат
    echo -ne "  ${CYAN}→ Получение сертификата Let's Encrypt...${NC} "
    local email="${1}@govpn.local"
    if certbot certonly --nginx -d "$domain" \
        --non-interactive --agree-tos \
        --email "admin@${domain}" \
        --redirect 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        # Fallback: standalone (останавливаем nginx временно)
        echo -e "${YELLOW}nginx метод не сработал, пробую standalone...${NC}"
        systemctl stop nginx 2>/dev/null
        if certbot certonly --standalone -d "$domain" \
            --non-interactive --agree-tos \
            --email "admin@${domain}" 2>/dev/null; then
            echo -e "${GREEN}✓${NC}"
            systemctl start nginx 2>/dev/null
        else
            echo -e "${RED}✗${NC}"
            systemctl start nginx 2>/dev/null
            echo -e "  ${RED}Не удалось получить сертификат.${NC}"
            echo -e "  ${WHITE}Убедитесь что порт 80 открыт и домен резолвится в ${MY_IP}${NC}"
            return 1
        fi
    fi

    # Обновляем nginx с SSL
    cat > "$nginx_conf" << EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    # Заглушка (красивая страница вместо пустого сервера)
    root /var/www/${domain};
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Создаём заглушку
    mkdir -p "/var/www/${domain}"
    _domain_create_stub "/var/www/${domain}" "$domain"

    nginx -t > /dev/null 2>&1 && systemctl reload nginx > /dev/null 2>&1

    # Автообновление сертификата
    if ! crontab -l 2>/dev/null | grep -q 'certbot renew'; then
        (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
        echo -e "  ${GREEN}✓ Автообновление сертификата настроено (ежедневно в 3:00)${NC}"
    fi

    echo -e "\n  ${GREEN}✅ SSL настроен!${NC}"
    echo -e "  ${WHITE}Домен:${NC} ${CYAN}https://${domain}${NC}"
    log_action "DOMAIN: SSL настроен для ${domain}"
}

# Создаёт красивую заглушку
_domain_create_stub() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${domain}</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0f0f10; color: #e5e5e7; min-height: 100vh;
         display: flex; align-items: center; justify-content: center; }
  .card { background: #1c1c1e; border: 1px solid #2c2c2e; border-radius: 16px;
          padding: 48px; max-width: 420px; text-align: center; }
  .icon { font-size: 48px; margin-bottom: 24px; }
  h1 { font-size: 22px; font-weight: 600; margin-bottom: 8px; }
  p  { color: #8e8e93; font-size: 15px; line-height: 1.6; }
</style>
</head>
<body>
  <div class="card">
    <div class="icon">&#128274;</div>
    <h1>${domain}</h1>
    <p>Сервер работает в штатном режиме.</p>
  </div>
</body>
</html>
EOF
}

# Главное меню доменов
domain_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Домен и SSL ━━━${NC}\n"
        _domain_detect_full
        echo ""

        # Адаптивные пункты
        local has_xui_pro=0
        ls /etc/letsencrypt/live/ 2>/dev/null | grep -q 'cdn-one\.org' && has_xui_pro=1
        local has_cert=0
        [ -n "$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README)" ] && has_cert=1

        [ "$has_xui_pro" -eq 0 ] && echo -e "  ${YELLOW}[1]${NC}  Настроить домен + SSL (Let's Encrypt)"
        [ "$has_cert" -eq 1 ]    && echo -e "  ${YELLOW}[2]${NC}  Сменить / добавить домен"
        [ "$has_cert" -eq 1 ]    && echo -e "  ${YELLOW}[3]${NC}  Продлить сертификат вручную"
        [ "$has_cert" -eq 1 ]    && echo -e "  ${YELLOW}[4]${NC}  Обновить заглушку"
        [ "$has_xui_pro" -eq 1 ] && echo -e "  ${WHITE}[i]${NC}  Домен cdn-one.org управляется x-ui-pro автоматически"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        case "$ch" in
            1|2)
                echo -ne "\n  Введите домен (например vpn.example.com): "
                read -r domain < /dev/tty
                [ -z "$domain" ] && continue
                # Предупреждение о клиентах
                local old_domain
                old_domain=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
                if [ -n "$old_domain" ]; then
                    echo -e "\n  ${YELLOW}Внимание!${NC}"
                    echo -e "  ${WHITE}Текущий домен: ${old_domain}${NC}"
                    echo -e "  ${WHITE}• Клиенты AWG — подключаются по IP, смена домена их НЕ затронет${NC}"
                    echo -e "  ${WHITE}• Клиенты 3X-UI на IP — тоже НЕ затронет${NC}"
                    echo -e "  ${RED}• Клиенты 3X-UI с доменом в ссылке — потеряют доступ до обновления ключей${NC}"
                    echo -ne "  Продолжить? (y/n): "; read -r c
                    [[ "$c" != "y" ]] && continue
                fi
                _domain_setup_ssl "$domain"
                read -p "  Enter..."
                ;;
            3)
                echo -e "\n  ${CYAN}→ Принудительное продление...${NC}"
                certbot renew --force-renewal --quiet 2>&1 | tail -5
                systemctl reload nginx 2>/dev/null
                echo -e "  ${GREEN}✓ Готово${NC}"
                read -p "  Enter..."
                ;;
            4)
                local domain_dir
                domain_dir=$(ls /etc/letsencrypt/live/ 2>/dev/null | grep -v README | head -1)
                if [ -n "$domain_dir" ]; then
                    _domain_create_stub "/var/www/${domain_dir}" "$domain_dir"
                    echo -e "  ${GREEN}✓ Заглушка обновлена${NC}"
                else
                    echo -e "  ${YELLOW}Домен не найден${NC}"
                fi
                read -p "  Enter..."
                ;;
            0|"") return ;;
        esac
    done
}


_3xui_reorder_inbounds() {
    clear
    echo -e "\n${CYAN}━━━ Сортировка inbounds по порядку ━━━${NC}\n"

    local db="/etc/x-ui/x-ui.db"

    python3 - << 'PYEOF'
import sqlite3, json, sys

db = '/etc/x-ui/x-ui.db'
conn = sqlite3.connect(db)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')

rows = conn.execute("SELECT id, remark, port FROM inbounds ORDER BY id").fetchall()

print("  Текущий порядок:")
for ib_id, remark, port in rows:
    print(f"    #{ib_id:2d}  {remark:30s}  port:{port}")

print()

# Пересортируем: назначаем новые ID начиная с 1
# Нельзя просто поменять ID из-за внешних ключей, поэтому создаём таблицу порядка
# Используем поле order если есть, иначе просто показываем
cols = [c[1] for c in conn.execute("PRAGMA table_info(inbounds)").fetchall()]
if 'sort_order' in cols or 'displayOrder' in cols:
    print("  Поле сортировки найдено — можно применить")
else:
    print("  Поле сортировки не найдено в этой версии 3X-UI")
    print("  Порядок отображения определяется ID inbound'а")
    print()
    print("  Для изменения порядка рекомендуется:")
    print("  1. Удалить и пересоздать inbounds в нужном порядке через панель")
    print("  2. Или использовать drag&drop в панели 3X-UI")

conn.close()
PYEOF

    echo ""
    read -p "  Enter..." < /dev/tty
}

_nginx_find_ssl_port() {
    # Возвращает nginx SSL порт без proxy_protocol
    # Если все порты с proxy_protocol — создаёт новый
    local all_ports
    all_ports=$(ss -tlnp 2>/dev/null | grep nginx | \
        grep -vE ':443 |:80 ' | grep -oP '\d+\.\d+\.\d+\.\d+:\K[0-9]+|\*:\K[0-9]+|:::\K[0-9]+' | \
        sort -un)

    for _np in $all_ports; do
        local _pp; _pp=$(grep -rn "listen.*${_np}.*proxy_protocol" \
            /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | wc -l)
        if [ "$_pp" -eq 0 ]; then
            echo "$_np"; return 0
        fi
    done

    # Все порты с proxy_protocol — добавляем новый
    local _pp_port; _pp_port=$(echo "$all_ports" | head -1)
    if [ -n "$_pp_port" ]; then
        local _new_port=$(( _pp_port + 10000 ))
        local _conf; _conf=$(grep -rl "listen.*${_pp_port}.*proxy_protocol" \
            /etc/nginx/sites-enabled/ 2>/dev/null | head -1)
        if [ -n "$_conf" ]; then
            # Добавляем listen без proxy_protocol
            sed -i "/listen ${_pp_port} ssl.*proxy_protocol/a\\        listen ${_new_port} ssl http2;" \
                "$_conf" 2>/dev/null
            sed -i "/listen \[::\]:${_pp_port} ssl.*proxy_protocol/a\\        listen [::]:${_new_port} ssl http2;" \
                "$_conf" 2>/dev/null
            nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
            echo "$_new_port"; return 0
        fi
    fi
    echo "17443"
}

_3xui_selfsteal_setup() {
    # Мастер настройки Self-Steal Reality для 3X-UI
    clear
    echo -e "\n${CYAN}━━━ Настройка Self-Steal Reality ━━━${NC}\n"
    echo -e "  ${WHITE}Self-Steal = Xray маскируется под твой СОБСТВЕННЫЙ домен${NC}"
    echo -e "  ${WHITE}Цензор видит легитимный сайт с реальным сертификатом${NC}\n"

    # Определяем домен и порт nginx
    local domain; domain=$(sqlite3 /etc/x-ui/x-ui.db \
        "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null | head -1)
    [ -z "$domain" ] && domain=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    local nginx_ssl_port=""

    echo -e "  ${WHITE}Текущий домен:${NC} ${CYAN}${domain:-не определён}${NC}\n"
    echo -e "  ${WHITE}Обнаруженные Nginx порты с SSL:${NC}"
    ss -tlnp | grep nginx | grep -oP ':\K[0-9]+' | sort -u | while read p; do
        [ "$p" = "80" ] && continue
        echo -e "    ${CYAN}${p}${NC}"
        [ -z "$nginx_ssl_port" ] && nginx_ssl_port="$p"
    done

    echo ""
    echo -e "  ${WHITE}── Диагностика ────────────────────────${NC}"
    echo -e "  ${YELLOW}[1]${NC}  Полная диагностика всех inbounds"
    echo -e "  ${WHITE}── Self-Steal ──────────────────────────${NC}"
    echo -e "  ${YELLOW}[2]${NC}  Мастер Self-Steal (авто)"
    echo -e "  ${YELLOW}[3]${NC}  Инструкция — как сделать вручную"
    echo -e "  ${WHITE}── Управление ──────────────────────────${NC}"
    echo -e "  ${CYAN}[4]${NC}  Установить заглушку сайта"
    echo -e "  ${CYAN}[5]${NC}  Сортировать inbounds по порядку"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор: " ss_ch < /dev/tty

    case "$ss_ch" in
        1) _3xui_selfsteal_diagnose ;;
        2) _3xui_selfsteal_wizard ;;
        3) _3xui_selfsteal_manual ;;
        4) _3xui_install_stub_site ;;
        5) _3xui_reorder_inbounds ;;
        0|"") return ;;
    esac
}

_3xui_selfsteal_diagnose() {
    clear
    echo -e "
${CYAN}━━━ Полная диагностика inbounds ━━━${NC}
"

    cat > /tmp/_govpn_diag.py << 'PYEOF_DIAG'
import sqlite3, json, subprocess, sys

db = '/etc/x-ui/x-ui.db'
conn = sqlite3.connect(db)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')

# Получаем домены с сертификатами
certs = subprocess.run(['certbot','certificates'], capture_output=True, text=True)
local_domains = []
for line in certs.stdout.splitlines():
    if 'Domains:' in line:
        local_domains.append(line.split()[-1])

# Получаем nginx порты
ss_out = subprocess.run(['ss','-tlnp'], capture_output=True, text=True).stdout
nginx_ports = []
for line in ss_out.splitlines():
    if 'nginx' in line:
        import re
        m = re.search(r'[\d.]+:(\d+)', line)
        if m and m.group(1) not in ('80','443'):
            nginx_ports.append(int(m.group(1)))

print(f"  Домены с SSL: {local_domains}")
print(f"  Nginx порты (не 80/443): {nginx_ports}
")

rows = conn.execute("SELECT id, remark, port, enable, stream_settings FROM inbounds").fetchall()

issues = []
for ib_id, remark, port, enable, stream in rows:
    status = "✓" if enable else "✗ (выкл)"
    try:
        ss = json.loads(stream)
        network = ss.get('network', 'tcp')
        security = ss.get('security', 'none')
        rs = ss.get('realitySettings', {})
        target = rs.get('dest', rs.get('target', ''))
        server_names = rs.get('serverNames', [])

        problems = []
        suggestions = []

        if security == 'reality':
            # Проверка Self-Steal
            is_self = '127.0.0.1' in str(target)
            if not is_self:
                problems.append(f"target={target} — чужой домен")
                if local_domains and nginx_ports:
                    suggestions.append(f"Исправь: target=127.0.0.1:{nginx_ports[0]}, serverNames={local_domains[0]}")
            else:
                # Проверяем что порт nginx правильный
                try:
                    tport = int(target.split(':')[-1])
                    if tport not in nginx_ports:
                        problems.append(f"target port {tport} не совпадает с nginx {nginx_ports}")
                except: pass

            # Проверка serverNames
            if server_names and local_domains:
                if not any(d in server_names for d in local_domains):
                    problems.append(f"serverNames={server_names} — не твой домен")
                    suggestions.append(f"serverNames должен быть {local_domains[0]}")

            # gRPC устарел
            if network == 'grpc':
                problems.append("gRPC deprecated — мигрируй на xhttp stream-up")
                suggestions.append("Замени на xhttp mode=stream-up или packet-up")

            # VLESS без flow
            clients = ss.get('settings', {}) if isinstance(ss.get('settings'), dict) else {}
            # Проверяем через БД
            for client in clients.get('clients', []):
                if not client.get('flow') and network in ('tcp',):
                    problems.append("VLESS без flow на TCP — рекомендуется xtls-rprx-vision")

        icon = "🟢" if not problems else "🔴"
        print(f"  {icon} #{ib_id} {remark} (port:{port}, {network}/{security}) {status}")
        for p in problems:
            print(f"      ⚠ {p}")
        for s in suggestions:
            print(f"      → {s}")
        if not problems and security == 'reality':
            print(f"      ✓ Self-Steal: {target}")

    except Exception as e:
        print(f"  ❓ #{ib_id} {remark}: ошибка={e}")

conn.close()
PYEOF_DIAG

    python3 /tmp/_govpn_diag.py
    echo ""
    read -p "  Enter..." < /dev/tty
}

_3xui_selfsteal_manual() {
    clear
    echo -e "\n${CYAN}━━━ Инструкция Self-Steal Reality ━━━${NC}\n"

    local domain; domain=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    local nginx_port; nginx_port=$(ss -tlnp | grep nginx | grep -v ':443\|:80' | \
        grep -oP ':\K[0-9]+' | head -1)

    echo -e "  ${WHITE}Твои данные:${NC}"
    echo -e "  Домен:      ${CYAN}${domain:-cdn-msk.site}${NC}"
    echo -e "  Nginx SSL:  ${CYAN}${nginx_port:-7443}${NC} (уже есть сертификат)${NC}\n"

    echo -e "  ${YELLOW}Шаг 1.${NC} В 3X-UI создай/измени основной inbound:"
    echo -e "  ${WHITE}Protocol:${NC}     vless"
    echo -e "  ${WHITE}Port:${NC}         443"
    echo -e "  ${WHITE}Transport:${NC}    xhttp  mode=packet-up"
    echo -e "  ${WHITE}Path:${NC}         /media/fragments/ (или другой)"
    echo -e "  ${WHITE}Security:${NC}     reality"
    echo -e "  ${WHITE}Dest:${NC}         ${CYAN}127.0.0.1:${nginx_port:-7443}${NC} ← КЛЮЧЕВОЕ"
    echo -e "  ${WHITE}ServerNames:${NC}  ${CYAN}${domain:-cdn-msk.site}${NC}"
    echo -e "  ${WHITE}uTLS:${NC}         chrome\n"

    echo -e "  ${YELLOW}Шаг 2.${NC} Nginx должен слушать на ${nginx_port:-7443} с реальным сертификатом"
    echo -e "  ${GREEN}✓ У тебя nginx уже на ${nginx_port:-7443} — готово${NC}\n"

    echo -e "  ${YELLOW}Шаг 3.${NC} Проверка: зайди в браузере на https://${domain:-cdn-msk.site}"
    echo -e "  Должен открыться твой сайт (Xray пропустит браузер на Nginx)\n"

    echo -e "  ${YELLOW}Шаг 4.${NC} Замени index.html на легитимную заглушку"
    echo -e "  ${CYAN}ls /var/www/html/${NC}\n"

    echo -e "  ${WHITE}Для xHTTP(warp) inbound тот же принцип:${NC}"
    echo -e "  ${WHITE}Dest:${NC} ${CYAN}127.0.0.1:${nginx_port:-7443}${NC}"
    echo -e "  ${WHITE}ServerNames:${NC} ${CYAN}${domain:-cdn-msk.site}${NC}"
    echo -e "  ${WHITE}Path:${NC} /api/v1/stream/ (другой путь)\n"

    echo -e "  ${YELLOW}Важно:${NC} путь в xHTTP должен отличаться для каждого inbound!"
    read -p "  Enter..." < /dev/tty
}

_3xui_selfsteal_wizard() {
    clear
    echo -e "\n${CYAN}━━━ Мастер Self-Steal (авто) ━━━${NC}\n"

    local domain; domain=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    local nginx_port; nginx_port=$(_nginx_find_ssl_port)
    echo -e "  ${CYAN}Nginx SSL порт (без proxy_protocol): ${nginx_port}${NC}"

    if [ -z "$domain" ]; then
        echo -e "  ${RED}✗ Домен не найден${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    echo -e "  ${WHITE}Домен:${NC}      ${CYAN}${domain}${NC}"
    echo -e "  ${WHITE}Nginx:${NC}      ${CYAN}127.0.0.1:${nginx_port}${NC}\n"

    local db="/etc/x-ui/x-ui.db"

    # Пишем Python скрипт во временный файл и запускаем
    cat > /tmp/_govpn_ss.py << 'PYEOF_SS'
import json, sys, sqlite3, os

db = sys.argv[1]
domain = sys.argv[2]
nginx_port = int(sys.argv[3])
mode = sys.argv[4] if len(sys.argv) > 4 else 'check'

SKIP_NETWORKS = ('grpc',)

conn = sqlite3.connect(db)
conn.text_factory = lambda b: b.decode('utf-8', errors='surrogateescape')

rows = conn.execute(
    "SELECT id, remark, stream_settings FROM inbounds WHERE stream_settings LIKE '%reality%'"
).fetchall()

changed = 0
for ib_id, remark, stream in rows:
    try:
        ss = json.loads(stream)
        network = ss.get('network', 'tcp')
        rs = ss.get('realitySettings', {})
        cur_target = rs.get('dest', rs.get('target', '?'))
        is_self = '127.0.0.1' in str(cur_target)

        if network in SKIP_NETWORKS:
            if mode == 'check':
                print(f"  ⚪ #{ib_id} {remark} ({network}) — пропущен (deprecated)")
            continue

        if mode == 'check':
            status = '✓ Self-Steal' if is_self else '⚠ нужно исправить'
            print(f"  #{ib_id} {remark} ({network})")
            print(f"      target: {cur_target}  {status}")
        else:
            # Пропускаем если уже Self-Steal с правильным доменом
            if is_self and domain in rs.get('serverNames', []):
                print(f"  ✓ #{ib_id} {remark}: уже настроен ({cur_target})")
                continue
            old_target = cur_target
            rs['dest'] = f'127.0.0.1:{nginx_port}'
            rs['target'] = f'127.0.0.1:{nginx_port}'
            rs['serverNames'] = [domain]
            ss['realitySettings'] = rs
            new_ss = json.dumps(ss, ensure_ascii=False)
            conn.execute("UPDATE inbounds SET stream_settings=? WHERE id=?", (new_ss, ib_id))
            conn.commit()
            print(f"  ✓ #{ib_id} {remark}: {old_target} → 127.0.0.1:{nginx_port}")
            changed += 1
    except Exception as e:
        print(f"  ✗ #{ib_id} {remark}: {e}")

conn.close()
if mode == 'apply':
    print(f"CHANGED:{changed}")
PYEOF_SS

    python3 /tmp/_govpn_ss.py "$db" "$domain" "$nginx_port" check

    echo ""
    echo -ne "  ${YELLOW}Применить Self-Steal? (y/n):${NC} "
    read -r confirm < /dev/tty
    [ "$confirm" != "y" ] && return

    local result
    result=$(python3 /tmp/_govpn_ss.py "$db" "$domain" "$nginx_port" apply)
    echo "$result" | grep -v '^CHANGED:'
    local cnt; cnt=$(echo "$result" | grep '^CHANGED:' | cut -d: -f2)

    if [ "${cnt:-0}" -gt 0 ]; then
        systemctl restart x-ui > /dev/null 2>&1; sleep 2
        echo -e "\n  ${GREEN}✓ Применено: ${cnt} inbound(s), xray перезапущен${NC}"
        echo -e "  ${WHITE}Проверь: https://${domain}${NC}"
        echo ""
        echo -ne "  ${YELLOW}Установить заглушку CinemaLab? (y/n):${NC} "
        read -r inst < /dev/tty
        [ "$inst" = "y" ] && _3xui_install_stub_site
    fi
    read -p "  Enter..." < /dev/tty
}



_3xui_install_stub_site() {
    clear
    echo -e "
${CYAN}━━━ Установка заглушки сайта ━━━${NC}
"

    # Определяем домен
    local domain
    domain=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    if [ -z "$domain" ]; then
        domain=$(grep -rh "server_name" /etc/nginx/sites-enabled/ 2>/dev/null |             grep -v "localhost\|_\|#" | grep -oP "server_name\s+\K\S+" | grep "\." | head -1)
    fi

    if [ -n "$domain" ]; then
        echo -e "  ${WHITE}Домен:${NC} ${CYAN}${domain}${NC}"
        local _yn; _yn=$(read_yn "  Использовать этот домен? (y/n): ")
        if [ "$_yn" != "y" ]; then
            echo -ne "  Введите домен: "; read -r domain < /dev/tty
        fi
    else
        echo -ne "  Введите домен: "; read -r domain < /dev/tty
    fi

    [ -z "$domain" ] && return

    local webroot="/var/www/${domain}"
    mkdir -p "$webroot"

    # Вызываем общее меню шаблонов
    _stub_templates "$domain" "$webroot"

    # Если nginx конфига нет — создаём базовый
    local nginx_conf="/etc/nginx/sites-available/${domain}"
    if [ ! -f "$nginx_conf" ]; then
        _stub_setup_full "$domain"
    else
        nginx -t && systemctl reload nginx 2>/dev/null
        echo -e "  ${GREEN}✓ Заглушка обновлена${NC}"
    fi
    sleep 2
}

_stub_cinemalab() {
    cat > "$1/index.html" << 'STUBEND'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>CinemaLab | Студия видеопроизводства</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-white"><nav class="bg-white border-b py-4 px-6 flex justify-between items-center"><span class="text-2xl font-bold">Cinema<span class="text-red-600">Lab</span></span><button class="bg-slate-900 text-white px-5 py-2 rounded text-sm">Вход для клиентов</button></nav>
<header class="h-96 flex items-center justify-center bg-gradient-to-br from-slate-900 to-slate-700"><div class="text-center text-white"><h1 class="text-5xl font-bold mb-4">Профессиональное видеопроизводство</h1><p class="text-slate-300 text-lg">4K/8K • Collaborative Workflow • 450 ГБ/сутки</p></div></header>
<section class="py-16 max-w-4xl mx-auto px-6"><h2 class="text-3xl font-bold mb-4">Удалённый монтаж</h2><p class="text-slate-600">Синхронизация проектов в реальном времени через высокоскоростное облачное хранилище. Adobe Premiere & DaVinci Resolve.</p></section>
<footer class="bg-slate-900 text-slate-400 py-8 text-center">CinemaLab 2026 • Москва</footer></body></html>
STUBEND
}

_stub_techcorp() {
    cat > "$1/index.html" << 'STUBEND'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>TechCorp | Корпоративные IT решения</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-50"><nav class="bg-white shadow py-4 px-8 flex justify-between items-center"><span class="text-xl font-bold text-blue-600">TechCorp</span><div class="space-x-6 text-sm text-gray-600"><a href="#" class="hover:text-blue-600">Услуги</a><a href="#" class="hover:text-blue-600">Клиенты</a><a href="#" class="hover:text-blue-600">Контакты</a></div></nav>
<header class="bg-blue-700 text-white py-24 px-8 text-center"><h1 class="text-4xl font-bold mb-4">Корпоративная IT инфраструктура</h1><p class="text-blue-200 text-lg">Защищённые каналы связи • VPN решения • 24/7 поддержка</p></header>
<section class="py-16 max-w-5xl mx-auto px-8 grid grid-cols-3 gap-8"><div class="bg-white rounded-lg p-6 shadow"><h3 class="font-bold text-lg mb-2">🔒 Безопасность</h3><p class="text-gray-600 text-sm">Корпоративные VPN, шифрование данных, защита периметра</p></div><div class="bg-white rounded-lg p-6 shadow"><h3 class="font-bold text-lg mb-2">☁️ Облако</h3><p class="text-gray-600 text-sm">Гибридные облачные решения, резервное копирование</p></div><div class="bg-white rounded-lg p-6 shadow"><h3 class="font-bold text-lg mb-2">📡 Сети</h3><p class="text-gray-600 text-sm">Проектирование и обслуживание корпоративных сетей</p></div></section>
<footer class="bg-gray-800 text-gray-400 py-8 text-center text-sm">© 2026 TechCorp LLC • Все права защищены</footer></body></html>
STUBEND
}

_stub_cloudstorage() {
    cat > "$1/index.html" << 'STUBEND'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>CloudDrive | Безопасное облачное хранилище</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gradient-to-br from-indigo-50 to-blue-50 min-h-screen"><nav class="bg-white/80 backdrop-blur py-4 px-8 flex justify-between items-center shadow-sm"><span class="text-xl font-bold text-indigo-600">☁ CloudDrive</span><button class="bg-indigo-600 text-white px-6 py-2 rounded-full text-sm">Войти</button></nav>
<header class="text-center py-24 px-8"><h1 class="text-5xl font-bold text-gray-800 mb-6">Ваши данные <span class="text-indigo-600">в безопасности</span></h1><p class="text-gray-500 text-xl mb-8">Зашифрованное хранилище для бизнеса и частных лиц. До 10 ТБ на аккаунт.</p><button class="bg-indigo-600 text-white px-10 py-4 rounded-full text-lg hover:bg-indigo-700">Начать бесплатно</button></header>
<section class="max-w-4xl mx-auto px-8 pb-16 grid grid-cols-2 gap-6"><div class="bg-white rounded-2xl p-6 shadow-sm"><div class="text-3xl mb-3">🔐</div><h3 class="font-bold mb-2">Шифрование AES-256</h3><p class="text-gray-500 text-sm">Данные зашифрованы до загрузки на сервер</p></div><div class="bg-white rounded-2xl p-6 shadow-sm"><div class="text-3xl mb-3">⚡</div><h3 class="font-bold mb-2">Высокая скорость</h3><p class="text-gray-500 text-sm">До 10 Гбит/с для корпоративных клиентов</p></div></section>
<footer class="text-center py-8 text-gray-400 text-sm">© 2026 CloudDrive Inc.</footer></body></html>
STUBEND
}


system_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Система и управление ━━━${NC}\n"

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

        # Бэкапы — кол-во и дата последнего
        local bak_count bak_last=""
        bak_count=$(ls "${BACKUP_DIR}"/govpn-backup-*.tar.gz 2>/dev/null | wc -l)
        [ "$bak_count" -gt 0 ] && bak_last=$(ls -t "${BACKUP_DIR}"/govpn-backup-*.tar.gz 2>/dev/null | head -1 | \
            xargs basename 2>/dev/null | grep -oE '[0-9]{8}-[0-9]{6}' | \
            sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\).*/\1-\2-\3 \4:\5/')
        echo -e "  ${WHITE}Бэкапов:${NC} ${CYAN}${bak_count}${NC}$([ -n "$bak_last" ] && echo "  последний: ${bak_last}")"

        # Домен
        local domain_info; domain_info=$(_domain_detect_short)
        echo -e "  ${WHITE}Домен:${NC}   ${domain_info}"

        echo ""
        echo -e " ${CYAN}── Обслуживание ──────────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  Бэкапы и восстановление"
        echo -e "  ${YELLOW}[2]${NC}  Обновить скрипт"
        echo -e "  ${YELLOW}[3]${NC}  Диагностика зависимостей"
        echo -e "  ${YELLOW}[4]${NC}  Проверка конфликтов"
        echo ""
        echo -e " ${CYAN}── Сервисы ───────────────────────────${NC}"
        is_3xui   && echo -e "  ${YELLOW}[5]${NC}  Перезапустить x-ui"
        is_3xui   && echo -e "  ${YELLOW}[6]${NC}  Перезапустить WARP (3X-UI)"
        is_amnezia && echo -e "  ${YELLOW}[7]${NC}  Перезапустить AWG контейнер"
        echo ""
        echo -e " ${CYAN}── Сервер ────────────────────────────${NC}"
        echo -e "  ${YELLOW}[8]${NC}  Домен и SSL"
        echo -e "  ${YELLOW}[9]${NC}  Установка и компоненты"
        is_3xui && echo -e "  ${CYAN}[s]${NC}  Self-Steal Reality (настройка маскировки)"
        echo -e "  ${YELLOW}[r]${NC}  Перезагрузить сервер"
        echo ""
        echo -e " ${CYAN}── Опасная зона ──────────────────────${NC}"
        echo -e "  ${RED}[x]${NC}  Полное удаление GoVPN"
        echo ""
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""

        local ch; ch=$(read_choice "Выбор: ")
        case "$ch" in
            1) _backups_menu ;;
            2) _self_update ;;
            3) _check_deps_full ;;
            4) _check_conflicts ;;
            5)
                is_3xui || continue
                echo -ne "  ${YELLOW}Перезапуск x-ui...${NC} "
                systemctl restart x-ui 2>/dev/null && echo -e "${GREEN}✓ OK${NC}" || echo -e "${RED}✗ Ошибка${NC}"
                read -p "  Enter..."
                ;;
            6)
                is_3xui || continue
                echo -ne "  ${YELLOW}Перезапуск WARP...${NC} "
                systemctl restart warp-svc 2>/dev/null
                sleep 2; warp-cli --accept-tos connect > /dev/null 2>&1
                sleep 3
                _3xui_warp_running && echo -e "${GREEN}✓ подключён${NC}" || echo -e "${RED}✗ не подключился${NC}"
                read -p "  Enter..."
                ;;
            7)
                is_amnezia || continue
                echo -ne "  ${YELLOW}Перезапуск ${AWG_CONTAINER}...${NC} "
                docker restart "$AWG_CONTAINER" > /dev/null 2>&1 && \
                    echo -e "${GREEN}✓ OK${NC}" || echo -e "${RED}✗ Ошибка${NC}"
                read -p "  Enter..."
                ;;
            8) domain_menu ;;
            9) install_wizard ;;
            r|R)
                read -p "$(echo -e "  ${RED}Перезагрузить сервер? (y/n): ${NC}")" c
                [[ "$c" == "y" ]] && reboot
                ;;
            [sS]) is_3xui && _3xui_selfsteal_setup ;;
            x|X)
                _full_uninstall
                ;;
            0|"") return ;;
        esac
    done
}

#  СИСТЕМА БЭКАПОВ
# ═══════════════════════════════════════════════════════════════

# Создаёт полный бэкап в BACKUP_DIR/govpn-backup-TIMESTAMP.tar.gz
# Возвращает путь к созданному архиву (или пустую строку при ошибке)
do_backup() {
    local silent="${1:-0}"   # 1 = не печатать прогресс
    mkdir -p "$BACKUP_DIR"

    local ts; ts=$(date +%s)
    local label; label=$(date -d "@${ts}" '+%Y%m%d-%H%M%S' 2>/dev/null || date '+%Y%m%d-%H%M%S')
    local archive="${BACKUP_DIR}/govpn-backup-${label}.tar.gz"
    local staging; staging=$(mktemp -d /tmp/govpn_bak_XXXXXX)
    local ok=0

    _bak_log() { [ "$silent" -eq 0 ] && echo -e "  ${CYAN}$*${NC}"; }

    # — govpn скрипт
    _bak_log "→ govpn скрипт"
    cp "$INSTALL_PATH" "${staging}/govpn.sh" 2>/dev/null && ok=1

    # — конфиг и алиасы
    _bak_log "→ конфигурация govpn"
    cp "$CONF_FILE"   "${staging}/config"   2>/dev/null || true
    cp "$ALIASES_FILE" "${staging}/aliases" 2>/dev/null || true

    # — x-ui.db (3X-UI)
    if is_3xui && [ -f "/etc/x-ui/x-ui.db" ]; then
        _bak_log "→ 3X-UI база (x-ui.db)"
        cp /etc/x-ui/x-ui.db "${staging}/x-ui.db" 2>/dev/null && ok=1
        [ -f "/usr/local/x-ui/bin/config.json" ] && \
            cp /usr/local/x-ui/bin/config.json "${staging}/x-ui-config.json" 2>/dev/null || true
    fi

    # — AWG clientsTable + конфиг
    if is_amnezia && [ -n "$AWG_CONTAINER" ]; then
        _bak_log "→ AWG clientsTable"
        docker cp "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" \
            "${staging}/awg-clientsTable" 2>/dev/null && ok=1
        local awg_conf; awg_conf=$(_awg_conf)
        if [ -n "$awg_conf" ]; then
            _bak_log "→ AWG конфиг (${awg_conf##*/})"
            docker cp "${AWG_CONTAINER}:${awg_conf}" \
                "${staging}/awg-$(basename "$awg_conf")" 2>/dev/null || true
        fi
    fi

    # — WARP ключи (внутри AWG контейнера)
    if is_amnezia && [ -n "$AWG_CONTAINER" ]; then
        if docker exec "$AWG_CONTAINER" sh -c "[ -f '${AWG_WARP_CONF}' ]" 2>/dev/null; then
            _bak_log "→ WARP конфиг (warp.conf)"
            docker cp "${AWG_CONTAINER}:${AWG_WARP_CONF}" \
                "${staging}/warp.conf" 2>/dev/null || true
            docker cp "${AWG_CONTAINER}:${AWG_WARP_DIR}/wgcf-account.toml" \
                "${staging}/wgcf-account.toml" 2>/dev/null || true
        fi
        if docker exec "$AWG_CONTAINER" sh -c "[ -f '${AWG_CLIENTS_FILE}' ]" 2>/dev/null; then
            _bak_log "→ WARP clients.list"
            docker cp "${AWG_CONTAINER}:${AWG_CLIENTS_FILE}" \
                "${staging}/warp-clients.list" 2>/dev/null || true
        fi
    fi

    # — WARP ключи (3X-UI / хостовой warp-cli)
    if is_3xui; then
        for f in /var/lib/cloudflare-warp/reg.json /var/lib/cloudflare-warp/mdm.xml; do
            [ -f "$f" ] && cp "$f" "${staging}/$(basename "$f")" 2>/dev/null || true
        done
    fi

    # Пакуем
    if [ "$ok" -eq 1 ]; then
        tar -czf "$archive" -C "$staging" . 2>/dev/null
        rm -rf "$staging"
        [ "$silent" -eq 0 ] && \
            echo -e "\n  ${GREEN}✅ Бэкап: ${WHITE}$(basename "$archive")${NC}  $(du -sh "$archive" 2>/dev/null | cut -f1)"
        log_action "BACKUP: $(basename "$archive")"
        echo "$archive"
    else
        rm -rf "$staging"
        [ "$silent" -eq 0 ] && echo -e "  ${RED}✗ Нечего бэкапить — нет данных${NC}"
    fi
}

# Тихий автобэкап перед опасными операциями (вызывать одной строкой)
_backup_auto() {
    do_backup 1 > /dev/null 2>&1
}

# Восстановление из архива
_backup_restore() {
    local archive="$1"
    [ -f "$archive" ] || { echo -e "${RED}Файл не найден: $archive${NC}"; return 1; }

    local staging; staging=$(mktemp -d /tmp/govpn_restore_XXXXXX)
    tar -xzf "$archive" -C "$staging" 2>/dev/null || {
        rm -rf "$staging"
        echo -e "${RED}✗ Не удалось распаковать архив${NC}"; return 1
    }

    local restored=0

    # x-ui.db
    if [ -f "${staging}/x-ui.db" ] && is_3xui; then
        echo -ne "  Восстановить x-ui.db? (y/n): "; read -r c
        if [[ "$c" == "y" ]]; then
            cp /etc/x-ui/x-ui.db "${BACKUP_DIR}/x-ui.db.pre-restore.$(date +%s)" 2>/dev/null || true
            cp "${staging}/x-ui.db" /etc/x-ui/x-ui.db
            systemctl restart x-ui > /dev/null 2>&1
            echo -e "  ${GREEN}✓ x-ui.db восстановлен, x-ui перезапущен${NC}"
            (( restored++ ))
        fi
    fi

    # x-ui config.json
    if [ -f "${staging}/x-ui-config.json" ] && is_3xui; then
        local cfg="/usr/local/x-ui/bin/config.json"
        [ -f "$cfg" ] && { echo -ne "  Восстановить config.json? (y/n): "; read -r c
            if [[ "$c" == "y" ]]; then
                cp "${staging}/x-ui-config.json" "$cfg"
                systemctl restart x-ui > /dev/null 2>&1
                echo -e "  ${GREEN}✓ config.json восстановлен${NC}"
                (( restored++ ))
            fi
        }
    fi

    # AWG clientsTable
    if [ -f "${staging}/awg-clientsTable" ] && is_amnezia && [ -n "$AWG_CONTAINER" ]; then
        echo -ne "  Восстановить AWG clientsTable? (y/n): "; read -r c
        if [[ "$c" == "y" ]]; then
            docker exec "$AWG_CONTAINER" sh -c \
                "cp /opt/amnezia/awg/clientsTable /opt/amnezia/awg/clientsTable.pre-restore.\$(date +%s) 2>/dev/null || true"
            docker cp "${staging}/awg-clientsTable" \
                "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" 2>/dev/null
            echo -e "  ${GREEN}✓ clientsTable восстановлен${NC}"
            (( restored++ ))
        fi
    fi

    # WARP конфиг
    if [ -f "${staging}/warp.conf" ] && is_amnezia && [ -n "$AWG_CONTAINER" ]; then
        echo -ne "  Восстановить warp.conf? (y/n): "; read -r c
        if [[ "$c" == "y" ]]; then
            docker exec "$AWG_CONTAINER" sh -c "mkdir -p '${AWG_WARP_DIR}'" 2>/dev/null
            docker cp "${staging}/warp.conf" "${AWG_CONTAINER}:${AWG_WARP_CONF}" 2>/dev/null
            [ -f "${staging}/wgcf-account.toml" ] && \
                docker cp "${staging}/wgcf-account.toml" \
                    "${AWG_CONTAINER}:${AWG_WARP_DIR}/wgcf-account.toml" 2>/dev/null || true
            echo -e "  ${GREEN}✓ warp.conf восстановлен${NC}"
            (( restored++ ))
        fi
    fi

    # govpn скрипт
    if [ -f "${staging}/govpn.sh" ]; then
        echo -ne "  Восстановить govpn скрипт? (y/n): "; read -r c
        if [[ "$c" == "y" ]]; then
            cp "${staging}/govpn.sh" "$INSTALL_PATH"
            chmod +x "$INSTALL_PATH"
            echo -e "  ${GREEN}✓ govpn восстановлен (перезапуск...)${NC}"
            rm -rf "$staging"
            log_action "ROLLBACK: $archive (${restored} компонентов)"
            sleep 1; exec "$INSTALL_PATH"
        fi
    fi

    rm -rf "$staging"

    if [ "$restored" -gt 0 ]; then
        echo -e "\n  ${GREEN}Восстановлено компонентов: ${restored}${NC}"
        log_action "ROLLBACK: $archive (${restored} компонентов)"
    else
        echo -e "  ${YELLOW}Ничего не восстановлено${NC}"
    fi
}

_backups_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Бэкапы и восстановление ━━━${NC}\n"

        # Список архивов
        local -a bak_arr=()
        while IFS= read -r b; do
            [ -f "$b" ] && bak_arr+=("$b")
        done < <(ls -t "${BACKUP_DIR}"/govpn-backup-*.tar.gz 2>/dev/null)

        # Старые одиночные бэкапы (обратная совместимость)
        local -a old_arr=()
        while IFS= read -r b; do
            [ -f "$b" ] && old_arr+=("$b")
        done < <(ls -t "${BACKUP_DIR}"/*.bak.* 2>/dev/null)

        if [ ${#bak_arr[@]} -eq 0 ] && [ ${#old_arr[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}Бэкапов ещё нет.${NC}\n"
        else
            echo -e "  ${WHITE}Полные архивы:${NC}"
            if [ ${#bak_arr[@]} -eq 0 ]; then
                echo -e "  ${YELLOW}  нет${NC}"
            else
                local i=1
                for b in "${bak_arr[@]}"; do
                    local ts; ts=$(basename "$b" | grep -oE '[0-9]{8}-[0-9]{6}')
                    local dt="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}"
                    local sz; sz=$(du -sh "$b" 2>/dev/null | cut -f1)
                    echo -e "  ${YELLOW}[$i]${NC}  ${dt}  ${WHITE}$(basename "$b")${NC}  ${CYAN}${sz}${NC}"
                    (( i++ ))
                done
            fi

            if [ ${#old_arr[@]} -gt 0 ]; then
                echo -e "\n  ${WHITE}Старые бэкапы (отдельные файлы):${NC}"
                local j=$(( ${#bak_arr[@]} + 1 ))
                for b in "${old_arr[@]}"; do
                    local ts; ts=$(basename "$b" | grep -oE '[0-9]{10,}$')
                    local dt; dt=$(date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
                    local sz; sz=$(du -sh "$b" 2>/dev/null | cut -f1)
                    echo -e "  ${YELLOW}[$j]${NC}  ${dt}  ${WHITE}$(basename "$b")${NC}  ${CYAN}${sz}${NC}"
                    bak_arr+=("$b")
                    (( j++ ))
                done
            fi
            echo ""
        fi

        echo -e "  ${GREEN}[c]${NC}  Создать бэкап сейчас"
        echo -e "  ${YELLOW}[r]${NC}  Восстановить из бэкапа (выбрать номер)"
        echo -e "  ${RED}[d]${NC}  Удалить старые (оставить 5 последних)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            c|C|с|С)
                echo ""
                do_backup 0
                read -p "  Enter..."
                ;;
            r|R|р|Р)
                if [ ${#bak_arr[@]} -eq 0 ]; then
                    echo -e "  ${YELLOW}Нет бэкапов для восстановления${NC}"
                    read -p "  Enter..."; continue
                fi
                echo -ne "\n  Номер бэкапа для восстановления: "
                read -r ch2 < /dev/tty
                [[ "$ch2" =~ ^[0-9]+$ ]] && (( ch2 >= 1 && ch2 <= ${#bak_arr[@]} )) || continue
                local chosen="${bak_arr[$((ch2-1))]}"
                echo ""
                if [[ "$chosen" == *.tar.gz ]]; then
                    _backup_restore "$chosen"
                else
                    # Старый формат — одиночный файл
                    read -p "  Восстановить $(basename "$chosen")? (y/n): " c
                    [[ "$c" != "y" ]] && continue
                    if [[ "$chosen" == *"x-ui.db"* ]]; then
                        cp "$chosen" /etc/x-ui/x-ui.db
                        systemctl restart x-ui > /dev/null 2>&1
                        echo -e "  ${GREEN}✓ x-ui.db восстановлен${NC}"
                    elif [[ "$chosen" == *"config.json"* ]]; then
                        cp "$chosen" /usr/local/x-ui/bin/config.json 2>/dev/null
                        systemctl restart x-ui > /dev/null 2>&1
                        echo -e "  ${GREEN}✓ config.json восстановлен${NC}"
                    fi
                    log_action "ROLLBACK: $chosen"
                fi
                read -p "  Enter..."
                ;;
            d|D|д|Д)
                echo ""
                local cnt=0

                # — полные архивы .tar.gz (оставить 5 новейших)
                local -a tgz_list=()
                while IFS= read -r b; do [ -f "$b" ] && tgz_list+=("$b"); done \
                    < <(ls -t "${BACKUP_DIR}"/govpn-backup-*.tar.gz 2>/dev/null)
                local tgz_total=${#tgz_list[@]}
                if [ "$tgz_total" -gt 5 ]; then
                    echo -e "  ${WHITE}Полные архивы:${NC} ${tgz_total} → оставить 5, удалить $(( tgz_total - 5 ))"
                    echo -ne "  Подтвердить? (y/n): "; read -r c
                    if [[ "$c" == "y" ]]; then
                        for (( idx=5; idx<tgz_total; idx++ )); do
                            rm -f "${tgz_list[$idx]}" && (( cnt++ ))
                        done
                    fi
                else
                    echo -e "  ${YELLOW}Полных архивов ${tgz_total} — меньше порога (5), не трогаем${NC}"
                fi

                # — старые одиночные .bak.* (удалить все, они устарели)
                local -a old_list=()
                while IFS= read -r b; do [ -f "$b" ] && old_list+=("$b"); done \
                    < <(ls -t "${BACKUP_DIR}"/*.bak.* 2>/dev/null)
                local old_total=${#old_list[@]}
                if [ "$old_total" -gt 0 ]; then
                    echo -e "  ${WHITE}Старые одиночные бэкапы:${NC} ${old_total} файлов (устаревший формат)"
                    echo -ne "  Удалить все? (y/n): "; read -r c
                    if [[ "$c" == "y" ]]; then
                        for b in "${old_list[@]}"; do
                            rm -f "$b" && (( cnt++ ))
                        done
                    fi
                fi

                if [ "$cnt" -gt 0 ]; then
                    echo -e "  ${GREEN}Удалено файлов: ${cnt}${NC}"
                    log_action "BACKUP CLEANUP: удалено ${cnt} файлов"
                else
                    echo -e "  ${YELLOW}Ничего не удалено${NC}"
                fi
                read -p "  Enter..."
                ;;
            0|"") return ;;
        esac
    done
}

_check_deps_full() {
    clear
    echo -e "\n${CYAN}━━━ Диагностика зависимостей ━━━${NC}\n"

    local ok=0 warn=0 fail=0
    local need_fix=()

    _dep_check() {
        local name="$1" check_cmd="$2" fix_cmd="$3" fix_label="$4"
        echo -ne "  ${WHITE}${name}:${NC} "
        if eval "$check_cmd" &>/dev/null 2>&1; then
            local ver; ver=$(eval "$check_cmd" 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d.]+' | head -1)
            echo -e "${GREEN}✓${NC}${ver:+  ${ver}}"
            (( ok++ ))
        else
            echo -e "${RED}✗ не найден${NC}"
            (( fail++ ))
            [ -n "$fix_cmd" ] && need_fix+=("${name}|${fix_cmd}|${fix_label}")
        fi
    }

    _dep_warn() {
        local name="$1" check_cmd="$2" note="$3"
        echo -ne "  ${WHITE}${name}:${NC} "
        if eval "$check_cmd" &>/dev/null 2>&1; then
            echo -e "${GREEN}✓${NC}"
            (( ok++ ))
        else
            echo -e "${YELLOW}⚠ ${note}${NC}"
            (( warn++ ))
        fi
    }

    echo -e "  ${CYAN}── Обязательные ──────────────────────${NC}"
    _dep_check "curl"      "curl --version"         "apt-get install -y curl"      "установить curl"
    _dep_check "python3"   "python3 --version"      "apt-get install -y python3"   "установить python3"
    _dep_check "iptables"  "iptables --version"     "apt-get install -y iptables"  "установить iptables"
    _dep_check "docker"    "docker --version"       ""                             ""

    echo ""
    echo -e "  ${CYAN}── AWG (amnezia) ─────────────────────${NC}"
    if is_amnezia; then
        _dep_check "wgcf"   "wgcf --version"  \
            "arch=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); curl -fsSL https://github.com/ViRb3/wgcf/releases/download/v${WGCF_VER}/wgcf_${WGCF_VER}_linux_\${arch} -o /usr/local/bin/wgcf && chmod +x /usr/local/bin/wgcf" \
            "скачать wgcf"
        _dep_warn "python3-yaml" "python3 -c 'import yaml'" "нужен для управления пользователями (apt-get install -y python3-yaml)"
        _dep_warn "qrencode"  "command -v qrencode"  "нужен для QR-кодов (apt-get install -y qrencode)"
        # Контейнер
        echo -ne "  ${WHITE}AWG контейнер:${NC} "
        if [ -n "$AWG_CONTAINER" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${AWG_CONTAINER}$"; then
            echo -e "${GREEN}✓ ${AWG_CONTAINER}${NC}"
            (( ok++ ))
        else
            echo -e "${RED}✗ не запущен${NC}"
            (( fail++ ))
        fi
    else
        echo -e "  ${WHITE}(режим не amnezia — пропуск)${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}── 3X-UI ─────────────────────────────${NC}"
    if is_3xui; then
        echo -ne "  ${WHITE}x-ui сервис:${NC} "
        systemctl is-active x-ui &>/dev/null 2>&1 && \
            echo -e "${GREEN}✓ активен${NC}" && (( ok++ )) || \
            { echo -e "${RED}✗ не запущен${NC}"; (( fail++ )); }
        echo -ne "  ${WHITE}x-ui.db:${NC} "
        [ -f /etc/x-ui/x-ui.db ] && \
            echo -e "${GREEN}✓${NC}  $(du -sh /etc/x-ui/x-ui.db 2>/dev/null | cut -f1)" && (( ok++ )) || \
            { echo -e "${RED}✗ не найден${NC}"; (( fail++ )); }
        _dep_warn "sqlite3" "command -v sqlite3" "нужен для некоторых операций (apt-get install -y sqlite3)"
    else
        echo -e "  ${WHITE}(режим не 3xui — пропуск)${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}── Инструменты ───────────────────────${NC}"
    echo -ne "  ${WHITE}RealiTLScanner:${NC} "
    if [ -f /usr/local/bin/RealiTLScanner ]; then
        echo -e "${GREEN}✓${NC}"
        (( ok++ ))
    else
        echo -e "${YELLOW}⚠ не установлен${NC}  (скачивается при первом использовании)"
        (( warn++ ))
    fi

    _dep_warn "openssl"   "command -v openssl"  "нужен для сертификатов (apt-get install -y openssl)"
    _dep_warn "wireguard" "command -v wg-quick" "нужен для WARP (apt-get install -y wireguard-tools)"
    _dep_warn "ufw"       "command -v ufw"      "опционально (apt-get install -y ufw)"

    echo ""
    echo -e "  ${CYAN}── WARP ──────────────────────────────${NC}"
    if is_amnezia; then
        echo -ne "  ${WHITE}WARP в AWG:${NC} "
        _awg_warp_running 2>/dev/null && \
            echo -e "${GREEN}✓ активен${NC}" && (( ok++ )) || \
            echo -e "${YELLOW}⚠ не настроен${NC}" && (( warn++ )) || true
    fi
    if is_3xui; then
        echo -ne "  ${WHITE}warp-cli:${NC} "
        command -v warp-cli &>/dev/null && \
            { _3xui_warp_running && echo -e "${GREEN}✓ подключён${NC}" || echo -e "${YELLOW}⚠ установлен, не подключён${NC}"; } && \
            (( ok++ )) || { echo -e "${YELLOW}⚠ не установлен${NC}"; (( warn++ )); }
    fi

    echo ""
    echo -e "  ${CYAN}── Сеть ──────────────────────────────${NC}"
    echo -ne "  ${WHITE}Внешний IP:${NC} "
    [ -n "$MY_IP" ] && echo -e "${GREEN}${MY_IP}${NC}" && (( ok++ )) || \
        { echo -e "${RED}✗ не определён${NC}"; (( fail++ )); }

    echo -ne "  ${WHITE}IP forwarding:${NC} "
    [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] && \
        echo -e "${GREEN}✓${NC}" && (( ok++ )) || \
        echo -e "${YELLOW}⚠ выключен${NC}" && (( warn++ )) || true

    # Итог
    echo ""
    echo -e "  ${MAGENTA}══════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓ OK: ${ok}${NC}  ${YELLOW}⚠ Warn: ${warn}${NC}  ${RED}✗ Fail: ${fail}${NC}"

    # Автофикс
    if [ ${#need_fix[@]} -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}Можно исправить автоматически:${NC}"
        local i=1
        for item in "${need_fix[@]}"; do
            local nm="${item%%|*}" lb="${item##*|}"
            echo -e "  ${YELLOW}[$i]${NC}  ${nm}: ${lb}"
            (( i++ ))
        done
        echo -e "  ${YELLOW}[a]${NC}  Исправить всё"
        echo ""
        read -p "  Выбор (Enter = пропустить): " fix_ch
        if [[ "$fix_ch" == "a" || "$fix_ch" == "A" ]]; then
            for item in "${need_fix[@]}"; do
                local nm="${item%%|*}" cmd; cmd=$(echo "$item" | cut -d'|' -f2)
                echo -ne "  Установка ${nm}... "
                export DEBIAN_FRONTEND=noninteractive
                eval "$cmd" > /dev/null 2>&1 && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
            done
        elif [[ "$fix_ch" =~ ^[0-9]+$ ]] && (( fix_ch >= 1 && fix_ch <= ${#need_fix[@]} )); then
            local item="${need_fix[$((fix_ch-1))]}"
            local nm="${item%%|*}" cmd; cmd=$(echo "$item" | cut -d'|' -f2)
            echo -ne "  Установка ${nm}... "
            export DEBIAN_FRONTEND=noninteractive
            eval "$cmd" > /dev/null 2>&1 && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
        fi
    fi

    echo ""
    read -p "  Enter..."
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

# ═══════════════════════════════════════════════════════════════
#  АВТООБНОВЛЕНИЕ
# ═══════════════════════════════════════════════════════════════

UPDATE_CACHE_FILE="${CONF_DIR}/update.cache"   # содержит: "VERSION|TIMESTAMP"
UPDATE_CACHE_TTL=21600                          # 6 часов

# Возвращает версию из кеша (если кеш свежий), иначе пустую строку
_update_cached_ver() {
    [ -f "$UPDATE_CACHE_FILE" ] || return
    local line; line=$(cat "$UPDATE_CACHE_FILE" 2>/dev/null)
    local cached_ver="${line%%|*}"
    local cached_ts="${line##*|}"
    [[ "$cached_ver" =~ ^[0-9]+\.[0-9]+ ]] || return
    [[ "$cached_ts" =~ ^[0-9]+$ ]] || return
    local now; now=$(date +%s)
    (( now - cached_ts < UPDATE_CACHE_TTL )) && echo "$cached_ver"
}

# Асинхронно проверяет версию в репо и обновляет кеш (запускается в фоне)
_update_fetch_bg() {
    local tmp="/tmp/govpn_ver_check.sh"
    curl -fsSL --max-time 10 "$REPO_URL" -o "$tmp" 2>/dev/null || return
    head -1 "$tmp" 2>/dev/null | grep -q '#!/bin/bash' || { rm -f "$tmp"; return; }
    local new_ver; new_ver=$(grep '^VERSION=' "$tmp" 2>/dev/null | head -1 | cut -d'"' -f2)
    rm -f "$tmp"
    [[ "$new_ver" =~ ^[0-9]+\.[0-9]+ ]] || return
    mkdir -p "$CONF_DIR"
    echo "${new_ver}|$(date +%s)" > "$UPDATE_CACHE_FILE"
}

# Запускает фоновую проверку если кеш устарел
_update_check_async() {
    local cached; cached=$(_update_cached_ver)
    [ -n "$cached" ] && return          # кеш свежий — не запрашиваем
    _update_fetch_bg &>/dev/null &
    disown 2>/dev/null || true
}

# Скачивает, валидирует и устанавливает новую версию
# Аргументы: [--force] [--yes]
cmd_update() {
    local force=0 yes=0
    for arg in "$@"; do
        [[ "$arg" == "--force" ]] && force=1
        [[ "$arg" == "--yes"   ]] && yes=1
    done

    clear
    echo -e "\n${CYAN}━━━ Обновление GoVPN ━━━${NC}\n"
    echo -e "  ${WHITE}Текущая версия: ${GREEN}v${VERSION}${NC}"
    echo -e "  ${WHITE}Источник:       ${CYAN}${REPO_URL}${NC}\n"

    # Скачиваем свежий скрипт
    local tmp="/tmp/govpn_update_$$.sh"
    echo -ne "  ${YELLOW}Загрузка...${NC} "
    if ! curl -fsSL --max-time 30 "$REPO_URL" -o "$tmp" 2>/dev/null; then
        echo -e "${RED}✗ Не удалось загрузить${NC}"
        rm -f "$tmp"; [ "$yes" -eq 0 ] && read -p "  Enter..."; return 1
    fi

    # Валидация
    if ! head -1 "$tmp" 2>/dev/null | grep -q '#!/bin/bash'; then
        echo -e "${RED}✗ Файл некорректен (не bash)${NC}"
        rm -f "$tmp"; [ "$yes" -eq 0 ] && read -p "  Enter..."; return 1
    fi

    local new_ver; new_ver=$(grep '^VERSION=' "$tmp" 2>/dev/null | head -1 | cut -d'"' -f2)
    if ! [[ "$new_ver" =~ ^[0-9]+\.[0-9]+ ]]; then
        echo -e "${RED}✗ Не удалось определить версию в скачанном файле${NC}"
        rm -f "$tmp"; [ "$yes" -eq 0 ] && read -p "  Enter..."; return 1
    fi
    echo -e "${GREEN}✓${NC}"
    echo -e "  ${WHITE}Версия в репо:  ${GREEN}v${new_ver}${NC}\n"

    # Сравниваем версии
    if [ "$force" -eq 0 ] && [ "$new_ver" = "$VERSION" ]; then
        echo -e "  ${YELLOW}Уже установлена актуальная версия (v${VERSION})${NC}"
        echo -ne "  Принудительно переустановить? (y/n): "
        if [ "$yes" -eq 1 ]; then
            echo "n"; rm -f "$tmp"; return 0
        fi
        read -r ans < /dev/tty
        if [[ "$ans" != "y" ]]; then
            rm -f "$tmp"; return 0
        fi
        force=1
    fi

    # Предупреждение о даунгрейде (если новая версия меньше текущей)
    if _ver_lt "$new_ver" "$VERSION" && [ "$force" -eq 0 ]; then
        echo -e "  ${YELLOW}⚠ Версия в репо (v${new_ver}) старее текущей (v${VERSION})${NC}"
        echo -ne "  Продолжить? (y/n): "
        [ "$yes" -eq 1 ] && echo "n" && rm -f "$tmp" && return 0
        read -r ans < /dev/tty
        [[ "$ans" != "y" ]] && rm -f "$tmp" && return 0
    fi

    # Бэкап текущей версии
    mkdir -p "$BACKUP_DIR"
    local bak="${BACKUP_DIR}/govpn.bak.$(date +%s)"
    cp "$INSTALL_PATH" "$bak" 2>/dev/null && \
        echo -e "  ${WHITE}Бэкап:${NC} ${CYAN}${bak}${NC}"

    # Установка
    cp -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    rm -f "$tmp"
    ln -sf "$INSTALL_PATH" /usr/bin/govpn 2>/dev/null

    # Обновляем кеш
    echo "${new_ver}|$(date +%s)" > "$UPDATE_CACHE_FILE" 2>/dev/null

    echo -e "\n  ${GREEN}✅ Установлена v${new_ver}${NC}"
    log_action "UPDATE: v${VERSION} → v${new_ver} (force=${force})"

    if [ "$yes" -eq 0 ]; then
        echo ""
        read -p "  Нажмите Enter для перезапуска..."
    fi
    exec "$INSTALL_PATH"
}

# Сравнение версий: возвращает 0 (true) если $1 < $2
_ver_lt() {
    local a="$1" b="$2"
    [ "$a" = "$b" ] && return 1
    local lower; lower=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)
    [ "$lower" = "$a" ]
}

# Показывает changelog — последние N строк из REPO (секция между двумя версиями)
_update_changelog() {
    local tmp="/tmp/govpn_changelog_$$.sh"
    echo -ne "${YELLOW}  Загрузка changelog...${NC} "
    if ! curl -fsSL --max-time 15 "$REPO_URL" -o "$tmp" 2>/dev/null; then
        echo -e "${RED}✗${NC}"; rm -f "$tmp"; return
    fi
    echo -e "${GREEN}✓${NC}\n"
    # Ищем блок CHANGELOG в скрипте (между маркерами)
    local in_log=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^#\ CHANGELOG ]]; then in_log=1; continue; fi
        [[ $in_log -eq 1 && "$line" =~ ^#\ === ]] && break
        [[ $in_log -eq 1 ]] && echo "  ${line#\# }"
    done < "$tmp" | head -30
    rm -f "$tmp"
}

_self_update() {
    cmd_update "$@"
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

_awg_emergency_restore() {
    # Экстренное восстановление AWG контейнера
    clear
    echo -e "\n${RED}━━━ Экстренное восстановление AWG ━━━${NC}\n"
    echo -e "  ${WHITE}Используй если контейнер упал и не поднимается${NC}\n"

    local container="${AWG_CONTAINER:-amnezia-awg2}"
    echo -e "  ${WHITE}Контейнер:${NC} ${CYAN}${container}${NC}"
    echo -e "  ${WHITE}Статус:${NC} $(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo 'не найден')\n"

    # Создаём правильный start.sh
    local tmp_sh; tmp_sh=$(mktemp)
    cat > "$tmp_sh" << 'STARTSH'
#!/bin/bash
echo "Container startup"

awg-quick down /opt/amnezia/awg/awg0.conf
if [ -f /opt/amnezia/awg/awg0.conf ]; then
    awg-quick up /opt/amnezia/awg/awg0.conf
fi

iptables -A INPUT -i awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -j ACCEPT
iptables -A OUTPUT -o awg0 -j ACCEPT
iptables -A FORWARD -i awg0 -o eth0 -s 10.8.1.0/24 -j ACCEPT
iptables -A FORWARD -i awg0 -o eth1 -s 10.8.1.0/24 -j ACCEPT
iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.8.1.0/24 -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 10.8.1.0/24 -o eth1 -j MASQUERADE

tail -f /dev/null
STARTSH

    echo -e "  ${YELLOW}[1]${NC}  Восстановить start.sh (без WARP)"
    echo -e "  ${YELLOW}[2]${NC}  Восстановить start.sh (с WARP если настроен)"
    echo -e "  ${YELLOW}[3]${NC}  Только перезапустить контейнер"
    echo -e "  ${YELLOW}[0]${NC}  Назад"
    echo ""
    read -p "  Выбор: " er_ch < /dev/tty

    case "$er_ch" in
        1|2)
            echo -e "  ${CYAN}Записываю start.sh во все overlay слои...${NC}"
            local updated=0
            for f in /var/lib/docker/overlay2/*/diff/opt/amnezia/start.sh; do
                cp "$tmp_sh" "$f" && chmod +x "$f" && (( updated++ ))
            done
            echo -e "  ${GREEN}✓ Обновлено слоёв: ${updated}${NC}"

            docker stop "$container" 2>/dev/null || true
            sleep 2
            docker start "$container"
            sleep 8

            if docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null | grep -q "running"; then
                echo -e "  ${GREEN}✓ Контейнер запущен${NC}"
                if [ "$er_ch" = "2" ]; then
                    echo -e "  ${CYAN}Применяю WARP правила...${NC}"
                    sleep 3
                    # Читаем сохранённых WARP клиентов
                    local warp_clients
                    warp_clients=$(_awg_selected_clients 2>/dev/null)
                    if [ -n "$warp_clients" ]; then
                        local -a sel_arr=()
                        while IFS= read -r ip; do [ -n "$ip" ] && sel_arr+=("$ip"); done <<< "$warp_clients"
                        _awg_apply_rules "${sel_arr[@]}"
                        echo -e "  ${GREEN}✓ WARP восстановлен (${#sel_arr[@]} клиентов)${NC}"
                    fi
                fi
            else
                echo -e "  ${RED}✗ Контейнер всё ещё не запускается${NC}"
                echo -e "  ${WHITE}Проверь:${NC} docker logs ${container} --tail 20"
            fi ;;
        3)
            docker stop "$container" 2>/dev/null || true
            sleep 2
            docker start "$container"
            sleep 5
            docker ps | grep "$container" ;;
        0|"") ;;
    esac
    rm -f "$tmp_sh"
    read -p "  Enter..." < /dev/tty
}

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
                hshake=$(echo "$wg_show" |                     awk "/allowed ips:.*${bare}\/32/{f=1} f && /latest handshake/{print; f=0}" |                     head -1 | sed 's/.*latest handshake: //')
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
                # head -1 чтобы брать только первое совпадение
                hshake=$(echo "$wg_show" |                     awk "/allowed ips:.*${bare}\/32/{f=1} f && /latest handshake/{print; f=0}" |                     head -1 | sed 's/.*latest handshake: //')
                local status_icon="${RED}●${NC}"
                local status_txt="${RED}не подключён${NC}"
                if [ -n "$hshake" ]; then
                    status_icon="${GREEN}●${NC}"
                    status_txt="${GREEN}${hshake}${NC}"
                fi
                printf "  ${YELLOW}[%d]${NC} %b ${WHITE}%-20s${NC}  ${CYAN}%s${NC}
"                     "$((i+1))" "$status_icon" "${name:-$bare}" "$ip"
                echo -e "       ${status_txt}"
            done
        else
            echo -e "  ${YELLOW}Клиентов нет${NC}"
        fi

        echo ""
        echo -e "  ${YELLOW}[+]${NC}   Добавить клиента"
        [ ${#sorted_ips[@]} -gt 0 ] && echo -e "  ${YELLOW}[номер]${NC} Конфиг / QR код"
        [ ${#sorted_ips[@]} -gt 0 ] && echo -e "  ${YELLOW}[-]${NC}   Удалить клиента"
        echo -e "  ${RED}[!]${NC}   Экстренное восстановление AWG"
        echo -e "  ${YELLOW}[/]${NC}   Сменить сортировку (${sort_mode})"
        echo -e "  ${YELLOW}[0]${NC}   Назад"
        echo ""
        ch=$(read_choice "Выбор (Enter = обновить): ")

        # Пустой Enter — обновить
        [ -z "$ch" ] && continue

        case "$ch" in
            "!") _awg_emergency_restore ;;
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
        echo -e "  ${YELLOW}[2]${NC}  QR код (AmneziaWG)"
        echo -e "  ${YELLOW}[3]${NC}  Переименовать"
        echo -e "  ${RED}[4]${NC}  Удалить клиента"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")
        case "$ch" in
            1) _awg_show_config "$client_ip" ;;
            2) _awg_show_qr "$client_ip" ;;
            3)
                echo -ne "  ${WHITE}Новое имя: ${NC}"; read -r new_name < /dev/tty
                [ -z "$new_name" ] && continue
                local tmp_ct="/tmp/awg_ct_rename.json"
                docker cp "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" "$tmp_ct" 2>/dev/null
                if [ -f "$tmp_ct" ]; then
                    local bare_ip="${client_ip%/32}"
                    python3 - "$tmp_ct" "$bare_ip" "$new_name" << 'PYEOF'
import sys, json
ct, bare, newname = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(ct) as f: data = json.load(f)
    for c in data:
        if c.get("userData",{}).get("allowedIps","").split("/")[0] == bare:
            c["userData"]["clientName"] = newname; break
    with open(ct,"w") as f: json.dump(data, f, indent=4)
    print("ok")
except Exception as e: print("err:"+str(e))
PYEOF
                    docker cp "$tmp_ct" "${AWG_CONTAINER}:/opt/amnezia/awg/clientsTable" 2>/dev/null
                    rm -f "$tmp_ct"
                    name="$new_name"; label="$new_name"
                    echo -e "  ${GREEN}✓ Переименован в '${new_name}'${NC}"
                    log_action "AWG PEER RENAME: ${client_ip} -> ${new_name}"
                fi
                read -p "  Enter..." < /dev/tty ;;
            4)
                echo -ne "  ${RED}Удалить ${label}? (y/n): ${NC}"
                read -r c < /dev/tty
                if [ "$c" = "y" ]; then
                    _awg_del_peer "$client_ip"
                    return
                fi ;;
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

# QR код roscomvpn deeplink для Happ/INCY
_awg_show_roscomvpn_qr() {
    local client_ip="$1"
    local name; name=$(_awg_client_name "$client_ip")
    clear
    echo -e "\n${CYAN}━━━ roscomvpn QR: ${WHITE}${name:-${client_ip%/32}}${CYAN} ━━━${NC}\n"

    local cfg; cfg=$(_awg_get_client_config "$client_ip")
    if [ -z "$cfg" ]; then
        echo -e "${YELLOW}Конфиг не найден.${NC}"
        echo -e "${WHITE}Клиент добавлен через Amnezia — ключ только на устройстве.${NC}"
        echo ""; read -p "Нажмите Enter..."; return
    fi

    # Генерируем deeplink для roscomvpn routing
    # Формат: https://routing.help — редирект на Happ deeplink с roscomvpn профилем
    local ROSCOM_DEEPLINK="https://routing.help"
    
    echo -e "  ${WHITE}Шаг 1:${NC} Отсканируй QR конфига AWG в Happ/AmneziaWG:"
    echo ""
    command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
    echo "$cfg" | qrencode -t ANSIUTF8 2>/dev/null || echo -e "${RED}qrencode не установлен${NC}"
    
    echo ""
    echo -e "  ${WHITE}Шаг 2:${NC} Добавь roscomvpn маршрутизацию — отсканируй:"
    echo ""
    echo "$ROSCOM_DEEPLINK" | qrencode -t ANSIUTF8 2>/dev/null
    echo -e "  ${CYAN}${ROSCOM_DEEPLINK}${NC}"
    echo ""
    echo -e "  ${WHITE}Результат:${NC} РФ/РБ сайты — напрямую, заблокированные — через VPN"
    echo ""
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

    # Полный бэкап перед изменением
    _backup_auto

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

    # Верификация — пир должен появиться в wg show
    sleep 1
    local verify_ok
    verify_ok=$(docker exec "$AWG_CONTAINER" sh -c         "wg show $(_awg_iface) allowed-ips 2>/dev/null | grep '${bare}/32'" 2>/dev/null)
    if [ -n "$verify_ok" ]; then
        echo -e "  ${GREEN}✓ Верификация: пир активен в wg${NC}"
    else
        echo -e "  ${YELLOW}⚠ Пир не виден в wg show — перезапуск контейнера...${NC}"
        docker restart "$AWG_CONTAINER" > /dev/null 2>&1
        sleep 3
        verify_ok=$(docker exec "$AWG_CONTAINER" sh -c             "wg show $(_awg_iface) allowed-ips 2>/dev/null | grep '${bare}/32'" 2>/dev/null)
        if [ -n "$verify_ok" ]; then
            echo -e "  ${GREEN}✓ Пир активен после перезапуска${NC}"
        else
            echo -e "  ${RED}✗ Пир не появился — проверьте вручную: wg show${NC}"
            echo -e "  ${WHITE}Конфиг клиента сохранён, можно попробовать снова.${NC}"
        fi
    fi
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

    # Полный бэкап перед удалением
    echo -ne "  ${YELLOW}Создаю бэкап...${NC} "
    _backup_auto && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}(пропущен)${NC}"

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

    # Верификация — пир должен исчезнуть из wg show
    sleep 1
    local verify_gone
    verify_gone=$(docker exec "$AWG_CONTAINER" sh -c         "wg show $(_awg_iface) allowed-ips 2>/dev/null | grep '${bare}/32'" 2>/dev/null)
    if [ -n "$verify_gone" ]; then
        echo -e "  ${RED}⚠ Пир всё ещё виден в wg show — пробуем принудительно${NC}"
        [ -n "$del_pubkey" ] &&             docker exec "$AWG_CONTAINER" sh -c                 "wg set $(_awg_iface) peer '${del_pubkey}' remove" 2>/dev/null
    fi

    echo -e "${GREEN}  ✓ Удалён: ${del_name:-$del_ip}${NC}"
    log_action "AWG PEER DEL: ${del_name} ${del_ip}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  MTPROTO ПРОКСИ (mtg v2)
# ═══════════════════════════════════════════════════════════════

MTG_CONF_DIR="${CONF_DIR}/mtproto"
MTG_IMAGE="nineseconds/mtg:2"
TELEMT_IMAGE="ghcr.io/telemt/telemt:latest"
MTG_ENGINE="mtg"   # mtg | telemt — выбор движка

# Список доменов для FakeTLS с описаниями
MTG_DOMAINS=(
    "google.com:Google"
    "wikipedia.org:Wikipedia"
    "github.com:GitHub"
    "stackoverflow.com:StackOverflow"
    "medium.com:Medium"
    "bbc.com:BBC"
    "reuters.com:Reuters"
    "nytimes.com:NYTimes"
    "lenta.ru:Лента.ру"
    "rbc.ru:РБК"
    "ria.ru:РИА Новости"
    "kommersant.ru:Коммерсантъ"
    "habr.com:Хабр"
    "stepik.org:Stepik"
    "duolingo.com:Duolingo"
    "coursera.org:Coursera"
    "udemy.com:Udemy"
    "khanacademy.org:Khan Academy"
    "ted.com:TED"
    "cloudflare.com:Cloudflare"
)

# Популярные порты для MTProto
MTG_PORTS=(443 8443 2053 2083 2087)

_mtg_list_instances() {
    # Docker контейнеры mtg/mtproto (исключаем telemt)
    docker ps -a --format '{{.Names}}	{{.Status}}	{{.Ports}}' 2>/dev/null |         grep -iE "^(mtg-[0-9]|mtproto)" | sort
    # Telemt — ищем только по meta-файлам
    if [ -d "$MTG_CONF_DIR" ]; then
        for meta in "${MTG_CONF_DIR}"/*.meta; do
            [ -f "$meta" ] || continue
            local mname; mname=$(basename "$meta" .meta)
            local mengine; mengine=$(grep "^engine=" "$meta" 2>/dev/null | cut -d= -f2)
            [ "$mengine" != "telemt" ] && continue
            local mport; mport=$(grep "^port=" "$meta" | cut -d= -f2)
            local mst; mst=$(systemctl is-active "$mname" 2>/dev/null || echo "inactive")
            printf '%s\t%s\t0.0.0.0:%s->3128/tcp\n' "$mname" "$mst" "$mport"
        done
    fi
}

_mtg_count_running() {
    local cnt=0 tcnt=0
    cnt=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE "^(mtg-|mtproto)" 2>/dev/null) || cnt=0
    [ -z "$cnt" ] && cnt=0
    # Telemt через meta-файлы
    if [ -d "$MTG_CONF_DIR" ]; then
        for meta in "${MTG_CONF_DIR}"/*.meta; do
            [ -f "$meta" ] || continue
            local mengine; mengine=$(grep "^engine=" "$meta" 2>/dev/null | cut -d= -f2)
            [ "$mengine" = "telemt" ] || continue
            local mname; mname=$(basename "$meta" .meta)
            systemctl is-active --quiet "$mname" 2>/dev/null && tcnt=$(( tcnt + 1 ))
        done
    fi
    echo $(( cnt + tcnt ))
}

_mtg_detect_type() {
    local name="$1"
    local engine; engine=$(grep "^engine=" "${MTG_CONF_DIR}/${name}.meta" 2>/dev/null | cut -d= -f2)
    case "$engine" in
        telemt) echo "telemt"; return ;;
        mtg)    echo "govpn";  return ;;
    esac
    [[ "$name" == mtg-* ]] && echo "govpn" || echo "external"
}

_mtg_is_running() {
    local name="$1"
    # Docker контейнер
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" && return 0
    # Systemd сервис (telemt)
    systemctl is-active --quiet "${name}" 2>/dev/null && return 0
    return 1
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
    local geo cc country city
    # Пробуем несколько источников
    geo=$(curl -s --max-time 5 "http://ip-api.com/json/${MY_IP}?fields=country,countryCode,city" 2>/dev/null)
    if [ -n "$geo" ]; then
        country=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null)
        city=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null)
        cc=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('countryCode',''))" 2>/dev/null)
    fi
    # Fallback через ipinfo.io
    if [ -z "$cc" ]; then
        geo=$(curl -s --max-time 5 "https://ipinfo.io/${MY_IP}/json" 2>/dev/null)
        country=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('country',''))" 2>/dev/null)
        city=$(echo "$geo" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('city',''))" 2>/dev/null)
        cc="$country"
    fi
    echo "${cc:-??}|${country:-Unknown}|${city:-}"
}

_mtg_check_port() {
    local port="$1"
    ss -tlnup 2>/dev/null | grep -q ":${port}[[:space:]]" && return 1 || return 0
}

_mtg_port_process() {
    local port="$1"
    ss -tlnup 2>/dev/null | grep ":${port}[[:space:]]" |         grep -oP '(?<=users:\(\(")[^"]+' | head -1
}

_mtg_add() {
    clear
    echo -e "\n${CYAN}━━━ Новый MTProto прокси ━━━${NC}\n"

    # Определяем домен сервера (для secret и отображения)
    local SERVER_DOMAIN=""
    SERVER_DOMAIN=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    [ -z "$SERVER_DOMAIN" ] && SERVER_DOMAIN=$(sqlite3 /etc/x-ui/x-ui.db         "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null | head -1)

    # Определяем страну сервера
    echo -ne "${WHITE}Определяю страну сервера...${NC} "
    # Убеждаемся что MY_IP определён
    [ -z "$MY_IP" ] && MY_IP=$(curl -s --max-time 5 https://api4.ipify.org 2>/dev/null)
    [ -z "$MY_IP" ] && MY_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
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
            local occ; occ=$(ss -tlnup 2>/dev/null | grep ":${p}[[:space:]]" |                 sed 's/.*users:(("//' | cut -d'"' -f1 | head -1)
            # nginx/certbot не конфликт — MTProto на другом порту
            if [[ "$occ" =~ ^(nginx|certbot)$ ]]; then
                echo -e "  ${YELLOW}[$i]${NC} ${YELLOW}${p}${NC}  — ${YELLOW}занят (${occ}) — можно использовать с осторожностью${NC}"
            else
                echo -e "  ${YELLOW}[$i]${NC} ${RED}${p}${NC}  — ${RED}занят (${occ})${NC}"
            fi
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
        local occ; occ=$(ss -tlnup 2>/dev/null | grep ":${chosen_port}[[:space:]]" |             sed 's/.*users:(("//' | cut -d'"' -f1 | head -1)
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
    # Показываем домен сервера как опцию
    local server_domain_idx=0
    if [ -n "$SERVER_DOMAIN" ]; then
        server_domain_idx=$(( ${#domain_list[@]} + 1 ))
        echo -e "  ${GREEN}[${server_domain_idx}]${NC} ${GREEN}${SERVER_DOMAIN}${NC}  ${CYAN}← ваш домен (Self-Steal)${NC}"
    fi
    local custom_idx
    [ -n "$SERVER_DOMAIN" ] && custom_idx=$(( server_domain_idx + 1 )) || custom_idx=$(( ${#domain_list[@]} + 1 ))
    echo -e "  ${YELLOW}[${custom_idx}]${NC} Свой домен"
    echo ""
    echo -e "${YELLOW}  ⚠ Не используйте домены заблокированные в вашем регионе!${NC}"
    echo ""
    # Дефолт — домен сервера если есть
    local default_choice=1
    [ -n "$SERVER_DOMAIN" ] && default_choice="$server_domain_idx"
    read -p "Выбор [${default_choice}]: " domain_choice
    [ -z "$domain_choice" ] && domain_choice="$default_choice"

    local chosen_domain=""
    if [[ "$domain_choice" =~ ^[0-9]+$ ]] && (( domain_choice >= 1 && domain_choice <= ${#domain_list[@]} )); then
        chosen_domain="${domain_list[$((domain_choice-1))]}"
    elif [ -n "$SERVER_DOMAIN" ] && (( domain_choice == server_domain_idx )); then
        chosen_domain="$SERVER_DOMAIN"
        echo -e "  ${GREEN}✓ Используется ваш домен: ${SERVER_DOMAIN}${NC}"
    elif (( domain_choice == custom_idx )); then
        echo -e "${WHITE}Введите домен (например: telegram.org):${NC}"
        read -p "> " chosen_domain < /dev/tty
        [ -z "$chosen_domain" ] && return
    else
        chosen_domain="${SERVER_DOMAIN:-bing.com}"
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

    # Генерируем секрет — через Docker или нативный mtg бинарник
    echo -e "\n${YELLOW}Генерация секрета...${NC}"
    local secret=""

    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        # Docker доступен
        secret=$(docker run --rm "$MTG_IMAGE" generate-secret -x "${chosen_domain}" 2>/dev/null | tr -d '[:space:]')
    fi

    if [ -z "$secret" ]; then
        # Fallback: нативный mtg бинарник
        local mtg_bin="/usr/local/bin/mtg"
        if [ ! -x "$mtg_bin" ]; then
            echo -e "  ${CYAN}Docker недоступен — скачиваю mtg бинарник...${NC}"
            local arch; arch=$(uname -m)
            local mtg_arch="amd64"
            [ "$arch" = "aarch64" ] && mtg_arch="arm64"
            local downloaded=0
            # Способ 1: docker cp из образа (если Docker есть на этом сервере)
            if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
                echo -e "  ${CYAN}Извлекаю mtg из Docker образа...${NC}"
                local tmp_name="mtg_extract_$$"
                docker create --name "$tmp_name" "$MTG_IMAGE" > /dev/null 2>&1
                docker cp "${tmp_name}:/mtg" "$mtg_bin" 2>/dev/null &&                     chmod +x "$mtg_bin" && downloaded=1
                docker rm "$tmp_name" > /dev/null 2>&1
            fi
            # Способ 2: GitHub (может быть заблокирован в РФ)
            if [ "$downloaded" -eq 0 ]; then
                local mtg_urls=(
                    "https://github.com/9seconds/mtg/releases/latest/download/mtg-linux-${mtg_arch}"
                    "https://objects.githubusercontent.com/github-production-release-asset-2e65be/161644585/mtg-linux-${mtg_arch}"
                )
                for url in "${mtg_urls[@]}"; do
                    curl -fsSL --connect-timeout 5 "$url" -o "$mtg_bin" 2>/dev/null &&                         chmod +x "$mtg_bin" && downloaded=1 && break
                done
            fi
            if [ "$downloaded" -eq 0 ]; then
                echo -e "  ${YELLOW}mtg недоступен — секрет будет сгенерирован локально${NC}"
                echo -e "  ${WHITE}Для запуска прокси скопируйте mtg вручную:${NC}"
                echo -e "  ${CYAN}scp /usr/local/bin/mtg root@<этот_сервер>:/usr/local/bin/mtg${NC}"
            else
                echo -e "  ${GREEN}✓ mtg установлен${NC}"
            fi
        fi
        if [ -x "$mtg_bin" ]; then
            secret=$("$mtg_bin" generate-secret -x "${chosen_domain}" 2>/dev/null | tr -d '[:space:]')
        fi
    fi

    # Финальный fallback: генерируем FakeTLS секрет без внешних зависимостей
    # Формат: ee + hex(random 16 bytes) + hex(domain)
    if [ -z "$secret" ]; then
        secret=$(python3 -c "
import os, binascii
domain = '${chosen_domain}'.encode()
rand = os.urandom(16)
# FakeTLS: prefix ee + random + domain в hex
raw = b'\xee' + rand + domain
print('ee' + binascii.hexlify(rand).decode() + binascii.hexlify(domain).decode())
" 2>/dev/null)
        [ -n "$secret" ] && echo -e "  ${GREEN}✓ Секрет сгенерирован локально${NC}"
    fi

    if [ -z "$secret" ]; then
        echo -e "${RED}  ✗ Не удалось сгенерировать секрет${NC}"
        read -p "Enter..."; return
    fi
    echo -e "${GREEN}  ✓ Секрет: ${secret:0:20}...${NC}"

    # Конфиг файл для mtg v2 (bind-to внутри toml, не как аргумент)
    mkdir -p "$MTG_CONF_DIR"
    local conf_file="${MTG_CONF_DIR}/${name}.toml"
    # mtg v2 формат: secret + bind-to в одном файле
    cat > "$conf_file" << TOML
secret = "${secret}"
bind-to = "0.0.0.0:3128"
prefer-ip = "prefer-ipv4"

[network]
dns = "https://1.1.1.1"

[defense.anti-replay]
enabled = true
max-size = "1mib"
error-rate = 0.001
TOML

    # Запускаем — через Docker или нативно
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        echo -e "${YELLOW}Запускаю контейнер ${name}...${NC}"
        docker run -d \
            --name "$name" \
            --restart unless-stopped \
            -v "${conf_file}:/config.toml" \
            -p "0.0.0.0:${chosen_port}:3128" \
            "$MTG_IMAGE" run /config.toml > /dev/null 2>&1
        sleep 3
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
            echo -e "${RED}  ✗ Контейнер не запустился${NC}"
            echo -e "${YELLOW}  Логи: docker logs ${name}${NC}"
            read -p "Enter..."; return
        fi
    else
        # Нативный запуск через systemd service (mtg v2)
        echo -e "${YELLOW}Запускаю mtg нативно (без Docker)...${NC}"
        local mtg_bin="/usr/local/bin/mtg"
        local svc_name="mtg-${chosen_port}"
        # mtg v2: ExecStart без --bind (порт уже в конфиге)
        cat > "/etc/systemd/system/${svc_name}.service" << SYSTEMD
[Unit]
Description=MTProto proxy ${name}
After=network.target

[Service]
ExecStart=${mtg_bin} run ${conf_file}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD
        mkdir -p /etc/mtg
        cp "$conf_file" "/etc/mtg/${name}.toml"
        systemctl daemon-reload
        systemctl enable "$svc_name" > /dev/null 2>&1
        systemctl start "$svc_name"
        sleep 2
        if ! systemctl is-active "$svc_name" &>/dev/null; then
            echo -e "${RED}  ✗ Сервис не запустился${NC}"
            echo -e "${YELLOW}  Логи: journalctl -u ${svc_name} -n 20${NC}"
            read -p "Enter..."; return
        fi
        echo -e "${GREEN}  ✓ Сервис ${svc_name} запущен${NC}"
    fi

    # Формируем ссылку — используем домен сервера если настроен
    local server_addr="$MY_IP"
    local server_domain_configured=""
    # Ищем домен в certbot
    server_domain_configured=$(certbot certificates 2>/dev/null | grep "Domains:" | head -1 | awk '{print $2}')
    # Или из govpn конфига
    [ -z "$server_domain_configured" ] && server_domain_configured=$(grep "^MTG_DOMAIN=" /etc/govpn/config 2>/dev/null | cut -d= -f2 | tr -d '"')
    [ -n "$server_domain_configured" ] && server_addr="$server_domain_configured"

    local link="tg://proxy?server=${server_addr}&port=${chosen_port}&secret=${secret}"
    local link_tme="https://t.me/proxy?server=${server_addr}&port=${chosen_port}&secret=${secret}"
    local created_mtg; created_mtg=$(date '+%Y-%m-%d %H:%M:%S')

    # Сохраняем мета-данные
    cat > "${MTG_CONF_DIR}/${name}.meta" << META
port=${chosen_port}
domain=${chosen_domain}
server=${server_addr}
secret=${secret}
link=${link}
link_tme=${link_tme}
created=${created_mtg}
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
        link=$(grep "^link=" "$meta_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
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
                local dtype; dtype=$(_mtg_detect_type "$name")
                # Для telemt — получаем актуальную ссылку через API
                if [ "$dtype" = "telemt" ]; then
                    local api_p; api_p=$(grep "^api_port=" "$meta_file" 2>/dev/null | cut -d= -f2)
                    [ -z "$api_p" ] && api_p=$(( port + 1 ))
                    local live_link
                    live_link=$(curl -s --max-time 2 "http://127.0.0.1:${api_p}/v1/users" 2>/dev/null |                         python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for u in d.get('data',[]):
        tls=u.get('links',{}).get('tls',[])
        if tls: print(tls[0]); break
except: pass
" 2>/dev/null)
                    [ -z "$live_link" ] && live_link=$(journalctl -u "$name" --no-pager -n 200 2>/dev/null |                         grep "EE-TLS:" | tail -1 | sed 's/.*EE-TLS:  *//' | tr -d ' 
')
                    [ -n "$live_link" ] && link="$live_link"
                fi
                # Конвертируем tg:// → t.me через python (безопасно)
                local tme_link; tme_link=$(python3 -c "
s='${link}'
if s.startswith('tg://proxy?'):
    print('https://t.me/proxy?' + s[len('tg://proxy?'):])
elif s.startswith('tg://proxy'):
    print('https://t.me/proxy' + s[len('tg://proxy'):])
else:
    print(s)
" 2>/dev/null || echo "$link")
                echo -e "${WHITE}tg:// ссылка:${NC}"
                echo -e "${GREEN}${link}${NC}"
                echo ""
                echo -e "${WHITE}t.me ссылка:${NC}"
                echo -e "${GREEN}${tme_link}${NC}"
                echo ""
                if command -v qrencode &>/dev/null; then
                    echo -e "${WHITE}QR код (tg://):${NC}
"
                    echo "$link" | qrencode -t ansiutf8 2>/dev/null
                fi
                read -p "Нажмите Enter..." ;;
            2)
                clear
                echo -e "\n${CYAN}━━━ Перевыпуск секрета: ${name} ━━━${NC}\n"
                echo -e "${YELLOW}Генерируем новый секрет для домена ${domain}...${NC}"
                local new_secret
                if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
                new_secret=$(docker run --rm "$MTG_IMAGE" generate-secret -x "${domain}" 2>/dev/null | tr -d '[:space:]')
            elif [ -x /usr/local/bin/mtg ]; then
                new_secret=$(/usr/local/bin/mtg generate-secret -x "${domain}" 2>/dev/null | tr -d '[:space:]')
            fi
            # Локальная генерация если нет ни Docker ни mtg
            if [ -z "$new_secret" ]; then
                new_secret=$(python3 -c "
import os, binascii
domain = '${domain}'.encode()
rand = os.urandom(16)
print('ee' + binascii.hexlify(rand).decode() + binascii.hexlify(domain).decode())
" 2>/dev/null)
            fi
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
                # Обновляем мета — используем сохранённый server из meta
                local srv; srv=$(grep "^server=" "$meta_file" 2>/dev/null | cut -d= -f2)
                [ -z "$srv" ] && srv="$MY_IP"
                local new_link="tg://proxy?server=${srv}&port=${port}&secret=${new_secret}"
                local new_link_tme="https://t.me/proxy?server=${srv}&port=${port}&secret=${new_secret}"
                # Обновляем мета безопасно через python
                python3 << PYEOF
import re
with open("${meta_file}", "r") as f:
    meta = f.read()
meta = re.sub(r"^secret=.*", "secret=${new_secret}", meta, flags=re.M)
meta = re.sub(r"^link=.*", "link=${new_link}", meta, flags=re.M)
meta = re.sub(r"^link_tme=.*", "link_tme=${new_link_tme}", meta, flags=re.M)
with open("${meta_file}", "w") as f:
    f.write(meta)
PYEOF
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
                local del_type; del_type=$(_mtg_detect_type "$name")
                if [ "$del_type" = "telemt" ]; then
                    _telemt_remove "$name" && return
                else
                    read -p "$(echo -e "${RED}Удалить ${name}? (y/n): ${NC}")" c
                    [ "$c" != "y" ] && continue
                    docker stop "$name" > /dev/null 2>&1
                    docker rm "$name" > /dev/null 2>&1
                    rm -f "${MTG_CONF_DIR}/${name}.toml" "${MTG_CONF_DIR}/${name}.meta"
                    echo -e "${GREEN}  ✓ Удалён.${NC}"
                    log_action "MTG DEL: ${name}"
                    read -p "Нажмите Enter..."; return
                fi ;;
            0|"") return ;;
        esac
    done
}


# ═══════════════════════════════════════════════════════════════
#  TELEMT — MTProxy на Rust (замена mtg)
# ═══════════════════════════════════════════════════════════════

_telemt_install() {
    echo -e "\n${CYAN}Устанавливаем Telemt...${NC}"
    local arch; arch=$(uname -m)
    local libc="gnu"
    ldd --version 2>&1 | grep -iq musl && libc="musl"
    local url="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"

    echo -e "  ${CYAN}Скачиваем бинарник (${arch}-linux-${libc})...${NC}"
    if wget -qO- "$url" | tar -xz -C /tmp/ 2>/dev/null &&        mv /tmp/telemt /usr/local/bin/telemt 2>/dev/null &&        chmod +x /usr/local/bin/telemt; then
        echo -e "  ${GREEN}✓ Telemt установлен: $(/usr/local/bin/telemt --version 2>/dev/null | head -1)${NC}"
        return 0
    else
        echo -e "  ${RED}✗ Ошибка установки Telemt${NC}"
        return 1
    fi
}

_telemt_is_installed() {
    command -v telemt &>/dev/null || [ -f /usr/local/bin/telemt ]
}

_telemt_add() {
    clear
    echo -e "\n${CYAN}━━━ Новый Telemt MTProto прокси ━━━${NC}\n"

    # Проверяем установку — ставим автоматически без лишних вопросов
    if ! _telemt_is_installed; then
        echo -e "  ${YELLOW}Telemt не установлен — устанавливаем...${NC}"
        _telemt_install || {
            echo -e "  ${RED}Не удалось установить Telemt${NC}"
            read -p "  Enter..." < /dev/tty
            return
        }
    fi

    # Получаем домен сервера — показываем все варианты и спрашиваем
    local server_domain _auto_domain
    # Собираем все домены с сертификатами
    local _all_domains; _all_domains=$(certbot certificates 2>/dev/null | grep "Domains:" | awk '{print $2}')
    [ -z "$_all_domains" ] && _all_domains=$(grep "^MTG_DOMAIN=" /etc/govpn/config 2>/dev/null | cut -d= -f2 | tr -d '"')

    echo -e "
  ${WHITE}Домен сервера для ссылки подключения:${NC}"
    if [ -n "$_all_domains" ]; then
        local _didx=1
        while IFS= read -r _d; do
            echo -e "  ${YELLOW}[${_didx}]${NC} ${_d}"
            _didx=$(( _didx + 1 ))
        done <<< "$_all_domains"
        echo -e "  ${YELLOW}[0]${NC} Использовать IP (${MY_IP})"
        echo -e "  ${YELLOW}[m]${NC} Ввести вручную"
        echo ""
        echo -ne "  Выбор [1]: "; read -r _dom_choice < /dev/tty
        _dom_choice="${_dom_choice:-1}"
        if [ "$_dom_choice" = "0" ]; then
            server_domain="$MY_IP"
        elif [ "$_dom_choice" = "m" ] || [ "$_dom_choice" = "м" ]; then
            echo -ne "  Введите домен: "; read -r server_domain < /dev/tty
        else
            server_domain=$(echo "$_all_domains" | sed -n "${_dom_choice}p")
            [ -z "$server_domain" ] && server_domain=$(echo "$_all_domains" | head -1)
        fi
    else
        echo -e "  ${YELLOW}Сертификатов не найдено${NC}"
        echo -ne "  Введите домен или оставьте пустым для IP: "; read -r server_domain < /dev/tty
        [ -z "$server_domain" ] && server_domain="$MY_IP"
    fi
    echo -e "  ${GREEN}✓ Домен для ссылки: ${server_domain}${NC}
"

    # Определяем рекомендуемый порт для текущего сервера
    local _rec_settings; _rec_settings=$(_mtg_recommend_settings)
    local _rec_port; _rec_port=$(echo "$_rec_settings" | grep "^REC_PORT=" | cut -d= -f2)
    local _self_steal; _self_steal=$(echo "$_rec_settings" | grep "^SELF_STEAL=" | cut -d= -f2)
    local _note; _note=$(echo "$_rec_settings" | grep "^NOTE=" | cut -d= -f2-)
    _rec_port="${_rec_port:-443}"

    echo -e "  ${CYAN}Рекомендуемый порт для этого сервера: ${WHITE}${_rec_port}${NC}"
    [ -n "$_note" ] && echo -e "  ${YELLOW}${_note}${NC}"
    [ "$_self_steal" = "yes" ] && echo -e "  ${GREEN}✓ Self-Steal возможен — трафик маскируется под ваш сайт${NC}"
    echo ""
    echo -ne "  Порт [${_rec_port}]: "; read -r port < /dev/tty
    port="${port:-${_rec_port}}"

    # Пинг доменов для выбора FakeTLS
    echo -e "
  ${WHITE}Выберите домен маскировки (FakeTLS):${NC}"
    echo -e "  ${CYAN}Тестирую доступность доменов...${NC}"
    local -a tls_domains=("storage.googleapis.com" "www.google.com" "microsoft.com" "apple.com" "github.com" "stackoverflow.com" "cloudflare.com" "amazon.com" "petrovich.ru" "yandex.ru")
    local -a tls_descs=("Google Storage" "Google" "Microsoft" "Apple" "GitHub" "StackOverflow" "Cloudflare" "Amazon" "Петрович.ру" "Яндекс")
    local idx=0
    for d in "${tls_domains[@]}"; do
        local ms; ms=$(_mtg_ping_domain "$d")
        local color="${GREEN}"
        [ "$ms" -gt 200 ] 2>/dev/null && color="${YELLOW}"
        [ "$ms" -gt 500 ] 2>/dev/null && color="${RED}"
        echo -e "  ${YELLOW}[$((idx+1))]${NC} ${d}  ${color}${ms}ms${NC}  ${tls_descs[$idx]}"
        idx=$(( idx + 1 ))
    done
    # Добавляем домен сервера как вариант если есть
    local srv_dom_idx=0
    if [ -n "$server_domain" ]; then
        srv_dom_idx=$(( ${#tls_domains[@]} + 1 ))
        local srv_ms; srv_ms=$(_mtg_ping_domain "$server_domain")
        echo -e "  ${GREEN}[${srv_dom_idx}]${NC} ${server_domain}  ${GREEN}${srv_ms}ms${NC}  ${GREEN}← ваш домен (Self-Steal)${NC}"
    fi
    echo -e "  ${YELLOW}[0]${NC} Свой домен"
    echo ""
    echo -ne "  Выбор [1]: "; read -r tls_choice < /dev/tty
    tls_choice="${tls_choice:-1}"
    local tls_domain
    if [[ "$tls_choice" == "0" ]]; then
        echo -ne "  Введите домен: "; read -r tls_domain < /dev/tty
        tls_domain="${tls_domain:-storage.googleapis.com}"
    elif [ -n "$server_domain" ] && [[ "$tls_choice" == "$srv_dom_idx" ]]; then
        tls_domain="$server_domain"
    elif [[ "$tls_choice" =~ ^[0-9]+$ ]] && (( tls_choice >= 1 && tls_choice <= ${#tls_domains[@]} )); then
        tls_domain="${tls_domains[$((tls_choice-1))]}"
    else
        tls_domain="storage.googleapis.com"
    fi

    # Генерируем 32-hex секрет для пользователя (имя фиксированное)
    local username="user"
    local user_secret; user_secret=$(python3 -c "import os,binascii; print(binascii.hexlify(os.urandom(16)).decode())")

    # Адрес для ссылки
    local server_addr="${server_domain:-$MY_IP}"

    mkdir -p "$MTG_CONF_DIR"
    local name="telemt-${port}"
    local conf_file="${MTG_CONF_DIR}/${name}.toml"

    cat > "$conf_file" << TOML
[general]
use_middle_proxy = false
log_level = "normal"

[general.modes]
tls = true

[general.links]
show = "*"
public_host = "${server_addr}"
public_port = ${port}

[server]
port = ${port}

[server.api]
enabled = true
listen = "127.0.0.1:$((port+1))"
whitelist = ["127.0.0.1"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${tls_domain}"
mask = true
tls_emulation = true

[access.users]
${username} = "${user_secret}"
TOML

    echo -e "\n  ${CYAN}Запускаем Telemt...${NC}"
    # Systemd сервис
    # Создаём пользователя telemt если нет
    id telemt &>/dev/null 2>&1 || useradd -d /opt/telemt -m -r -U telemt 2>/dev/null
    mkdir -p "$(dirname "$conf_file")"
    chown -R telemt:telemt "$(dirname "$conf_file")" 2>/dev/null

    cat > "/etc/systemd/system/${name}.service" << SYSTEMD
[Unit]
Description=Telemt MTProto proxy ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/usr/local/bin/telemt run ${conf_file}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable --now "$name" 2>/dev/null


    # Ждём запуска и получаем ссылку через API (рекомендовано документацией)
    echo -e "  ${CYAN}Ожидаем запуска Telemt...${NC}"
    local api_port=$(( port + 1 ))
    local attempts=0 real_link="" real_secret=""
    while [ $attempts -lt 20 ] && [ -z "$real_link" ]; do
        sleep 1
        # API telemt /v1/users
        real_link=$(curl -s --max-time 2 "http://127.0.0.1:${api_port}/v1/users" 2>/dev/null | \
            python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for u in d.get('data',[]):
        tls=u.get('links',{}).get('tls',[])
        if tls: print(tls[0]); break
except: pass
" 2>/dev/null)
        # Fallback — journalctl
        [ -z "$real_link" ] && real_link=$(journalctl -u "$name" --no-pager -n 100 2>/dev/null | \
            grep "EE-TLS:" | tail -1 | sed 's/.*EE-TLS:  //' | tr -d ' ')
        attempts=$(( attempts + 1 ))
    done

    # Если не получили — генерируем сами
    if [ -n "$real_link" ]; then
        real_secret=$(echo "$real_link" | sed 's/.*secret=//' | cut -d'&' -f1)
    else
        real_secret=$(python3 -c "
import os, binascii
rand = os.urandom(16)
domain = '${tls_domain}'.encode()
print('ee' + binascii.hexlify(rand).decode() + binascii.hexlify(domain).decode())
")
        real_link="tg://proxy?server=${server_addr}&port=${port}&secret=${real_secret}"
    fi
    local link="$real_link"
    local link_tme_val; link_tme_val=$(python3 -c "
s='${link}'
if s.startswith('tg://proxy?'):
    print('https://t.me/proxy?' + s[len('tg://proxy?'):])
else:
    print(s.replace('tg://proxy','https://t.me/proxy',1))
" 2>/dev/null || echo "${link}")
    local created_at; created_at=$(date '+%Y-%m-%d %H:%M:%S')

    # Сохраняем мета
    cat > "${MTG_CONF_DIR}/${name}.meta" << META
port=${port}
domain=${tls_domain}
server=${server_addr}
secret=${real_secret}
user_secret=${user_secret}
username=${username}
engine=telemt
api_port=${api_port}
link=${link}
link_tme=${link_tme_val}
created=${created_at}
META

    echo -e "\n${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${GREEN}✓ Telemt запущен!${NC}"
    echo -e "  ${WHITE}Порт:   ${CYAN}${port}${NC}"
    echo -e "  ${WHITE}Домен:  ${CYAN}${tls_domain}${NC}"
    echo -e "  ${WHITE}Ссылка: ${GREEN}${link}${NC}"
    echo -e "  ${YELLOW}⚠ При перезапуске секрет меняется — используй 'Показать ссылку' в управлении${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    # Предлагаем iptables редирект если порт нестандартный
    if [ "$port" != "443" ] && [ "$port" != "8443" ]; then
        echo -e "  ${CYAN}Добавить iptables REDIRECT диапазона портов → ${port}?${NC}"
        local _yn; _yn=$(read_yn "  (y/n): ")
        [ "$_yn" = "y" ] && _xui_add_redirect "$port"
    fi
    read -p "  Нажмите Enter..." < /dev/tty
}

_telemt_add_user() {
    local name="$1"
    local conf_file="${MTG_CONF_DIR}/${name}.toml"
    [ ! -f "$conf_file" ] && { echo -e "  ${RED}Конфиг не найден${NC}"; return; }

    echo -ne "  Имя нового пользователя: "; read -r uname < /dev/tty
    [[ -z "$uname" ]] && return
    local usecret; usecret=$(python3 -c "import os,binascii; print(binascii.hexlify(os.urandom(16)).decode())")

    # Добавляем в конфиг
    echo "${uname} = \"${usecret}\"" >> "$conf_file"

    # Перезапускаем
    docker restart "$name" 2>/dev/null || systemctl restart "$name" 2>/dev/null
    echo -e "  ${GREEN}✓ Пользователь ${uname} добавлен, секрет: ${usecret}${NC}"
    sleep 2
}

_telemt_remove() {
    local name="$1"
    local _yn; _yn=$(read_yn "  ${RED}Удалить Telemt прокси ${name}? (y/n): ${NC}")
    [ "$_yn" != "y" ] && return
    # Systemd
    systemctl stop "${name}" 2>/dev/null
    systemctl disable "${name}" 2>/dev/null
    rm -f "/etc/systemd/system/${name}.service" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    # Docker (если запущен как контейнер)
    docker stop "${name}" 2>/dev/null
    docker rm "${name}" 2>/dev/null
    # Конфиги
    rm -f "${MTG_CONF_DIR}/${name}.toml" "${MTG_CONF_DIR}/${name}.meta" 2>/dev/null
    echo -e "  ${GREEN}✓ Прокси ${name} удалён${NC}"; sleep 2
}

# ═══════════════════════════════════════════════════════════════
#  SSL ПРОВЕРКА И ВЫПУСК ДЛЯ ЗАГЛУШКИ
# ═══════════════════════════════════════════════════════════════

_ssl_check_and_issue() {
    local domain="$1"
    [ -z "$domain" ] && return 1

    echo -e "\n  ${CYAN}Проверяем SSL для ${domain}...${NC}"

    # Проверяем существующий сертификат
    if certbot certificates 2>/dev/null | grep -q "Domains:.*${domain}"; then
        local expiry; expiry=$(certbot certificates 2>/dev/null | grep -A3 "Domains:.*${domain}" | grep "Expiry" | awk '{print $3}')
        echo -e "  ${GREEN}✓ SSL сертификат есть (истекает: ${expiry})${NC}"
        return 0
    fi

    echo -e "  ${YELLOW}SSL сертификат не найден — выпускаем...${NC}"

    # Проверяем что порт 80 доступен
    if ss -tlnp | grep -q ":80.*nginx\|:80.*apache"; then
        # Используем webroot
        local webroot="/var/www/${domain}"
        mkdir -p "$webroot"
        certbot certonly --webroot -w "$webroot" -d "$domain" \
            --non-interactive --agree-tos -m "admin@${domain}" 2>/dev/null && {
            echo -e "  ${GREEN}✓ SSL выпущен через webroot${NC}"; return 0
        }
    fi

    # Standalone (временно останавливаем nginx)
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$domain" \
        --non-interactive --agree-tos -m "admin@${domain}" 2>/dev/null && {
        systemctl start nginx 2>/dev/null
        echo -e "  ${GREEN}✓ SSL выпущен через standalone${NC}"; return 0
    }
    systemctl start nginx 2>/dev/null
    echo -e "  ${RED}✗ Не удалось выпустить SSL — проверь DNS и порт 80${NC}"
    return 1
}

# ═══════════════════════════════════════════════════════════════
#  HTML ЗАГЛУШКИ — ВЫБОР ШАБЛОНА
# ═══════════════════════════════════════════════════════════════

_stub_templates() {
    local domain="$1"
    local webroot="${2:-/var/www/${domain}}"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ HTML Заглушка для ${domain} ━━━${NC}\n"
        echo -e "  ${WHITE}── Категории ────────────────────────${NC}"
        echo -e "  ${YELLOW}[1]${NC}  📰 Новостной блог / IT медиа"
        echo -e "  ${YELLOW}[2]${NC}  🏢 Бизнес / Корпоративный сайт"
        echo -e "  ${YELLOW}[3]${NC}  🛠️  Технологии / SaaS"
        echo -e "  ${YELLOW}[4]${NC}  🎓 Образование / Курсы"
        echo -e "  ${YELLOW}[5]${NC}  🛒 Магазин / E-commerce"
        echo -e "  ${YELLOW}[6]${NC}  👤 Портфолио / Личный сайт"
        echo -e "  ${YELLOW}[7]${NC}  🔧 В разработке (Under Construction)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1) _stub_create_news "$webroot" "$domain" ;;
            2) _stub_create_business "$webroot" "$domain" ;;
            3) _stub_create_saas "$webroot" "$domain" ;;
            4) _stub_create_education "$webroot" "$domain" ;;
            5) _stub_create_shop "$webroot" "$domain" ;;
            6) _stub_create_portfolio "$webroot" "$domain" ;;
            7) _stub_create_under_construction "$webroot" "$domain" ;;
            0|"") return ;;
        esac

        # После создания — перезагрузить nginx
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
        echo -e "\n  ${GREEN}✓ Заглушка установлена! Проверь: http://${domain}${NC}"
        read -p "  Enter для продолжения..." < /dev/tty
        return
    done
}

_stub_create_news() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TechNews — Новости технологий</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#f4f6f8;color:#333}
header{background:#1a1a2e;color:#fff;padding:0 20px}
.header-inner{max-width:1100px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;height:60px}
.logo{font-size:1.4em;font-weight:700;color:#e94560}
nav a{color:#ccc;text-decoration:none;margin-left:20px;font-size:.9em}
nav a:hover{color:#fff}
.hero{background:linear-gradient(135deg,#1a1a2e,#16213e);color:#fff;padding:60px 20px;text-align:center}
.hero h1{font-size:2.2em;margin-bottom:15px}
.hero p{color:#aaa;font-size:1.1em;max-width:600px;margin:0 auto 25px}
.btn{background:#e94560;color:#fff;padding:12px 28px;border-radius:5px;text-decoration:none;font-size:.95em}
.container{max-width:1100px;margin:40px auto;padding:0 20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:25px}
.card{background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08)}
.card-img{height:160px;background:linear-gradient(135deg,#667eea,#764ba2);display:flex;align-items:center;justify-content:center;font-size:3em}
.card-body{padding:20px}
.tag{background:#e94560;color:#fff;font-size:.7em;padding:3px 8px;border-radius:3px;text-transform:uppercase}
.card h3{margin:10px 0 8px;font-size:1.05em}
.card p{color:#666;font-size:.9em;line-height:1.5}
.card-meta{color:#999;font-size:.8em;margin-top:12px}
footer{background:#1a1a2e;color:#777;text-align:center;padding:30px;margin-top:60px;font-size:.9em}
</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div class="logo">⚡ TechNews</div>
    <nav>
      <a href="#">Главная</a><a href="#">ИИ</a><a href="#">Безопасность</a><a href="#">Разработка</a>
    </nav>
  </div>
</header>
<div class="hero">
  <h1>Технологии, которые меняют мир</h1>
  <p>Актуальные новости из мира IT, искусственного интеллекта и кибербезопасности</p>
  <a href="#" class="btn">Читать далее</a>
</div>
<div class="container">
  <div class="grid">
    <div class="card">
      <div class="card-img">🤖</div>
      <div class="card-body">
        <span class="tag">ИИ</span>
        <h3>Новые модели ИИ устанавливают рекорды производительности</h3>
        <p>Исследователи представили архитектуру, превосходящую предыдущие решения на ключевых бенчмарках.</p>
        <div class="card-meta">5 минут назад · 3 мин чтения</div>
      </div>
    </div>
    <div class="card">
      <div class="card-img">🔐</div>
      <div class="card-body">
        <span class="tag">Безопасность</span>
        <h3>Критическая уязвимость обнаружена в популярном ПО</h3>
        <p>Специалисты рекомендуют немедленно обновить системы для защиты от эксплойта.</p>
        <div class="card-meta">1 час назад · 5 мин чтения</div>
      </div>
    </div>
    <div class="card">
      <div class="card-img">💻</div>
      <div class="card-body">
        <span class="tag">Dev</span>
        <h3>Rust обходит C++ по популярности в системном программировании</h3>
        <p>Ежегодный опрос разработчиков зафиксировал значительный сдвиг предпочтений.</p>
        <div class="card-meta">3 часа назад · 4 мин чтения</div>
      </div>
    </div>
  </div>
</div>
<footer>© 2026 TechNews. Все права защищены.</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Новостной блог' создан${NC}"
}

_stub_create_business() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Nexora — Бизнес решения</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#333}
header{background:#fff;box-shadow:0 1px 3px rgba(0,0,0,.1);padding:0 30px;position:sticky;top:0;z-index:10}
.header-inner{max-width:1100px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;height:65px}
.logo{font-size:1.5em;font-weight:800;color:#2563eb}
nav a{color:#555;text-decoration:none;margin-left:25px;font-size:.9em;font-weight:500}
.btn-nav{background:#2563eb;color:#fff!important;padding:8px 18px;border-radius:6px}
.hero{background:linear-gradient(135deg,#eff6ff,#dbeafe);padding:90px 30px;text-align:center}
.hero h1{font-size:2.8em;font-weight:800;color:#1e3a8a;margin-bottom:20px;line-height:1.2}
.hero p{color:#64748b;font-size:1.15em;max-width:580px;margin:0 auto 35px}
.btn-primary{background:#2563eb;color:#fff;padding:14px 32px;border-radius:8px;text-decoration:none;font-weight:600;margin-right:10px}
.btn-secondary{background:#fff;color:#2563eb;padding:14px 32px;border-radius:8px;text-decoration:none;font-weight:600;border:2px solid #2563eb}
.stats{display:flex;justify-content:center;gap:60px;padding:50px;background:#fff}
.stat{text-align:center}
.stat .num{font-size:2.2em;font-weight:800;color:#2563eb}
.stat .label{color:#64748b;font-size:.9em;margin-top:5px}
.features{max-width:1100px;margin:60px auto;padding:0 30px;display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:30px}
.feature{background:#f8fafc;padding:30px;border-radius:12px;border-left:4px solid #2563eb}
.feature .icon{font-size:2em;margin-bottom:15px}
.feature h3{font-weight:700;margin-bottom:10px}
.feature p{color:#64748b;line-height:1.6;font-size:.95em}
footer{background:#1e3a8a;color:#94a3b8;text-align:center;padding:35px;font-size:.9em}
</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div class="logo">Nexora</div>
    <nav>
      <a href="#">Решения</a><a href="#">О нас</a><a href="#">Цены</a><a href="#" class="btn-nav">Начать</a>
    </nav>
  </div>
</header>
<div class="hero">
  <h1>Масштабируйте бизнес<br>с умными решениями</h1>
  <p>Комплексные IT-решения для роста вашей компании. Автоматизация, аналитика, безопасность.</p>
  <a href="#" class="btn-primary">Попробовать бесплатно</a>
  <a href="#" class="btn-secondary">Узнать больше</a>
</div>
<div class="stats">
  <div class="stat"><div class="num">500+</div><div class="label">Клиентов</div></div>
  <div class="stat"><div class="num">99.9%</div><div class="label">Uptime</div></div>
  <div class="stat"><div class="num">24/7</div><div class="label">Поддержка</div></div>
  <div class="stat"><div class="num">5 лет</div><div class="label">На рынке</div></div>
</div>
<div class="features">
  <div class="feature"><div class="icon">🚀</div><h3>Быстрое развёртывание</h3><p>Запустите решение за несколько часов без долгих внедрений и сложных настроек.</p></div>
  <div class="feature"><div class="icon">🔒</div><h3>Корпоративная безопасность</h3><p>Шифрование данных, контроль доступа и соответствие требованиям GDPR.</p></div>
  <div class="feature"><div class="icon">📊</div><h3>Аналитика в реальном времени</h3><p>Дашборды и отчёты для принятия обоснованных бизнес-решений.</p></div>
</div>
<footer>© 2026 Nexora Technologies. Все права защищены.</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Бизнес' создан${NC}"
}

_stub_create_saas() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CloudFlow — SaaS платформа</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0f0f23;color:#e2e8f0}
header{padding:20px 40px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid #1e293b}
.logo{font-size:1.4em;font-weight:700;background:linear-gradient(135deg,#667eea,#764ba2);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
nav a{color:#94a3b8;text-decoration:none;margin-left:20px;font-size:.9em;transition:.2s}
nav a:hover{color:#fff}
.btn-hero{background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;padding:9px 20px;border-radius:20px;text-decoration:none;font-size:.9em}
.hero{text-align:center;padding:100px 40px 80px;max-width:900px;margin:0 auto}
.badge{display:inline-block;background:#1e293b;color:#667eea;padding:6px 16px;border-radius:20px;font-size:.85em;margin-bottom:25px;border:1px solid #334155}
.hero h1{font-size:3.2em;font-weight:800;line-height:1.15;margin-bottom:20px}
.hero h1 span{background:linear-gradient(135deg,#667eea,#764ba2);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.hero p{color:#94a3b8;font-size:1.15em;line-height:1.7;max-width:600px;margin:0 auto 40px}
.actions{display:flex;justify-content:center;gap:15px;flex-wrap:wrap}
.btn-main{background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;padding:14px 30px;border-radius:8px;text-decoration:none;font-weight:600}
.btn-ghost{color:#e2e8f0;padding:14px 30px;border-radius:8px;text-decoration:none;border:1px solid #334155}
.features{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px;max-width:1000px;margin:0 auto 80px;padding:0 40px}
.feature{background:#1e293b;border:1px solid #334155;border-radius:12px;padding:25px}
.feature .icon{font-size:1.8em;margin-bottom:12px}
.feature h3{font-size:1em;margin-bottom:8px;color:#f1f5f9}
.feature p{color:#64748b;font-size:.88em;line-height:1.6}
footer{border-top:1px solid #1e293b;text-align:center;padding:30px;color:#475569;font-size:.85em}
</style>
</head>
<body>
<header>
  <div class="logo">⚡ CloudFlow</div>
  <nav>
    <a href="#">Возможности</a><a href="#">Цены</a><a href="#">Документация</a>
    <a href="#" class="btn-hero">Начать →</a>
  </nav>
</header>
<div class="hero">
  <div class="badge">🚀 Новый релиз v3.0</div>
  <h1>Инфраструктура для <span>современных команд</span></h1>
  <p>Разворачивайте, масштабируйте и управляйте сервисами одним кликом. Без DevOps экспертизы.</p>
  <div class="actions">
    <a href="#" class="btn-main">Попробовать бесплатно</a>
    <a href="#" class="btn-ghost">Смотреть демо</a>
  </div>
</div>
<div class="features">
  <div class="feature"><div class="icon">⚡</div><h3>Мгновенный деплой</h3><p>Push в Git — и приложение уже в продакшне. CI/CD из коробки.</p></div>
  <div class="feature"><div class="icon">📈</div><h3>Автомасштабирование</h3><p>Система сама добавит ресурсы при пиковой нагрузке и уберёт их после.</p></div>
  <div class="feature"><div class="icon">🔐</div><h3>Zero-trust безопасность</h3><p>Сквозное шифрование и управление доступом на уровне сервиса.</p></div>
  <div class="feature"><div class="icon">📊</div><h3>Метрики и алерты</h3><p>Prometheus, Grafana и умные уведомления о проблемах.</p></div>
</div>
<footer>© 2026 CloudFlow Technologies · Политика конфиденциальности</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'SaaS' создан${NC}"
}

_stub_create_education() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>EduPath — Онлайн обучение</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#fff;color:#1a1a1a}
header{background:#fff;box-shadow:0 1px 4px rgba(0,0,0,.08);padding:0 30px;position:sticky;top:0;z-index:10}
.header-inner{max-width:1100px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;height:65px}
.logo{font-size:1.4em;font-weight:800;color:#7c3aed}
nav a{color:#6b7280;text-decoration:none;margin-left:22px;font-size:.9em;font-weight:500}
.btn-start{background:#7c3aed;color:#fff!important;padding:9px 20px;border-radius:7px}
.hero{background:linear-gradient(135deg,#f5f3ff,#ede9fe);padding:80px 30px;text-align:center}
.hero h1{font-size:2.6em;font-weight:800;color:#4c1d95;margin-bottom:18px;line-height:1.25}
.hero p{color:#6d28d9;font-size:1.1em;max-width:560px;margin:0 auto 30px;opacity:.8}
.btn-cta{background:#7c3aed;color:#fff;padding:14px 30px;border-radius:8px;text-decoration:none;font-weight:600;font-size:1em}
.courses{max-width:1100px;margin:60px auto;padding:0 30px}
.courses h2{font-size:1.7em;font-weight:700;margin-bottom:30px;text-align:center}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:25px}
.course{background:#fff;border:1px solid #e5e7eb;border-radius:12px;overflow:hidden;transition:.2s}
.course:hover{box-shadow:0 8px 25px rgba(124,58,237,.15);transform:translateY(-2px)}
.course-header{padding:30px;text-align:center;font-size:3em}
.course-header.py{background:#fef3c7}
.course-header.js{background:#dbeafe}
.course-header.sec{background:#fee2e2}
.course-body{padding:20px}
.course-body h3{font-weight:700;margin-bottom:8px}
.course-body p{color:#6b7280;font-size:.9em;line-height:1.5;margin-bottom:12px}
.meta{display:flex;justify-content:space-between;font-size:.82em;color:#9ca3af}
.enroll{display:block;text-align:center;background:#7c3aed;color:#fff;padding:10px;border-radius:6px;text-decoration:none;margin-top:15px;font-size:.9em}
footer{background:#4c1d95;color:#c4b5fd;text-align:center;padding:30px;font-size:.9em;margin-top:60px}
</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div class="logo">📚 EduPath</div>
    <nav>
      <a href="#">Курсы</a><a href="#">Преподаватели</a><a href="#">Блог</a><a href="#" class="btn-start">Войти</a>
    </nav>
  </div>
</header>
<div class="hero">
  <h1>Освойте IT профессию<br>онлайн</h1>
  <p>Практические курсы от экспертов индустрии. Учитесь в своём темпе, получайте реальные навыки.</p>
  <a href="#" class="btn-cta">Начать бесплатно →</a>
</div>
<div class="courses">
  <h2>Популярные курсы</h2>
  <div class="grid">
    <div class="course">
      <div class="course-header py">🐍</div>
      <div class="course-body">
        <h3>Python для начинающих</h3>
        <p>Основы программирования, работа с данными, автоматизация задач.</p>
        <div class="meta"><span>⏱ 40 часов</span><span>👥 12,400 студентов</span></div>
        <a href="#" class="enroll">Записаться</a>
      </div>
    </div>
    <div class="course">
      <div class="course-header js">🌐</div>
      <div class="course-body">
        <h3>Full-Stack JavaScript</h3>
        <p>React, Node.js, базы данных. Создайте полноценное веб-приложение.</p>
        <div class="meta"><span>⏱ 80 часов</span><span>👥 8,200 студентов</span></div>
        <a href="#" class="enroll">Записаться</a>
      </div>
    </div>
    <div class="course">
      <div class="course-header sec">🛡️</div>
      <div class="course-body">
        <h3>Кибербезопасность</h3>
        <p>Пентест, защита сетей, анализ уязвимостей. Подготовка к CEH.</p>
        <div class="meta"><span>⏱ 60 часов</span><span>👥 5,800 студентов</span></div>
        <a href="#" class="enroll">Записаться</a>
      </div>
    </div>
  </div>
</div>
<footer>© 2026 EduPath · Политика конфиденциальности · Условия использования</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Образование' создан${NC}"
}

_stub_create_shop() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>TechStore — Электроника</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#f9fafb;color:#111}
header{background:#111;color:#fff;padding:0 30px}
.header-inner{max-width:1200px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;height:65px}
.logo{font-size:1.4em;font-weight:700}
.logo span{color:#f59e0b}
nav a{color:#d1d5db;text-decoration:none;margin-left:20px;font-size:.9em}
.cart{background:#f59e0b;color:#111;padding:8px 16px;border-radius:6px;font-weight:600;font-size:.85em}
.banner{background:linear-gradient(135deg,#111,#1f2937);color:#fff;padding:70px 30px;text-align:center}
.banner h1{font-size:2.5em;font-weight:800;margin-bottom:15px}
.banner h1 span{color:#f59e0b}
.banner p{color:#9ca3af;font-size:1.1em;margin-bottom:25px}
.btn-shop{background:#f59e0b;color:#111;padding:13px 28px;border-radius:7px;text-decoration:none;font-weight:700}
.products{max-width:1200px;margin:50px auto;padding:0 30px}
.products h2{font-size:1.5em;font-weight:700;margin-bottom:25px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:20px}
.product{background:#fff;border-radius:10px;overflow:hidden;box-shadow:0 2px 6px rgba(0,0,0,.07)}
.product-img{height:140px;display:flex;align-items:center;justify-content:center;font-size:4em;background:#f3f4f6}
.product-body{padding:15px}
.product-body h3{font-size:.95em;margin-bottom:6px}
.product-body .price{color:#f59e0b;font-size:1.1em;font-weight:700}
.product-body .old-price{color:#9ca3af;font-size:.85em;text-decoration:line-through;margin-left:5px}
.add-btn{display:block;text-align:center;background:#111;color:#fff;padding:9px;border-radius:6px;text-decoration:none;margin-top:12px;font-size:.9em}
footer{background:#111;color:#6b7280;text-align:center;padding:30px;font-size:.85em;margin-top:60px}
</style>
</head>
<body>
<header>
  <div class="header-inner">
    <div class="logo">Tech<span>Store</span></div>
    <nav><a href="#">Каталог</a><a href="#">Акции</a><a href="#">Доставка</a><a href="#" class="cart">🛒 Корзина</a></nav>
  </div>
</header>
<div class="banner">
  <h1>Электроника по <span>лучшим ценам</span></h1>
  <p>Гарантия качества · Быстрая доставка · Официальная гарантия</p>
  <a href="#" class="btn-shop">В каталог →</a>
</div>
<div class="products">
  <h2>🔥 Хиты продаж</h2>
  <div class="grid">
    <div class="product"><div class="product-img">💻</div><div class="product-body"><h3>Ноутбук ProBook X5</h3><span class="price">89 900 ₽</span><span class="old-price">110 000 ₽</span><a href="#" class="add-btn">В корзину</a></div></div>
    <div class="product"><div class="product-img">📱</div><div class="product-body"><h3>Смартфон Ultra Pro</h3><span class="price">54 990 ₽</span><span class="old-price">65 000 ₽</span><a href="#" class="add-btn">В корзину</a></div></div>
    <div class="product"><div class="product-img">🎧</div><div class="product-body"><h3>Наушники AirMax</h3><span class="price">12 500 ₽</span><span class="old-price">18 000 ₽</span><a href="#" class="add-btn">В корзину</a></div></div>
    <div class="product"><div class="product-img">⌚</div><div class="product-body"><h3>Смарт-часы FitPro</h3><span class="price">8 990 ₽</span><span class="old-price">12 000 ₽</span><a href="#" class="add-btn">В корзину</a></div></div>
  </div>
</div>
<footer>© 2026 TechStore · ИНН 7712345678 · Все права защищены</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Магазин' создан${NC}"
}

_stub_create_portfolio() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Alex Dev — Full Stack разработчик</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0a0a0a;color:#e2e8f0;line-height:1.6}
nav{position:fixed;top:0;width:100%;background:rgba(10,10,10,.9);backdrop-filter:blur(10px);padding:18px 40px;display:flex;justify-content:space-between;align-items:center;z-index:100;border-bottom:1px solid #1e293b}
.logo{font-weight:700;color:#38bdf8;font-size:1.1em}
nav a{color:#94a3b8;text-decoration:none;margin-left:20px;font-size:.9em;transition:.2s}
nav a:hover{color:#38bdf8}
.hero{min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center;padding:40px;background:radial-gradient(ellipse at center,#0f172a 0%,#0a0a0a 70%)}
.hero-content{max-width:700px}
.greeting{color:#38bdf8;font-size:.95em;letter-spacing:.1em;text-transform:uppercase;margin-bottom:15px}
.hero h1{font-size:3.5em;font-weight:800;margin-bottom:15px;line-height:1.1}
.hero h1 span{color:#38bdf8}
.hero p{color:#64748b;font-size:1.1em;margin-bottom:35px}
.skills{display:flex;flex-wrap:wrap;justify-content:center;gap:10px;margin-bottom:35px}
.skill{background:#1e293b;color:#38bdf8;padding:6px 14px;border-radius:20px;font-size:.85em;border:1px solid #334155}
.actions{display:flex;justify-content:center;gap:15px}
.btn-main{background:#38bdf8;color:#0a0a0a;padding:13px 28px;border-radius:8px;text-decoration:none;font-weight:700}
.btn-ghost{color:#e2e8f0;padding:13px 28px;border-radius:8px;text-decoration:none;border:1px solid #334155}
.projects{max-width:900px;margin:80px auto;padding:0 40px}
.projects h2{font-size:1.8em;font-weight:700;text-align:center;margin-bottom:40px}
.project-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px}
.project{background:#0f172a;border:1px solid #1e293b;border-radius:12px;padding:25px;transition:.2s}
.project:hover{border-color:#38bdf8;transform:translateY(-3px)}
.project .icon{font-size:2em;margin-bottom:12px}
.project h3{font-weight:700;margin-bottom:8px;font-size:1em}
.project p{color:#64748b;font-size:.88em}
footer{text-align:center;padding:40px;color:#334155;border-top:1px solid #1e293b;font-size:.85em}
</style>
</head>
<body>
<nav>
  <div class="logo">&lt;AlexDev /&gt;</div>
  <div><a href="#">О себе</a><a href="#">Проекты</a><a href="#">Контакты</a></div>
</nav>
<div class="hero">
  <div class="hero-content">
    <div class="greeting">👋 Привет, я</div>
    <h1>Full Stack <span>разработчик</span></h1>
    <p>Создаю современные веб-приложения и API. Специализация на React, Node.js и облачных решениях.</p>
    <div class="skills">
      <span class="skill">React</span><span class="skill">Node.js</span><span class="skill">TypeScript</span>
      <span class="skill">PostgreSQL</span><span class="skill">Docker</span><span class="skill">Rust</span>
    </div>
    <div class="actions">
      <a href="#" class="btn-main">Смотреть проекты</a>
      <a href="#" class="btn-ghost">Написать</a>
    </div>
  </div>
</div>
<div class="projects">
  <h2>Избранные проекты</h2>
  <div class="project-grid">
    <div class="project"><div class="icon">🛒</div><h3>E-commerce платформа</h3><p>Полноценный магазин с корзиной, оплатой и админкой. React + Node + PostgreSQL.</p></div>
    <div class="project"><div class="icon">📊</div><h3>Аналитический дашборд</h3><p>Визуализация данных в реальном времени. WebSockets + D3.js + Redis.</p></div>
    <div class="project"><div class="icon">🤖</div><h3>Telegram бот</h3><p>Автоматизация бизнес-процессов. Python + aiogram + PostgreSQL.</p></div>
  </div>
</div>
<footer>© 2026 AlexDev · Сделано с ❤️ и ☕</footer>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Портфолио' создан${NC}"
}

_stub_create_under_construction() {
    local webroot="$1" domain="$2"
    mkdir -p "$webroot"
    cat > "${webroot}/index.html" << HTMLEOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${domain} — Скоро</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:linear-gradient(135deg,#0f0c29,#302b63,#24243e);min-height:100vh;display:flex;align-items:center;justify-content:center;color:#fff;text-align:center;padding:20px}
.container{max-width:550px}
.icon{font-size:5em;margin-bottom:25px;display:block}
h1{font-size:2.5em;font-weight:800;margin-bottom:15px}
p{color:#a78bfa;font-size:1.1em;line-height:1.6;margin-bottom:35px}
.domain{color:#c4b5fd;font-size:.9em;margin-bottom:40px;opacity:.7}
.counter{display:flex;justify-content:center;gap:20px;margin-bottom:40px}
.counter-item{background:rgba(255,255,255,.1);backdrop-filter:blur(10px);border:1px solid rgba(255,255,255,.2);border-radius:12px;padding:20px 25px;min-width:80px}
.counter-item .num{font-size:2em;font-weight:800}
.counter-item .label{font-size:.75em;opacity:.7;margin-top:5px;text-transform:uppercase}
.notify{display:flex;max-width:400px;margin:0 auto;gap:10px}
.notify input{flex:1;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.2);border-radius:8px;padding:12px 16px;color:#fff;font-size:.9em;outline:none}
.notify input::placeholder{color:rgba(255,255,255,.4)}
.notify button{background:#7c3aed;color:#fff;border:none;border-radius:8px;padding:12px 20px;cursor:pointer;font-size:.9em;white-space:nowrap}
footer{position:fixed;bottom:20px;color:rgba(255,255,255,.3);font-size:.8em;width:100%;text-align:center}
</style>
</head>
<body>
<div class="container">
  <span class="icon">🚀</span>
  <h1>Скоро открытие</h1>
  <p>Мы работаем над чем-то особенным. Подпишитесь, чтобы узнать первыми.</p>
  <div class="domain">${domain}</div>
  <div class="counter">
    <div class="counter-item"><div class="num" id="days">14</div><div class="label">Дней</div></div>
    <div class="counter-item"><div class="num" id="hours">07</div><div class="label">Часов</div></div>
    <div class="counter-item"><div class="num" id="mins">23</div><div class="label">Минут</div></div>
    <div class="counter-item"><div class="num" id="secs">45</div><div class="label">Секунд</div></div>
  </div>
  <div class="notify">
    <input type="email" placeholder="Ваш email">
    <button>Уведомить</button>
  </div>
</div>
<footer>${domain}</footer>
<script>
const target=new Date(Date.now()+14*24*3600*1000);
setInterval(()=>{
  const d=target-Date.now();
  if(d<0)return;
  const pad=n=>String(Math.floor(n)).padStart(2,'0');
  document.getElementById('days').textContent=pad(d/86400000);
  document.getElementById('hours').textContent=pad(d%86400000/3600000);
  document.getElementById('mins').textContent=pad(d%3600000/60000);
  document.getElementById('secs').textContent=pad(d%60000/1000);
},1000);
</script>
</body>
</html>
HTMLEOF
    echo -e "  ${GREEN}✓ Шаблон 'Under Construction' создан${NC}"
}

# Настройка заглушки — полный цикл (SSL + nginx + шаблон)
_stub_setup_full() {
    clear
    echo -e "\n${CYAN}━━━ Настройка сайта-заглушки ━━━${NC}\n"

    echo -ne "  Домен сайта: "; read -r domain < /dev/tty
    [[ -z "$domain" ]] && return

    local webroot="/var/www/${domain}"

    # 1. SSL
    _ssl_check_and_issue "$domain"

    # 2. nginx конфиг
    local ssl_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
    local ssl_key="/etc/letsencrypt/live/${domain}/privkey.pem"
    local nginx_conf="/etc/nginx/sites-available/${domain}"

    mkdir -p "$webroot"
    # Определяем свободный порт для HTTPS nginx
    local https_port=443
    for try_port in 443 8443 7443 17443 9443; do
        if ! ss -tlnp | grep -q ":${try_port} "; then
            https_port=$try_port
            break
        elif ss -tlnp | grep -q ":${try_port}.*nginx"; then
            https_port=$try_port
            break
        fi
    done
    echo -e "  ${CYAN}HTTPS nginx будет на порту ${https_port}${NC}"
    # Всегда пересоздаём конфиг

    if [ -f "$ssl_cert" ]; then
        cat > "$nginx_conf" << NGINXEOF
server {
    listen 80;
    server_name ${domain};
    # Редирект на правильный HTTPS порт
    return 301 https://\$host:${https_port}\$request_uri;
}
server {
    listen ${https_port} ssl http2;
    server_name ${domain};
    ssl_certificate     ${ssl_cert};
    ssl_certificate_key ${ssl_key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    root ${webroot};
    index index.html;
    location /.well-known/acme-challenge/ { root ${webroot}; }
    location / { try_files \$uri \$uri/ =404; }
}
NGINXEOF
        echo -e "  ${CYAN}HTTPS будет на порту ${https_port}${NC}"
    else
        cat > "$nginx_conf" << NGINXEOF
server {
    listen 80;
    server_name ${domain};
    root ${webroot};
    index index.html;
    location /.well-known/acme-challenge/ { root ${webroot}; }
    location / { try_files \$uri \$uri/ =404; }
}
NGINXEOF
    fi
    ln -sf "$nginx_conf" "/etc/nginx/sites-available/${domain}" 2>/dev/null || true
    ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/${domain}"
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null
    nginx -t && systemctl reload nginx && echo -e "  ${GREEN}✓ nginx настроен${NC}"

    # 3. Выбор шаблона
    _stub_templates "$domain" "$webroot"
}


# ═══════════════════════════════════════════════════════════════
#  УМНОЕ ОПРЕДЕЛЕНИЕ ПОРТОВ ДЛЯ TELEMT/MTG
# ═══════════════════════════════════════════════════════════════

# Возвращает список занятых портов
_get_busy_ports() {
    ss -tlnp 2>/dev/null | grep -oP ':\K\d+(?= )' | sort -un
}

# Находит свободный порт из списка предпочтений
_find_free_port() {
    local -a preferred=("$@")
    local busy; busy=$(_get_busy_ports)
    for p in "${preferred[@]}"; do
        echo "$busy" | grep -qx "$p" || { echo "$p"; return 0; }
    done
    # Генерируем случайный в диапазоне 20000-50000
    local rnd=$(( RANDOM % 30000 + 20000 ))
    while echo "$busy" | grep -qx "$rnd"; do
        rnd=$(( RANDOM % 30000 + 20000 ))
    done
    echo "$rnd"
}

# Определяет рекомендуемые настройки MTProto для текущего сервера
_mtg_recommend_settings() {
    local mode="$MODE"
    local busy; busy=$(_get_busy_ports)

    echo "MODE=${mode}"

    # Определяем свободный порт
    if [ "$mode" = "3xui" ] || [ "$mode" = "combo" ]; then
        # На x-ui серверах 443 и 8443 обычно заняты nginx/xray
        local rec_port; rec_port=$(_find_free_port 2053 2083 2087 8443 443)
        echo "REC_PORT=${rec_port}"
        # Если 443 занят — Self-Steal невозможен напрямую
        if echo "$busy" | grep -qx "443"; then
            echo "SELF_STEAL=no"
            echo "NOTE=Порт 443 занят nginx/xray. Telemt будет на ${rec_port}. Self-Steal через nginx возможен отдельно."
        else
            echo "SELF_STEAL=yes"
            echo "NOTE=Порт 443 свободен — можно Self-Steal"
        fi
    elif [ "$mode" = "amnezia" ]; then
        # На AWG серверах 443 обычно свободен или занят MTG/Telemt
        local rec_port; rec_port=$(_find_free_port 443 8443 2053)
        echo "REC_PORT=${rec_port}"
        if echo "$busy" | grep -qx "443"; then
            echo "SELF_STEAL=no"
            echo "NOTE=Порт 443 занят. Используем ${rec_port}."
        else
            echo "SELF_STEAL=yes"
            echo "NOTE=Порт 443 свободен — рекомендуется для лучшей маскировки"
        fi
    else
        local rec_port; rec_port=$(_find_free_port 443 2053 8443)
        echo "REC_PORT=${rec_port}"
        echo "SELF_STEAL=unknown"
        echo "NOTE=Режим сервера не определён"
    fi
}

mtproto_menu() {
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
                case "$ctype" in
                    telemt)  type_label=" ${GREEN}[Telemt/Rust]${NC}" ;;
                    external) type_label=" ${YELLOW}[внешний]${NC}" ;;
                    govpn)   type_label=" ${CYAN}[mtg]${NC}" ;;
                esac

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

        echo -e "  ${WHITE}── Добавить ─────────────────────────${NC}"
        echo -e "  ${YELLOW}[+]${NC}  Новый прокси (mtg)"
        echo -e "  ${YELLOW}[t]${NC}  Новый прокси ${GREEN}Telemt${NC} ${CYAN}(Rust, быстрее)${NC}"
        [ ${#names[@]} -gt 0 ] && echo -e "  ${YELLOW}[номер]${NC}  Управление прокси"
        echo -e "  ${WHITE}── Сайт ──────────────────────────────${NC}"
        echo -e "  ${CYAN}[s]${NC}  Настроить сайт-заглушку (SSL + шаблон)"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        ch=$(read_choice "Выбор: ")

        [ "$ch" = "0" ] || [ -z "$ch" ] && return
        [ "$ch" = "+" ] && { _mtg_add; continue; }
        [ "$ch" = "t" ] || [ "$ch" = "T" ] && { _telemt_add; continue; }
        [ "$ch" = "s" ] || [ "$ch" = "S" ] && { _stub_setup_full; continue; }

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

        # Мониторинг системы
        local _sys_stats; _sys_stats=$(get_sys_stats)
        echo -e "  ${WHITE}SYS:  ${CYAN}${_sys_stats}${NC}"
        if is_amnezia; then
            local _awg_stats; _awg_stats=$(get_awg_stats)
            [ -n "$_awg_stats" ] && echo -e "  ${WHITE}AWG:  ${GREEN}${_awg_stats}${NC}"
        fi

        # Hysteria2 статус скрыт (протокол заблокирован ТСПУ)

        # Уведомление о новой версии (из кеша, без задержки)
        local _upd_cached; _upd_cached=$(_update_cached_ver)
        if [ -n "$_upd_cached" ] && [ "$_upd_cached" != "$VERSION" ]; then
            echo -e "  ${YELLOW}★ Доступна v${_upd_cached}${NC}  ${WHITE}→ govpn update${NC}"
        fi

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
        if is_3xui; then
            echo -e " ${CYAN}── 3X-UI ─────────────────────────────${NC}"
            echo -e "  ${GREEN}3)  Клиенты 3X-UI${NC}"
            echo -e "  ${CYAN}i)  Inbound'ы (создать/управлять)${NC}"
        fi
        echo -e " ${CYAN}── ПРОКСИ ────────────────────────────${NC}"
        # MTProto только на не-bridge серверах
        if ! is_bridge; then
            local _mtg_cnt; _mtg_cnt=$(_mtg_count_running 2>/dev/null || echo 0)
            if [ "$_mtg_cnt" -gt 0 ]; then
                echo -e "  ${GREEN}5)  MTProto прокси${NC}  ${CYAN}(${_mtg_cnt} активных)${NC}"
            else
                echo -e "  5)  MTProto прокси"
            fi
        fi
        echo -e "  6)  iptables проброс"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e "  7)  Серверы, скорость, тесты"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e "  8)  Система и управление"
        is_amnezia && echo -e "  ${RED}!${NC}  AWG авария? → ${RED}[!]${NC} Экстренное восстановление"
        # h) Hysteria2 скрыт
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
            3)
                if is_amnezia && ! is_3xui; then
                    awg_clients_menu
                elif is_3xui; then
                    _3xui_clients_menu
                fi ;;
            4) is_amnezia && awg_peers_menu ;;
            i|I|и|И) is_3xui && _3xui_inbound_templates ;;
            5) mtproto_menu ;;
            6) iptables_menu ;;
            7) tools_menu ;;
            8) system_menu ;;
            # h|H|р|Р) is_hysteria2 && hysteria2_menu ;;
            "!") is_amnezia && _awg_emergency_restore ;;
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

    # Автодобавление IP этого сервера в список серверов
    if [ -n "$MY_IP" ] && ! grep -q "^${MY_IP}=" "$ALIASES_FILE" 2>/dev/null; then
        local geo_cc geo_city
        geo_cc=$(curl -s --max-time 3 "http://ip-api.com/json/${MY_IP}?fields=countryCode,city" 2>/dev/null | \
            python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('countryCode','')+'|'+d.get('city',''))" 2>/dev/null)
        local cc="${geo_cc%%|*}" city="${geo_cc##*|}"
        local sname="${city:-Server}"
        echo "${MY_IP}=${sname}||${cc}|" >> "$ALIASES_FILE"
    fi

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

    # Фоновая проверка обновлений (обновляет кеш если устарел, без задержки)
    _update_check_async

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
    backup)
        check_root
        init_config
        detect_interface
        get_my_ip
        detect_mode
        echo -e "\n${CYAN}━━━ Создание бэкапа ━━━${NC}\n"
        result=$(do_backup 0)
        [ -n "$result" ] && echo -e "\n  Путь: ${CYAN}${result}${NC}" || exit 1
        ;;
    update|upgrade)
        check_root
        init_config
        shift
        cmd_update "$@"
        ;;
    version|-v|--version)
        echo "GoVPN Manager v${VERSION}"
        # Показываем кешированную версию репо если есть
        local _cv; _cv=$(_update_cached_ver) 2>/dev/null || true
        [ -n "$_cv" ] && [ "$_cv" != "$VERSION" ] && \
            echo "Доступна v${_cv} → govpn update"
        ;;
    check-update)
        check_root
        init_config
        echo -ne "Проверка версии... "
        _update_fetch_bg
        local _cv; _cv=$(_update_cached_ver)
        if [ -n "$_cv" ]; then
            if [ "$_cv" = "$VERSION" ]; then
                echo -e "${GREEN}v${VERSION} — актуальная${NC}"
            else
                echo -e "${YELLOW}Доступна v${_cv}${NC} (текущая v${VERSION})"
                echo "Обновить: govpn update"
            fi
        else
            echo -e "${RED}Не удалось проверить${NC}"
        fi
        ;;
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
