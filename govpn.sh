#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  GoVPN Manager v4.0
#  Автоопределение режима · WARP мастер · iptables каскад
#  Поддержка: 3X-UI · AmneziaWG · Bridge · Combo
# ══════════════════════════════════════════════════════════════

VERSION="5.31"
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

_fmt_bytes() {
    local b=$1
    if (( b >= 1073741824 )); then
        printf "%.1fG" "$(echo "scale=1; $b/1073741824" | bc 2>/dev/null || echo 0)"
    elif (( b >= 1048576 )); then
        printf "%.1fM" "$(echo "scale=1; $b/1048576" | bc 2>/dev/null || echo 0)"
    elif (( b >= 1024 )); then
        printf "%.0fK" "$(echo "scale=0; $b/1024" | bc 2>/dev/null || echo 0)"
    else
        printf "%dB" "$b"
    fi
}

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
_3xui_load_config() {
    XUI_DB="/etc/x-ui/x-ui.db"
    XUI_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "17331")
    XUI_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    XUI_PATH="${XUI_PATH%/}"
    XUI_BASE="https://127.0.0.1:${XUI_PORT}${XUI_PATH}"
    XUI_SUB_PORT=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "")
    XUI_SUB_PATH=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath';" 2>/dev/null || echo "")
    XUI_SUB_DOMAIN=$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
}

# Авторизация — возвращает cookie значение
# Авторизация — возвращает cookie значение
_3xui_auth() {
    _3xui_load_config
    local user pass
    user=$(sqlite3 "$XUI_DB" "SELECT username FROM users LIMIT 1;" 2>/dev/null)
    pass=$(grep "^XUI_PASS=" /etc/govpn/config 2>/dev/null | cut -d= -f2-)

    [ -z "$user" ] && { echo -e "  ${RED}✗ x-ui база недоступна${NC}" >&2; return 1; }

    if [ -z "$pass" ]; then
        echo -e "\n  ${WHITE}Введите пароль от панели 3X-UI:${NC}" >&2
        read -r -s pass < /dev/tty
        echo "" >&2
        [ -z "$pass" ] && return 1
        echo "XUI_PASS=${pass}" >> /etc/govpn/config
    fi

    # Логин через файл данных — избегаем проблем с кавычками в JSON
    local cookie
    cookie=$(_3xui_login_request "$user" "$pass")

    if [ -z "$cookie" ]; then
        sed -i "/^XUI_PASS=/d" /etc/govpn/config 2>/dev/null
        echo -e "  ${RED}✗ Неверный пароль. Введите пароль:${NC}" >&2
        read -r -s pass < /dev/tty
        echo "" >&2
        [ -z "$pass" ] && return 1
        echo "XUI_PASS=${pass}" >> /etc/govpn/config
        cookie=$(_3xui_login_request "$user" "$pass")
        [ -z "$cookie" ] && { echo -e "  ${RED}✗ Авторизация не удалась${NC}" >&2; return 1; }
    fi

    echo "$cookie"
}

# Выполняет HTTP логин и возвращает cookie
_3xui_login_request() {
    local user="$1" pass="$2"
    local hf df
    hf=$(mktemp); df=$(mktemp)
    printf '{"username":"%s","password":"%s"}' "$user" "$pass" > "$df"
    curl -sk -X POST "${XUI_BASE}/login" \
        -H 'Content-Type: application/json' \
        -d "@${df}" \
        -D "$hf" -o /dev/null 2>/dev/null
    grep -ioP '3x-ui=\S+(?=;)' "$hf" 2>/dev/null | head -1
    rm -f "$hf" "$df"
}


# API запрос с авторизацией
_3xui_api() {
    local method="$1" path="$2" data="$3" cookie="$4"
    local url="${XUI_BASE}${path}"
    if [ "$method" = "GET" ]; then
        curl -sk -H "Cookie: $cookie" "$url" 2>/dev/null
    else
        curl -sk -X POST -H "Cookie: $cookie" \
            -H "Content-Type: application/json" \
            -d "$data" "$url" 2>/dev/null
    fi
}

# Получает список inbound'ов как JSON
_3xui_get_inbounds() {
    local cookie="$1"
    _3xui_api GET "/panel/api/inbounds/list" "" "$cookie"
}

# Парсит клиентов из всех inbound'ов
_3xui_parse_clients() {
    local cookie="$1"
    local json; json=$(_3xui_get_inbounds "$cookie")
    [ -z "$json" ] && return 1
    local jf; jf=$(mktemp)
    printf '%s' "$json" > "$jf"
    python3 /tmp/xui_parse.py "$jf" 2>/dev/null
    rm -f "$jf"
}

# Записывает вспомогательный python скрипт для парсинга клиентов
_3xui_write_helpers() {
    cat > /tmp/xui_parse.py << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
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
            sub_id = c.get("subId", "")
            enable = "on" if c.get("enable", True) else "off"
            up = ib.get("up", 0)
            down = ib.get("down", 0)
            key = sub_id if sub_id else email
            if key not in seen:
                seen[key] = {"email": email, "subId": sub_id, "inbounds": [], "enable": enable, "up": up, "down": down}
            if ib_id not in seen[key]["inbounds"]:
                seen[key]["inbounds"].append(ib_id)
    for v in seen.values():
        print("{}|{}|{}|{}|{}|{}".format(
            v["email"], v["subId"], ",".join(v["inbounds"]),
            v["enable"], v["up"], v["down"]))
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF
    cat > /tmp/xui_select_inbounds.py << 'PYEOF2'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    exclude = {"2", "6"}
    for ib in d.get("obj", []):
        if str(ib["id"]) not in exclude:
            print("{}|{}|{}|{}".format(
                ib["id"], ib.get("remark",""), ib.get("protocol",""), ib.get("port","")))
except Exception as e:
    sys.stderr.write("ERR:{}\n".format(e))
PYEOF2
}


# Форматирует байты в читаемый вид
_fmt_bytes() {
    local b="$1"
    python3 -c "
b=$b
if b < 1024: print(f'{b}B')
elif b < 1048576: print(f'{b/1024:.1f}K')
elif b < 1073741824: print(f'{b/1048576:.1f}M')
else: print(f'{b/1073741824:.1f}G')
" 2>/dev/null || echo "${b}B"
}

# Генерирует UUID v4
_gen_uuid() {
    python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/'
}

# Генерирует subId
_gen_subid() {
    python3 -c "import random, string; print(''.join(random.choices(string.ascii_lowercase + string.digits, k=16)))" 2>/dev/null || \
        openssl rand -hex 8
}

# Возвращает имя inbound'а по id
_3xui_inbound_name() {
    local ib_id="$1" cookie="$2"
    local json; json=$(_3xui_get_inbounds "$cookie")
    python3 -c "
import json
d=json.loads('''${json}''')
for ib in d.get('obj',[]):
    if str(ib['id'])=='${ib_id}':
        print(ib.get('remark','id=${ib_id}'))
        break
" 2>/dev/null || echo "id=${ib_id}"
}

# Показывает меню выбора inbound'ов
_3xui_select_inbounds() {
    local cookie="$1"
    local jf; jf=$(mktemp)
    _3xui_get_inbounds "$cookie" > "$jf" 2>/dev/null
    python3 /tmp/xui_select_inbounds.py "$jf" 2>/dev/null
    rm -f "$jf"
}

# Добавляет клиента в один inbound через API
_3xui_add_client_to_inbound() {
    local ib_id="$1" email="$2" uuid="$3" sub_id="$4" cookie="$5"
    local data
    data=$(python3 -c "
import json
client = {
    'id': '${uuid}',
    'email': '${email}',
    'subId': '${sub_id}',
    'enable': True,
    'flow': 'xtls-rprx-vision',
    'limitIp': 0,
    'totalGB': 0,
    'expiryTime': 0,
    'reset': 0,
    'tgId': '',
    'comment': ''
}
payload = {'id': ${ib_id}, 'settings': json.dumps({'clients': [client]})}
print(json.dumps(payload))
" 2>/dev/null)
    _3xui_api POST "/panel/api/inbounds/addClient" "$data" "$cookie"
}

# Удаляет клиента из inbound'а по email
_3xui_del_client_from_inbound() {
    local ib_id="$1" email="$2" cookie="$3"
    # Сначала получаем UUID клиента
    local json; json=$(_3xui_get_inbounds "$cookie")
    local uuid
    uuid=$(python3 -c "
import json
d=json.loads('''${json}''')
for ib in d.get('obj',[]):
    if str(ib['id'])=='${ib_id}':
        try:
            s=json.loads(ib.get('settings','{}'))
            for c in s.get('clients',[]):
                if c.get('email')=='${email}':
                    print(c.get('id',''))
                    break
        except: pass
" 2>/dev/null)
    [ -z "$uuid" ] && return 1
    _3xui_api POST "/panel/api/inbounds/${ib_id}/delClient/${uuid}" "" "$cookie"
}

# Генерирует ссылку подписки для клиента
_3xui_sub_link() {
    local sub_id="$1"
    _3xui_load_config
    if [ -n "$XUI_SUB_DOMAIN" ]; then
        echo "https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}${sub_id}"
    elif [ -n "$MY_IP" ] && [ -n "$XUI_SUB_PORT" ]; then
        echo "https://${MY_IP}:${XUI_SUB_PORT}${XUI_SUB_PATH}${sub_id}"
    else
        echo "(подписка не настроена)"
    fi
}

# ─── Главное меню управления клиентами 3X-UI ───────────────────

_3xui_clients_menu() {
    _3xui_load_config
    _3xui_write_helpers

    # Выбор сервера (алиас) если их несколько
    local target_server="local"
    if [ -f "$ALIASES_FILE" ] && [ -s "$ALIASES_FILE" ]; then
        echo -e "\n${CYAN}━━━ Выберите сервер ━━━${NC}\n"
        echo -e "  ${YELLOW}[0]${NC}  Текущий (${MY_IP})"
        local ai=1
        local -a aliases_list=()
        while IFS= read -r aline; do
            [ -z "$aline" ] || [[ "$aline" == \#* ]] && continue
            local aip="${aline%%=*}" aname="${aline##*=}"
            aname="${aname%%|*}"
            echo -e "  ${YELLOW}[$ai]${NC}  ${aname} (${aip})"
            aliases_list+=("$aip|$aname")
            (( ai++ ))
        done < "$ALIASES_FILE"
        echo ""
        read -p "  Выбор (0 = текущий): " srv_ch < /dev/tty
        if [[ "$srv_ch" =~ ^[1-9][0-9]*$ ]] && (( srv_ch < ai )); then
            target_server="${aliases_list[$((srv_ch-1))]}"
        fi
    fi

    local cookie
    cookie=$(_3xui_auth)
    if [ -z "$cookie" ]; then
        echo -e "  ${RED}✗ Не удалось авторизоваться в 3X-UI${NC}"
        read -p "  Enter..." < /dev/tty
        return 1
    fi

    while true; do
        clear
        echo -e "\n${CYAN}━━━ 3X-UI — клиенты ━━━${NC}"

        # Подписка
        _3xui_load_config
        local sub_url
        if [ -n "$XUI_SUB_DOMAIN" ]; then
            sub_url="https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}"
        else
            sub_url="http://${MY_IP}:${XUI_SUB_PORT}${XUI_SUB_PATH}"
        fi
        echo -e "  ${WHITE}Подписки:${NC} ${CYAN}${sub_url}<subId>${NC}\n"

        # Загружаем клиентов
        local -a clients=()
        local _cf; _cf=$(mktemp)
        _3xui_parse_clients "$cookie" > "$_cf" 2>/dev/null
        while IFS= read -r line; do
            [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && clients+=("$line")
        done < "$_cf"
        rm -f "$_cf"

        if [ ${#clients[@]} -eq 0 ]; then
            echo -e "  ${YELLOW}Клиентов не найдено${NC}\n"
        else
            # Заголовок таблицы с выравниванием
            printf "  \e[97m%-4s %-22s %-20s %-10s %s\e[0m\n" "№" "Email" "SubId" "Статус" "Трафик↑/↓"
            echo -e "  ${CYAN}──────────────────────────────────────────────────────────${NC}"
            local i=1
            for c in "${clients[@]}"; do
                IFS='|' read -r email sub_id inbounds enable up down <<< "$c"
                local status_col up_fmt down_fmt
                [ "$enable" = "on" ] && status_col="${GREEN}● вкл${NC}" || status_col="${RED}● выкл${NC}"
                up_fmt=$(_fmt_bytes "$up")
                down_fmt=$(_fmt_bytes "$down")
                printf "  ${YELLOW}[%-2d]${NC} %-22s %-20s %b %-4s %s/%s\n" \
                    "$i" "${email:0:21}" "${sub_id:0:19}" "$status_col" "" "$up_fmt" "$down_fmt"
                (( i++ ))
            done
            echo ""
        fi

        echo -e "  ${GREEN}[a]${NC}  Добавить клиента"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        # Проверяем 0 и пустую строку ПЕРВЫМИ
        [ "$ch" = "0" ] || [ -z "$ch" ] && return

        if [[ "$ch" =~ ^[1-9][0-9]*$ ]] && (( ch >= 1 && ch <= ${#clients[@]} )); then
            _3xui_client_profile "${clients[$((ch-1))]}" "$cookie"
            cookie=$(_3xui_auth)
        elif [[ "$ch" == "a" || "$ch" == "A" || "$ch" == "а" || "$ch" == "А" ]]; then
            _3xui_add_client_menu "$cookie"
            cookie=$(_3xui_auth)
        fi
    done
}


# Профиль конкретного клиента
_3xui_client_profile() {
    local client_str="$1" cookie="$2"
    IFS='|' read -r email sub_id inbounds enable up down <<< "$client_str"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиент: ${email} ━━━${NC}\n"

        echo -e "  ${WHITE}Email:${NC}    ${CYAN}${email}${NC}"
        echo -e "  ${WHITE}SubId:${NC}    ${CYAN}${sub_id}${NC}"
        echo -e "  ${WHITE}Статус:${NC}   $([ "$enable" = "on" ] && echo -e "${GREEN}● активен${NC}" || echo -e "${RED}● отключён${NC}")"

        # Inbound'ы клиента
        echo -e "  ${WHITE}Протоколы:${NC}"
        IFS=',' read -ra ib_arr <<< "$inbounds"
        for ib_id in "${ib_arr[@]}"; do
            local ib_name; ib_name=$(_3xui_inbound_name "$ib_id" "$cookie")
            echo -e "    ${CYAN}• ${ib_name} (id=${ib_id})${NC}"
        done

        # Подписка
        local sub_link; sub_link=$(_3xui_sub_link "$sub_id")
        echo -e "\n  ${WHITE}Подписка:${NC}"
        echo -e "  ${CYAN}${sub_link}${NC}"
        echo ""

        echo -e "  ${YELLOW}[1]${NC}  QR-код подписки"
        echo -e "  ${GREEN}[2]${NC}  Добавить протокол"
        echo -e "  ${RED}[3]${NC}  Удалить протокол"
        echo -e "  ${RED}[4]${NC}  Удалить клиента полностью"
        echo -e "  ${YELLOW}[5]${NC}  Сбросить трафик"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1)
                command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
                echo ""
                qrencode -t ANSIUTF8 "$sub_link"
                read -p "  Enter..."
                ;;
            2)
                _3xui_add_inbound_to_client "$email" "$sub_id" "$inbounds" "$cookie"
                return  # возвращаемся в список для обновления
                ;;
            3)
                _3xui_del_inbound_from_client "$email" "$inbounds" "$cookie"
                return
                ;;
            4)
                echo -ne "\n  ${RED}Удалить ${email} из всех inbound'ов? (y/n): ${NC}"
                read -r c
                [[ "$c" != "y" ]] && continue
                IFS=',' read -ra ib_arr <<< "$inbounds"
                local all_ok=1
                for ib_id in "${ib_arr[@]}"; do
                    local res; res=$(_3xui_del_client_from_inbound "$ib_id" "$email" "$cookie")
                    echo "$res" | grep -q '"success":true' || all_ok=0
                done
                [ "$all_ok" -eq 1 ] && \
                    echo -e "  ${GREEN}✓ Клиент ${email} удалён${NC}" || \
                    echo -e "  ${YELLOW}⚠ Часть inbound'ов не обновилась${NC}"
                log_action "3XUI: удалён клиент ${email}"
                read -p "  Enter..."
                return
                ;;
            5)
                local res; res=$(_3xui_api POST "/panel/api/inbounds/resetClientTraffic/${email}" "" "$cookie")
                echo "$res" | grep -q '"success":true' && \
                    echo -e "  ${GREEN}✓ Трафик сброшен${NC}" || \
                    echo -e "  ${RED}✗ Ошибка сброса${NC}"
                read -p "  Enter..."
                ;;
            0|"") return ;;
        esac
    done
}

# Добавить нового клиента
_3xui_add_client_menu() {
    local cookie="$1"
    clear
    echo -e "\n${CYAN}━━━ Добавить клиента ━━━${NC}\n"

    echo -ne "  Имя клиента (email): "; read -r email < /dev/tty
    [ -z "$email" ] && return

    # Проверяем уникальность
    local _cf; _cf=$(mktemp)
    _3xui_parse_clients "$cookie" > "$_cf" 2>/dev/null
    local existing; existing=$(grep "^${email}|" "$_cf" 2>/dev/null)
    rm -f "$_cf"
    if [ -n "$existing" ]; then
        echo -e "  ${RED}✗ Клиент '${email}' уже существует${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    local uuid sub_id
    uuid=$(_gen_uuid)
    sub_id=$(_gen_subid)

    # Загружаем список доступных inbound'ов
    local -a available_ibs=()
    local _sf; _sf=$(mktemp)
    _3xui_select_inbounds "$cookie" > "$_sf" 2>/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] && ! [[ "$line" == ERR:* ]] && available_ibs+=("$line")
    done < "$_sf"
    rm -f "$_sf"

    if [ ${#available_ibs[@]} -eq 0 ]; then
        echo -e "  ${RED}✗ Нет доступных inbound'ов${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    # Показываем список протоколов
    echo -e "\n  ${WHITE}Доступные протоколы:${NC}\n"
    local i=1
    for ib in "${available_ibs[@]}"; do
        IFS='|' read -r ib_id ib_name ib_proto ib_port <<< "$ib"
        # Очищаем emoji из названия для читаемости
        local clean_name; clean_name=$(echo "$ib_name" | sed 's/[^[:print:]]//g' | xargs)
        echo -e "  ${YELLOW}[$i]${NC}  ${clean_name:-id=$ib_id}  ${CYAN}(${ib_proto}:${ib_port})${NC}"
        (( i++ ))
    done
    echo ""
    echo -e "  ${GREEN}[a]${NC}  Все сразу (рекомендуется)"
    echo ""
    echo -e "  ${WHITE}Введите номер(а) через пробел или 'a' для всех:${NC}"
    echo -ne "  → "; read -r sel < /dev/tty

    local -a selected_ids=()
    if [[ "$sel" == "a" || "$sel" == "A" || "$sel" == "а" || "$sel" == "А" ]]; then
        for ib in "${available_ibs[@]}"; do
            selected_ids+=("${ib%%|*}")
        done
    else
        for num in $sel; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#available_ibs[@]} )); then
                selected_ids+=("${available_ibs[$((num-1))]%%|*}")
            fi
        done
    fi

    if [ ${#selected_ids[@]} -eq 0 ]; then
        echo -e "\n  ${YELLOW}Ничего не выбрано — нажмите 'a' для всех или номер протокола${NC}"
        read -p "  Enter..." < /dev/tty; return
    fi

    echo ""
    local success=0 fail=0
    for ib_id in "${selected_ids[@]}"; do
        local ib_name; ib_name=$(_3xui_inbound_name "$ib_id" "$cookie")
        echo -ne "  ${CYAN}→ Добавляю в ${ib_name}...${NC} "
        local res; res=$(_3xui_add_client_to_inbound "$ib_id" "$email" "$uuid" "$sub_id" "$cookie")
        if echo "$res" | grep -q '"success":true'; then
            echo -e "${GREEN}✓${NC}"
            (( success++ ))
        else
            local err_msg; err_msg=$(echo "$res" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('msg',''))" 2>/dev/null)
            echo -e "${RED}✗${NC}  ${err_msg}"
            (( fail++ ))
        fi
    done

    if [ "$success" -gt 0 ]; then
        local sub_link; sub_link=$(_3xui_sub_link "$sub_id")
        echo -e "\n  ${GREEN}✅ Клиент ${email} добавлен (${success} протокол(ов))${NC}"
        echo -e "  ${WHITE}Ссылка подписки:${NC}\n  ${CYAN}${sub_link}${NC}"
        echo ""
        command -v qrencode &>/dev/null || apt-get install -y qrencode > /dev/null 2>&1
        command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$sub_link"
        log_action "3XUI: добавлен клиент ${email}, subId=${sub_id}"
    fi
    [ "$fail" -gt 0 ] && echo -e "  ${YELLOW}⚠ ${fail} протокол(ов) не добавилось${NC}"
    read -p "  Enter..." < /dev/tty
}


# Добавить inbound к существующему клиенту
_3xui_add_inbound_to_client() {
    local email="$1" sub_id="$2" current_inbounds="$3" cookie="$4"
    clear
    echo -e "\n${CYAN}━━━ Добавить протокол: ${email} ━━━${NC}\n"

    # Получаем UUID клиента из первого inbound'а
    local first_ib; first_ib="${current_inbounds%%,*}"
    local json; json=$(_3xui_get_inbounds "$cookie")
    local uuid
    uuid=$(python3 -c "
import json
d=json.loads('''${json}''')
for ib in d.get('obj',[]):
    if str(ib['id'])=='${first_ib}':
        try:
            s=json.loads(ib.get('settings','{}'))
            for c in s.get('clients',[]):
                if c.get('email')=='${email}':
                    print(c.get('id',''))
                    break
        except: pass
" 2>/dev/null)

    # Показываем inbound'ы которых ещё нет
    local -a available=()
    local _sf2; _sf2=$(mktemp)
    _3xui_select_inbounds "$cookie" > "$_sf2" 2>/dev/null
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        local ib_id="${line%%|*}"
        [[ ",$current_inbounds," == *",$ib_id,"* ]] && continue
        available+=("$line")
    done < "$_sf2"
    rm -f "$_sf2"

    if [ ${#available[@]} -eq 0 ]; then
        echo -e "  ${YELLOW}Клиент уже во всех доступных inbound'ах${NC}"
        read -p "  Enter..."; return
    fi

    local i=1
    for ib in "${available[@]}"; do
        IFS='|' read -r ib_id ib_name ib_proto ib_port <<< "$ib"
        echo -e "  ${YELLOW}[$i]${NC}  ${ib_name} (${ib_proto}:${ib_port})"
        (( i++ ))
    done
    echo -e "  ${GREEN}[a]${NC}  Все сразу"
    echo ""
    echo -ne "  Выбор: "; read -r sel

    local selected_ids=()
    if [[ "$sel" == "a" || "$sel" == "A" ]]; then
        for ib in "${available[@]}"; do selected_ids+=("${ib%%|*}"); done
    else
        for num in $sel; do
            [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#available[@]} )) && \
                selected_ids+=("${available[$((num-1))]%%|*}")
        done
    fi

    [ ${#selected_ids[@]} -eq 0 ] && { read -p "  Enter..."; return; }

    echo ""
    for ib_id in "${selected_ids[@]}"; do
        local ib_name; ib_name=$(_3xui_inbound_name "$ib_id" "$cookie")
        echo -ne "  ${CYAN}→ Добавляю в ${ib_name}...${NC} "
        local res; res=$(_3xui_add_client_to_inbound "$ib_id" "$email" "$uuid" "$sub_id" "$cookie")
        echo "$res" | grep -q '"success":true' && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    done
    log_action "3XUI: ${email} добавлен в inbound'ы: ${selected_ids[*]}"
    read -p "  Enter..."
}

# Удалить inbound из клиента
_3xui_del_inbound_from_client() {
    local email="$1" current_inbounds="$2" cookie="$3"
    clear
    echo -e "\n${CYAN}━━━ Удалить протокол: ${email} ━━━${NC}\n"

    IFS=',' read -ra ib_arr <<< "$current_inbounds"
    if [ ${#ib_arr[@]} -le 1 ]; then
        echo -e "  ${YELLOW}Только один протокол. Используйте 'Удалить клиента' для полного удаления.${NC}"
        read -p "  Enter..."; return
    fi

    local i=1
    for ib_id in "${ib_arr[@]}"; do
        local ib_name; ib_name=$(_3xui_inbound_name "$ib_id" "$cookie")
        echo -e "  ${YELLOW}[$i]${NC}  ${ib_name} (id=${ib_id})"
        (( i++ ))
    done
    echo ""
    echo -ne "  Какой удалить (номер): "; read -r num
    [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#ib_arr[@]} )) || { read -p "  Enter..."; return; }

    local target_ib="${ib_arr[$((num-1))]}"
    local ib_name; ib_name=$(_3xui_inbound_name "$target_ib" "$cookie")
    echo -ne "  ${RED}Удалить ${email} из ${ib_name}? (y/n): ${NC}"; read -r c
    [[ "$c" != "y" ]] && return

    local res; res=$(_3xui_del_client_from_inbound "$target_ib" "$email" "$cookie")
    echo "$res" | grep -q '"success":true' && \
        echo -e "  ${GREEN}✓ Удалён из ${ib_name}${NC}" || \
        echo -e "  ${RED}✗ Ошибка${NC}"
    log_action "3XUI: ${email} удалён из inbound ${target_ib}"
    read -p "  Enter..."
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
    echo -e "  ${CYAN}3.${NC} Routing → Добавить правило:"
    echo -e '     { "outboundTag": "WARP", "domain": ["geosite:geolocation-!cn"] }'
    echo -e "  ${CYAN}4.${NC} Сохранить → Перезапустить Xray\n"

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
        is_3xui && echo -e "  ${CYAN}[i]${NC}  Инструкция — как подключить трафик через WARP в 3X-UI"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        read -p "Выбор: " warp_action
        case "$warp_action" in
            1) warp_test; return ;;
            i|I) is_3xui && { _3xui_warp_instruction; return; } ;;
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
        echo -e "\n${CYAN}━━━ Установка сервера ━━━${NC}\n"

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
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")

        case "$ch" in
            1) _install_amnezia_awg ;;
            2) _install_3xui ;;
            0|"") return ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════
#  3X-UI — УПРАВЛЕНИЕ КЛИЕНТАМИ ЧЕРЕЗ API
# ═══════════════════════════════════════════════════════════════

# Конфиг API для текущего сервера
XUI_API_HOST="127.0.0.1"
XUI_COOKIE_FILE="/tmp/govpn_xui_session.txt"
XUI_HEADERS_FILE="/tmp/govpn_xui_headers.txt"

# Inbound'ы которые используем (WS=2 исключён)
# id|название|тип
XUI_INBOUNDS_USABLE="1:TCP:vless 3:TCP2:vless 4:gRPC:trojan 5:xHTTP:vless"

# Читает параметры панели из x-ui.db
_xui_read_config() {
    if [ ! -f /etc/x-ui/x-ui.db ]; then
        echo ""; return 1
    fi
    XUI_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null || echo "17331")
    XUI_BASEPATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null || echo "/")
    XUI_USER=$(sqlite3 /etc/x-ui/x-ui.db "SELECT username FROM users LIMIT 1;" 2>/dev/null || echo "")
    XUI_PASS_HASH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT password FROM users LIMIT 1;" 2>/dev/null || echo "")
    XUI_SUB_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subPort';" 2>/dev/null || echo "15903")
    XUI_SUB_PATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subPath';" 2>/dev/null || echo "")
    XUI_SUB_DOMAIN=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='subDomain';" 2>/dev/null || echo "")
    # Убираем слэши из basepath для URL
    XUI_BASEPATH="${XUI_BASEPATH%/}"
}

# Запрашивает пароль у пользователя и логинится
_xui_login() {
    _xui_read_config || return 1

    echo -ne "  ${CYAN}→ Пароль от панели x-ui: ${NC}"
    read -rs XUI_PASS_INPUT
    echo ""

    local login_url="https://${XUI_API_HOST}:${XUI_PORT}${XUI_BASEPATH}/login"
    curl -sk -X POST "$login_url" \
        -H 'Content-Type: application/json' \
        -d "{\"username\":\"${XUI_USER}\",\"password\":\"${XUI_PASS_INPUT}\"}" \
        -D "$XUI_HEADERS_FILE" > /dev/null 2>&1

    local cookie
    cookie=$(grep -ioP '3x-ui=\S+(?=;)' "$XUI_HEADERS_FILE" 2>/dev/null)
    if [ -z "$cookie" ]; then
        echo -e "  ${RED}✗ Авторизация не удалась${NC}"
        return 1
    fi
    echo "$cookie" > "$XUI_COOKIE_FILE"
    echo -e "  ${GREEN}✓ Авторизован${NC}"
    return 0
}

# Выполняет API запрос (с автоповтором при устаревшей сессии)
_xui_api() {
    local method="$1" path="$2" data="$3"
    [ ! -f "$XUI_COOKIE_FILE" ] && { echo "NO_SESSION"; return 1; }
    local cookie; cookie=$(cat "$XUI_COOKIE_FILE")
    local url="https://${XUI_API_HOST}:${XUI_PORT}${XUI_BASEPATH}${path}"
    local result
    if [ "$method" = "GET" ]; then
        result=$(curl -sk -H "Cookie: $cookie" "$url" 2>/dev/null)
    else
        result=$(curl -sk -X POST -H "Cookie: $cookie" -H 'Content-Type: application/json' \
            -d "$data" "$url" 2>/dev/null)
    fi
    # Проверяем успех
    local success; success=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
    if [ "$success" != "True" ] && [ "$success" != "true" ]; then
        local msg; msg=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('msg',''))" 2>/dev/null)
        if echo "$msg" | grep -qi 'login\|auth\|session\|unauthorized'; then
            echo "SESSION_EXPIRED"
        else
            echo "ERROR:${msg}"
        fi
        return 1
    fi
    echo "$result"
    return 0
}

# Получает список клиентов (все inbound'ы, дедупликация по subId)
_xui_get_clients() {
    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    [ "$resp" = "SESSION_EXPIRED" ] && { echo "SESSION_EXPIRED"; return 1; }
    [ -z "$resp" ] && { echo "ERROR:empty"; return 1; }

    python3 - "$resp" << 'PYEOF'
import json, sys, re

try:
    data = json.loads(sys.argv[1])
    inbounds = data.get('obj', [])
    
    # Собираем уникальных клиентов по subId
    clients = {}  # subId -> {email, subId, inbounds: [id,...], total, up, down, expiry}
    
    for ib in inbounds:
        ib_id = ib.get('id')
        ib_remark = ib.get('remark', '').strip()
        ib_protocol = ib.get('protocol', '')
        
        # Пропускаем WS (id=2) и Socks5 (id=6)
        if ib_id in [2, 6]:
            continue
        
        # Парсим клиентов из settings JSON
        try:
            settings = json.loads(ib.get('settings', '{}'))
        except:
            continue
        
        for c in settings.get('clients', []):
            sub_id = c.get('subId', '')
            email = c.get('email', '')
            key = sub_id if sub_id else email
            
            if key not in clients:
                clients[key] = {
                    'email': email,
                    'subId': sub_id,
                    'enable': c.get('enable', True),
                    'totalGB': c.get('totalGB', 0),
                    'expiryTime': c.get('expiryTime', 0),
                    'inbounds': [],
                    'up': 0, 'down': 0
                }
            
            clients[key]['inbounds'].append({
                'id': ib_id,
                'remark': ib_remark,
                'protocol': ib_protocol,
                'clientId': c.get('id', ''),
                'flow': c.get('flow', '')
            })
        
        # Собираем статистику трафика
        try:
            stats_resp = data  # трафик будет отдельным запросом
        except:
            pass
    
    # Выводим в формате для парсинга
    for key, c in clients.items():
        ib_ids = ','.join(str(i['id']) for i in c['inbounds'])
        ib_names = ','.join(i['remark'][:8] for i in c['inbounds'])
        print(f"{c['subId']}|{c['email']}|{ib_ids}|{ib_names}|{c['enable']}|{c['totalGB']}|{c['expiryTime']}")

except Exception as e:
    print(f"ERR:{e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Генерирует subId
_xui_gen_subid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16 || \
    date +%s%N | md5sum | cut -c 1-16
}

# Генерирует UUID v4
_xui_gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
    python3 -c "import uuid; print(str(uuid.uuid4()))"
}

# Генерирует пароль для trojan
_xui_gen_pass() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

# Добавляет клиента в один inbound
_xui_add_to_inbound() {
    local ib_id="$1" email="$2" sub_id="$3" client_uuid="$4" client_pass="$5"
    
    # Получаем тип протокола для этого inbound
    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    local protocol
    protocol=$(echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('obj',[]):
    if i['id']==${ib_id}: print(i['protocol']); break
" 2>/dev/null)

    # Формируем клиента в зависимости от протокола
    local client_json
    if [ "$protocol" = "trojan" ]; then
        client_json=$(python3 -c "
import json
c = {
    'password': '${client_pass}',
    'email': '${email}',
    'enable': True,
    'subId': '${sub_id}',
    'tgId': '',
    'limitIp': 0,
    'totalGB': 0,
    'expiryTime': 0,
    'reset': 0,
    'comment': ''
}
print(json.dumps(c))
")
    else
        client_json=$(python3 -c "
import json
c = {
    'id': '${client_uuid}',
    'flow': 'xtls-rprx-vision',
    'email': '${email}',
    'enable': True,
    'subId': '${sub_id}',
    'tgId': '',
    'limitIp': 0,
    'totalGB': 0,
    'expiryTime': 0,
    'reset': 0,
    'comment': ''
}
print(json.dumps(c))
")
    fi

    local payload; payload=$(python3 -c "
import json
print(json.dumps({'id': ${ib_id}, 'settings': json.dumps({'clients': [${client_json}]})}))
")
    local result; result=$(_xui_api POST "/panel/api/inbounds/addClient" "$payload")
    echo "$result"
}

# Удаляет клиента из inbound по email
_xui_del_from_inbound() {
    local ib_id="$1" client_uuid="$2"
    local payload="{\"id\":${ib_id}}"
    local result; result=$(_xui_api POST "/panel/api/inbounds/${ib_id}/delClient/${client_uuid}" "")
    echo "$result"
}

# Генерирует ссылку подписки
_xui_sub_url() {
    local sub_id="$1"
    _xui_read_config
    if [ -n "$XUI_SUB_DOMAIN" ]; then
        echo "https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}${sub_id}"
    else
        echo "https://${MY_IP}:${XUI_SUB_PORT}${XUI_SUB_PATH}${sub_id}"
    fi
}

# Показывает QR-код подписки
_xui_show_qr() {
    local sub_id="$1" email="$2"
    local url; url=$(_xui_sub_url "$sub_id")
    echo ""
    echo -e "  ${WHITE}Клиент:${NC} ${CYAN}${email}${NC}"
    echo -e "  ${WHITE}Подписка:${NC} ${CYAN}${url}${NC}"
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$url"
    else
        echo -e "  ${YELLOW}qrencode не установлен (apt-get install -y qrencode)${NC}"
    fi
}

# Меню выбора inbound'ов
_xui_select_inbounds() {
    local prompt="$1"  # "add" or "del"
    local inbound_data="$2"  # текущие inbound'ы клиента (через запятую id)
    
    echo ""
    echo -e "  ${CYAN}Доступные inbound'ы:${NC}"
    echo ""
    
    # Получаем полный список
    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    local inbounds_list
    inbounds_list=$(echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d.get('obj',[]):
    if i['id'] not in [2,6]:
        print(f\"{i['id']}|{i['remark'].strip()[:20]}|{i['protocol']}|{i['port']}\")
" 2>/dev/null)

    local -a ib_array=()
    local i=1
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ib_id="${line%%|*}"
        local rest="${line#*|}"
        local ib_name="${rest%%|*}"
        rest="${rest#*|}"
        local ib_proto="${rest%%|*}"
        local ib_port="${rest##*|}"
        
        # Проверяем есть ли уже у клиента
        local has=""
        echo "$inbound_data" | grep -q "\b${ib_id}\b" && has=" ${GREEN}(есть)${NC}"
        
        echo -e "  ${YELLOW}[${i}]${NC}  id=${ib_id}  ${ib_name}  ${ib_proto}:${ib_port}${has}"
        ib_array+=("$ib_id")
        (( i++ ))
    done <<< "$inbounds_list"
    echo ""
    echo -e "  ${YELLOW}[a]${NC}  Все inbound'ы сразу"
    echo -e "  ${YELLOW}[0]${NC}  Отмена"
    echo ""
    
    read -p "  Выбор: " sel
    case "$sel" in
        a|A) echo "ALL" ;;
        0|"") echo "CANCEL" ;;
        *) 
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel < i )); then
                echo "${ib_array[$((sel-1))]}"
            else
                echo "CANCEL"
            fi
            ;;
    esac
}

# Главное меню управления клиентами 3X-UI
xui_clients_menu() {
    # Проверяем что есть x-ui
    if ! systemctl is-active x-ui &>/dev/null 2>&1; then
        echo -e "  ${RED}✗ x-ui не запущен${NC}"
        read -p "  Enter..."; return
    fi
    if [ ! -f /etc/x-ui/x-ui.db ]; then
        echo -e "  ${RED}✗ x-ui база не найдена${NC}"
        read -p "  Enter..."; return
    fi

    _xui_read_config

    # Авторизация
    local session_ok=0
    if [ -f "$XUI_COOKIE_FILE" ]; then
        # Проверяем сессию
        local test; test=$(_xui_api GET "/panel/api/inbounds/list" "")
        [[ "$test" != "SESSION_EXPIRED" && "$test" != "NO_SESSION" && "$test" != ERROR:* ]] && session_ok=1
    fi
    if [ "$session_ok" -eq 0 ]; then
        clear
        echo -e "\n${CYAN}━━━ Авторизация 3X-UI ━━━${NC}\n"
        echo -e "  ${WHITE}Панель:${NC} https://${XUI_SUB_DOMAIN:-$MY_IP}${XUI_BASEPATH}/"
        echo -e "  ${WHITE}Логин:${NC}  ${XUI_USER}\n"
        _xui_login || { read -p "  Enter..."; return; }
    fi

    while true; do
        clear
        echo -e "\n${CYAN}━━━ 3X-UI — Клиенты ━━━${NC}\n"

        # Шапка
        local sub_domain_info
        [ -n "$XUI_SUB_DOMAIN" ] && \
            sub_domain_info="${GREEN}https://${XUI_SUB_DOMAIN}${XUI_SUB_PATH}${NC}" || \
            sub_domain_info="${YELLOW}https://${MY_IP}:${XUI_SUB_PORT}${XUI_SUB_PATH}${NC}"
        echo -e "  ${WHITE}Подписки:${NC} ${sub_domain_info}"

        # Предупреждение если subDomain пустой
        if [ -z "$XUI_SUB_DOMAIN" ]; then
            echo -e "  ${YELLOW}⚠ subDomain не задан — IP виден в ссылке подписки${NC}"
            echo -e "  ${WHITE}  Исправить: govpn → [3] Клиенты 3X-UI → [f] Настроить домен подписки${NC}"
        fi
        echo ""

        # Получаем клиентов
        local clients_raw
        clients_raw=$(_xui_get_clients)
        if [ "$clients_raw" = "SESSION_EXPIRED" ]; then
            echo -e "  ${YELLOW}Сессия истекла, переавторизация...${NC}"
            _xui_login || { read -p "  Enter..."; return; }
            clients_raw=$(_xui_get_clients)
        fi

        # Парсим и показываем список
        local -a client_lines=()
        local idx=1
        while IFS= read -r line; do
            [ -z "$line" ] || [[ "$line" == ERR:* ]] && continue
            local sub_id="${line%%|*}"
            local rest="${line#*|}"
            local email="${rest%%|*}"
            rest="${rest#*|}"
            local ib_ids="${rest%%|*}"
            rest="${rest#*|}"
            local ib_names="${rest%%|*}"
            rest="${rest#*|}"
            local enabled="${rest%%|*}"

            local status_icon
            [[ "$enabled" == "True" || "$enabled" == "true" ]] && \
                status_icon="${GREEN}●${NC}" || status_icon="${RED}●${NC}"

            printf "  ${YELLOW}[%2d]${NC}  %b  ${WHITE}%-20s${NC}  ${CYAN}%-30s${NC}  %s\n" \
                "$idx" "$status_icon" "$email" "$ib_names" "${sub_id:0:8}..."
            client_lines+=("$line")
            (( idx++ ))
        done <<< "$clients_raw"

        echo ""
        echo -e "  ${GREEN}[n]${NC}  Новый клиент"
        echo -e "  ${YELLOW}[f]${NC}  Настроить домен подписки"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор (номер клиента или команда): ")

        case "$ch" in
            n|N|т|Т)
                _xui_new_client_wizard
                ;;
            f|F|а|А)
                _xui_fix_subdomain
                ;;
            0|"") return ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && (( ch >= 1 && ch <= ${#client_lines[@]} )); then
                    _xui_client_profile "${client_lines[$((ch-1))]}"
                fi
                ;;
        esac
    done
}

# Профиль клиента
_xui_client_profile() {
    local line="$1"
    local sub_id="${line%%|*}"
    local rest="${line#*|}"
    local email="${rest%%|*}"
    rest="${rest#*|}"
    local ib_ids="${rest%%|*}"
    rest="${rest#*|}"
    local ib_names="${rest%%|*}"
    rest="${rest#*|}"
    local enabled="${rest%%|*}"
    rest="${rest#*|}"
    local total_gb="${rest%%|*}"

    while true; do
        clear
        echo -e "\n${CYAN}━━━ Клиент: ${email} ━━━${NC}\n"
        local status
        [[ "$enabled" == "True" || "$enabled" == "true" ]] && \
            status="${GREEN}● активен${NC}" || status="${RED}● отключён${NC}"
        echo -e "  ${WHITE}Статус:${NC}   ${status}"
        echo -e "  ${WHITE}subId:${NC}    ${CYAN}${sub_id}${NC}"
        echo -e "  ${WHITE}Inbound'ы:${NC} ${ib_names}"
        echo -e "  ${WHITE}Лимит:${NC}    $([ "$total_gb" = "0" ] && echo "${GREEN}∞${NC}" || echo "${YELLOW}${total_gb} GB${NC}")"
        local sub_url; sub_url=$(_xui_sub_url "$sub_id")
        echo -e "  ${WHITE}Подписка:${NC} ${CYAN}${sub_url}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC}  QR-код подписки"
        echo -e "  ${GREEN}[2]${NC}  Добавить inbound"
        echo -e "  ${RED}[3]${NC}  Удалить из inbound'а"
        echo -e "  ${RED}[4]${NC}  Удалить клиента полностью"
        echo -e "  ${YELLOW}[0]${NC}  Назад"
        echo ""
        local ch; ch=$(read_choice "Выбор: ")
        case "$ch" in
            1)
                _xui_show_qr "$sub_id" "$email"
                read -p "  Enter..."
                ;;
            2)
                _xui_add_inbound_to_client "$sub_id" "$email" "$ib_ids"
                # Обновляем данные
                return
                ;;
            3)
                _xui_remove_inbound_from_client "$sub_id" "$email" "$ib_ids"
                return
                ;;
            4)
                echo -ne "\n  ${RED}Удалить ${email} из всех inbound'ов? (y/n): ${NC}"
                read -r c
                [[ "$c" != "y" ]] && continue
                _xui_delete_client_all "$sub_id" "$email" "$ib_ids"
                read -p "  Enter..."
                return
                ;;
            0|"") return ;;
        esac
    done
}

# Мастер создания нового клиента
_xui_new_client_wizard() {
    clear
    echo -e "\n${CYAN}━━━ Новый клиент 3X-UI ━━━${NC}\n"

    # Имя
    echo -ne "  Имя клиента (email): "; read -r new_email
    [ -z "$new_email" ] && return

    # Генерируем ID
    local new_sub_id; new_sub_id=$(_xui_gen_subid)
    local new_uuid; new_uuid=$(_xui_gen_uuid)
    local new_pass; new_pass=$(_xui_gen_pass)

    echo -e "\n  ${WHITE}subId:${NC} ${CYAN}${new_sub_id}${NC}"
    echo -e "  ${WHITE}UUID:${NC}  ${CYAN}${new_uuid}${NC}\n"

    # Выбор inbound'ов
    local sel; sel=$(_xui_select_inbounds "add" "")
    [ "$sel" = "CANCEL" ] && return

    local -a target_ids=()
    if [ "$sel" = "ALL" ]; then
        # Все inbound'ы (1,3,4,5)
        target_ids=(1 3 4 5)
    else
        target_ids=("$sel")
    fi

    echo ""
    local success_count=0 fail_count=0
    for ib_id in "${target_ids[@]}"; do
        echo -ne "  ${CYAN}→ inbound ${ib_id}...${NC} "
        local result; result=$(_xui_add_to_inbound "$ib_id" "$new_email" "$new_sub_id" "$new_uuid" "$new_pass")
        local ok; ok=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
        if [[ "$ok" == "True" || "$ok" == "true" ]]; then
            echo -e "${GREEN}✓${NC}"
            (( success_count++ ))
        else
            local msg; msg=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('msg',''))" 2>/dev/null)
            echo -e "${RED}✗ ${msg}${NC}"
            (( fail_count++ ))
        fi
    done

    if [ "$success_count" -gt 0 ]; then
        echo -e "\n  ${GREEN}✓ Клиент ${new_email} создан в ${success_count} inbound'ах${NC}"
        local sub_url; sub_url=$(_xui_sub_url "$new_sub_id")
        echo -e "  ${WHITE}Подписка:${NC} ${CYAN}${sub_url}${NC}"
        echo ""
        command -v qrencode &>/dev/null && qrencode -t ANSIUTF8 "$sub_url"
        log_action "XUI: добавлен клиент ${new_email} subId=${new_sub_id}"
    fi
    read -p "  Enter..."
}

# Добавляет inbound к существующему клиенту
_xui_add_inbound_to_client() {
    local sub_id="$1" email="$2" current_ibs="$3"
    clear
    echo -e "\n${CYAN}━━━ Добавить inbound → ${email} ━━━${NC}\n"

    local sel; sel=$(_xui_select_inbounds "add" "$current_ibs")
    [ "$sel" = "CANCEL" ] && return

    # Нужны UUID/pass клиента — берём из первого inbound'а
    local first_ib; first_ib=$(echo "$current_ibs" | cut -d, -f1)
    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    local client_data
    client_data=$(echo "$resp" | python3 - "$first_ib" "$email" << 'PYEOF'
import json,sys
ib_id, email = int(sys.argv[1]), sys.argv[2]
d = json.loads(sys.argv[3]) if len(sys.argv)>3 else json.load(sys.stdin)
PYEOF
)
    # Упрощённо — генерируем новые (клиент будет в подписке через subId)
    local new_uuid; new_uuid=$(_xui_gen_uuid)
    local new_pass; new_pass=$(_xui_gen_pass)

    local -a target_ids=()
    [ "$sel" = "ALL" ] && target_ids=(1 3 4 5) || target_ids=("$sel")

    for ib_id in "${target_ids[@]}"; do
        # Пропускаем если уже есть
        echo "$current_ibs" | grep -q "\b${ib_id}\b" && \
            { echo -e "  ${YELLOW}inbound ${ib_id} — уже добавлен${NC}"; continue; }
        echo -ne "  ${CYAN}→ inbound ${ib_id}...${NC} "
        local result; result=$(_xui_add_to_inbound "$ib_id" "$email" "$sub_id" "$new_uuid" "$new_pass")
        local ok; ok=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
        [[ "$ok" == "True" || "$ok" == "true" ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    done
    log_action "XUI: клиент ${email} — добавлен inbound"
    read -p "  Enter..."
}

# Удаляет клиента из конкретного inbound'а
_xui_remove_inbound_from_client() {
    local sub_id="$1" email="$2" current_ibs="$3"
    clear
    echo -e "\n${CYAN}━━━ Удалить из inbound → ${email} ━━━${NC}\n"

    local sel; sel=$(_xui_select_inbounds "del" "$current_ibs")
    [ "$sel" = "CANCEL" ] && return

    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    local -a target_ids=()
    [ "$sel" = "ALL" ] && {
        IFS=',' read -ra target_ids <<< "$current_ibs"
    } || target_ids=("$sel")

    for ib_id in "${target_ids[@]}"; do
        echo -ne "  ${CYAN}→ Удаление из inbound ${ib_id}...${NC} "
        # Находим clientId (UUID) клиента в этом inbound
        local client_id
        client_id=$(echo "$resp" | python3 - "$ib_id" "$email" << 'PYEOF'
import json,sys
d=json.load(sys.stdin)
ib_id,email=int(sys.argv[1]),sys.argv[2]
for ib in d.get('obj',[]):
    if ib['id']==ib_id:
        s=json.loads(ib.get('settings','{}'))
        for c in s.get('clients',[]):
            if c.get('email')==email:
                print(c.get('id') or c.get('password',''))
                break
PYEOF
)
        if [ -z "$client_id" ]; then
            echo -e "${YELLOW}не найден${NC}"
            continue
        fi
        local result; result=$(_xui_api POST "/panel/api/inbounds/${ib_id}/delClient/${client_id}" "")
        local ok; ok=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
        [[ "$ok" == "True" || "$ok" == "true" ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    done
    log_action "XUI: клиент ${email} — удалён из inbound"
    read -p "  Enter..."
}

# Удаляет клиента из всех inbound'ов
_xui_delete_client_all() {
    local sub_id="$1" email="$2" ib_ids_str="$3"
    local resp; resp=$(_xui_api GET "/panel/api/inbounds/list" "")
    IFS=',' read -ra ib_ids <<< "$ib_ids_str"

    for ib_id in "${ib_ids[@]}"; do
        echo -ne "  ${CYAN}→ inbound ${ib_id}...${NC} "
        local client_id
        client_id=$(echo "$resp" | python3 - "$ib_id" "$email" << 'PYEOF'
import json,sys
d=json.load(sys.stdin)
ib_id,email=int(sys.argv[1]),sys.argv[2]
for ib in d.get('obj',[]):
    if ib['id']==ib_id:
        s=json.loads(ib.get('settings','{}'))
        for c in s.get('clients',[]):
            if c.get('email')==email:
                print(c.get('id') or c.get('password',''))
                break
PYEOF
)
        if [ -z "$client_id" ]; then
            echo -e "${YELLOW}не найден${NC}"; continue
        fi
        local result; result=$(_xui_api POST "/panel/api/inbounds/${ib_id}/delClient/${client_id}" "")
        local ok; ok=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
        [[ "$ok" == "True" || "$ok" == "true" ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}"
    done
    log_action "XUI: удалён клиент ${email} полностью"
}

# Исправляет subDomain в x-ui.db
_xui_fix_subdomain() {
    clear
    echo -e "\n${CYAN}━━━ Домен подписки ━━━${NC}\n"
    _xui_read_config

    echo -e "  ${WHITE}Текущий subDomain:${NC} ${CYAN}${XUI_SUB_DOMAIN:-не задан}${NC}"
    echo -e "  ${WHITE}Текущий subPath:${NC}   ${CYAN}${XUI_SUB_PATH}${NC}"
    echo -e "  ${WHITE}Текущий subPort:${NC}   ${CYAN}${XUI_SUB_PORT}${NC}"
    echo ""
    echo -e "  ${WHITE}Пример подписки сейчас:${NC}"
    echo -e "  ${CYAN}$(_xui_sub_url 'SUBID_КЛИЕНТА')${NC}"
    echo ""

    echo -ne "  Новый домен подписки (Enter = оставить): "
    read -r new_domain
    [ -z "$new_domain" ] && { read -p "  Enter..."; return; }

    echo -ne "  ${YELLOW}Внимание! Клиенты с доменом в подписке обновятся автоматически.${NC}"
    echo -ne "\n  Продолжить? (y/n): "; read -r c
    [[ "$c" != "y" ]] && return

    sqlite3 /etc/x-ui/x-ui.db \
        "INSERT OR REPLACE INTO settings (key, value) VALUES ('subDomain', '${new_domain}');" \
        2>/dev/null && \
        echo -e "  ${GREEN}✓ subDomain обновлён: ${new_domain}${NC}" || \
        echo -e "  ${RED}✗ Ошибка записи в БД${NC}"

    systemctl restart x-ui > /dev/null 2>&1
    sleep 2
    echo -e "  ${GREEN}✓ x-ui перезапущен${NC}"
    log_action "XUI: subDomain установлен: ${new_domain}"
    read -p "  Enter..."
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
                read -r domain
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
        echo -e "  ${YELLOW}[9]${NC}  Установить сервер"
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
                read -r ch2
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
        read -r ans
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
        read -r ans
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
        fi
        echo -e " ${CYAN}── ПРОКСИ ────────────────────────────${NC}"
        echo -e "  5)  MTProto прокси"
        echo -e "  6)  iptables проброс"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e "  7)  Серверы, скорость, тесты"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e "  8)  Система и управление"
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
            3) is_3xui && _3xui_clients_menu ;;
            4) is_amnezia && awg_peers_menu ;;
            5) mtproto_menu ;;
            6) iptables_menu ;;
            7) tools_menu ;;
            8) system_menu ;;
            # h|H|р|Р) is_hysteria2 && hysteria2_menu ;;
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
