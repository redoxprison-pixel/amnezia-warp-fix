#!/bin/bash
set -o pipefail

# ══════════════════════════════════════════════════════════════
#  GoVPN Manager v1.0
#  WARP · iptables cascade · 3x-ui/x-ui-pro · AmneziaWG
#  Безопасная установка: бэкап → патч → валидация → rollback
# ══════════════════════════════════════════════════════════════

VERSION="1.7"
GOVPN_REPO_URL="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main/govpn.sh"
SCRIPT_NAME="govpn"
INSTALL_PATH="/usr/local/bin/${SCRIPT_NAME}"
CONF_DIR="/etc/${SCRIPT_NAME}"
CONF_FILE="${CONF_DIR}/config"
ALIASES_FILE="${CONF_DIR}/aliases"
BACKUP_DIR="${CONF_DIR}/backups"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
MONITOR_DIR="${CONF_DIR}/monitors"
BOT_PID_FILE="/var/run/${SCRIPT_NAME}_bot.pid"
MONITOR_PID_FILE="/var/run/${SCRIPT_NAME}_monitor.pid"

DEFAULT_WARP_PORT=40000
WARP_SOCKS_PORT=""
MY_IP=""
IFACE=""
BOT_TOKEN=""
BOT_CHAT_ID=""

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'; WHITE='\033[1;37m'
BLUE='\033[0;34m'; NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
#  LOGGING
# ═══════════════════════════════════════════════════════════════

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════════════════════════

init_config() {
    mkdir -p "$CONF_DIR" "$BACKUP_DIR" "$MONITOR_DIR"
    touch "$ALIASES_FILE"
    if [ ! -f "$CONF_FILE" ]; then
        cat > "$CONF_FILE" <<'CONF'
WARP_SOCKS_PORT="40000"
BOT_TOKEN=""
BOT_CHAT_ID=""
CONF
    fi
    source "$CONF_FILE"
    WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-$DEFAULT_WARP_PORT}"
}

save_config_val() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONF_FILE"
    else
        echo "${key}=\"${value}\"" >> "$CONF_FILE"
    fi
    source "$CONF_FILE"
}

# ═══════════════════════════════════════════════════════════════
#  SYSTEM CHECKS
# ═══════════════════════════════════════════════════════════════

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"; exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="${VERSION_ID:-}"
        OS_CODENAME="${VERSION_CODENAME:-}"
    else
        OS_ID="unknown"
        OS_VERSION=""
        OS_CODENAME=""
    fi
}

detect_interface() {
    IFACE=$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
    if [ -z "$IFACE" ]; then
        echo -e "${RED}[ERROR] Не удалось определить сетевой интерфейс!${NC}"
        exit 1
    fi
}

get_my_ip() {
    local ip=""
    local services=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    for svc in "${services[@]}"; do
        ip=$(curl -s4 --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        # Проверяем что получили именно IP, а не HTML/ошибку
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            MY_IP="$ip"
            return
        fi
    done
    # Fallback: получить IP с сетевого интерфейса
    MY_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' | head -1 || echo "N/A")
}

check_deps() {
    local missing=()
    for cmd in jq curl python3 iptables; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    dpkg -s iptables-persistent &>/dev/null 2>&1 || missing+=("iptables-persistent")

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}[*] Установка зависимостей: ${missing[*]}${NC}"
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get &>/dev/null; then
            apt-get update -y > /dev/null 2>&1
            apt-get install -y jq curl python3 iptables iptables-persistent \
                netfilter-persistent procps > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y jq curl python3 iptables-services procps-ng > /dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y jq curl python3 iptables-services procps-ng > /dev/null 2>&1
        else
            echo -e "${RED}[ERROR] Неподдерживаемый пакетный менеджер!${NC}"; exit 1
        fi
    fi
}

prepare_system() {
    # BBR + ip_forward (идемпотентно)
    if grep -qE '^[[:space:]]*#?[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^#*\s*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null || \
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
}

save_iptables() {
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save > /dev/null 2>&1
    elif command -v service &>/dev/null && service iptables status &>/dev/null 2>&1; then
        service iptables save > /dev/null 2>&1
    fi
}

# ═══════════════════════════════════════════════════════════════
#  CONFLICT CHECK
# ═══════════════════════════════════════════════════════════════

check_conflicts() {
    clear
    echo -e "\n${CYAN}━━━ Проверка конфликтов ━━━${NC}\n"
    local has_blocker=0

    # 1. Другие WARP реализации
    local warp_blockers=("warp-go" "amnezia-warp" "wireproxy")
    local warp_info=("wgcf")   # только генератор конфигов, не демон
    for v in "${warp_blockers[@]}"; do
        if command -v "$v" &>/dev/null || systemctl is-active "$v" &>/dev/null 2>&1; then
            echo -e "  ${RED}[BLOCKER]${NC} Найден конфликтующий сервис: ${WHITE}${v}${NC}"
            has_blocker=1
        else
            echo -e "  ${GREEN}[✓]${NC} ${v} — не установлен"
        fi
    done
    for v in "${warp_info[@]}"; do
        if command -v "$v" &>/dev/null; then
            echo -e "  ${CYAN}[INFO]${NC} ${v} — установлен (CLI утилита, не конфликтует с warp-cli)"
        else
            echo -e "  ${GREEN}[✓]${NC} ${v} — не установлен"
        fi
    done

    # 2. WireGuard интерфейсы (WARP использует WireGuard)
    local wg_ifaces
    wg_ifaces=$(ip link show 2>/dev/null | grep -E "warp[0-9]|^[0-9]+: wg[0-9]" | awk -F': ' '{print $2}')
    if [ -n "$wg_ifaces" ]; then
        echo -e "  ${YELLOW}[WARN]${NC} Активные WireGuard интерфейсы: ${WHITE}${wg_ifaces}${NC}"
        echo -e "         Может конфликтовать с WARP"
    else
        echo -e "  ${GREEN}[✓]${NC} WireGuard интерфейсы — не найдены"
    fi

    # 3. Порт WARP занят
    if ss -tlnp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT} "; then
        local occupant
        occupant=$(ss -tlnp 2>/dev/null | grep ":${WARP_SOCKS_PORT} " | \
            sed 's/.*users:(("//' | cut -d'"' -f1)
        if [ "$occupant" = "warp-svc" ]; then
            echo -e "  ${GREEN}[✓]${NC} Порт ${WARP_SOCKS_PORT} — занят warp-svc (это нормально, WARP уже работает)"
        else
            echo -e "  ${RED}[BLOCKER]${NC} Порт ${WARP_SOCKS_PORT} занят другим процессом: ${WHITE}${occupant}${NC}"
            echo -e "         Измените порт WARP (п.13) или остановите ${occupant}."
            has_blocker=1
        fi
    else
        echo -e "  ${GREEN}[✓]${NC} Порт ${WARP_SOCKS_PORT} — свободен"
    fi

    # 4. Старая версия этого скрипта
    if [ -f "$INSTALL_PATH" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
        local old_ver
        old_ver=$(grep '^VERSION=' "$INSTALL_PATH" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ -n "$old_ver" ] && [ "$old_ver" != "$VERSION" ]; then
            echo -e "  ${YELLOW}[WARN]${NC} Найдена другая версия ${SCRIPT_NAME}: ${WHITE}v${old_ver}${NC} (текущая: v${VERSION})"
            echo -e "         Путь: ${WHITE}${INSTALL_PATH}${NC}"
            echo -e "         Запустите скрипт — он обновится автоматически."
        elif [ -n "$old_ver" ] && [ "$old_ver" = "$VERSION" ]; then
            echo -e "  ${GREEN}[✓]${NC} Версия ${SCRIPT_NAME} совпадает: v${VERSION}"
        else
            echo -e "  ${CYAN}[INFO]${NC} ${INSTALL_PATH} существует (версия не определена)"
        fi
    else
        echo -e "  ${GREEN}[✓]${NC} Команда ${SCRIPT_NAME} — актуальная версия v${VERSION}"
    fi

    # 5. Orphan warp outbound в xray config
    local xray_cfg
    xray_cfg=$(detect_xray_config 2>/dev/null)
    if [ -n "$xray_cfg" ]; then
        local warp_count
        warp_count=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('${xray_cfg}'))
    outs = [o for o in cfg.get('outbounds',[]) if o.get('tag')=='warp']
    print(len(outs))
except: print(0)
" 2>/dev/null)
        if [ "${warp_count:-0}" -gt 0 ] && ! is_warp_running; then
            echo -e "  ${YELLOW}[WARN]${NC} Найден orphan outbound 'warp' в xray config"
            echo -e "         WARP не запущен — трафик уходит в никуда"
            echo -e "         Файл: ${WHITE}${xray_cfg}${NC}"
        elif [ "${warp_count:-0}" -gt 0 ] && is_warp_running; then
            echo -e "  ${GREEN}[✓]${NC} outbound 'warp' в xray config — WARP запущен, OK"
        else
            echo -e "  ${GREEN}[✓]${NC} Orphan warp outbound — не найден"
        fi
    fi

    # 6. Amnezia Docker контейнеры
    if command -v docker &>/dev/null; then
        local amn_containers
        amn_containers=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -i "amnezia")
        if [ -n "$amn_containers" ]; then
            echo ""
            echo -e "  ${CYAN}[INFO]${NC} Обнаружены контейнеры Amnezia:"
            while IFS=$'\t' read -r name ports; do
                echo -e "         ${WHITE}${name}${NC}  ${CYAN}${ports}${NC}"
            done <<< "$amn_containers"
            echo ""
            # Проверяем конкретные конфликты портов с WARP
            # amnezia-xray на 443 — не конфликтует с WARP SOCKS5
            # amnezia-awg на UDP — не конфликтует
            # amnezia-socks5proxy — проверим порт
            local amn_socks_port
            amn_socks_port=$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | \
                grep "amnezia-socks5proxy" | grep -oE '0\.0\.0\.0:[0-9]+->' | \
                grep -oE '[0-9]+' | tail -1)
            if [ -n "$amn_socks_port" ] && [ "$amn_socks_port" = "$WARP_SOCKS_PORT" ]; then
                echo -e "  ${RED}[BLOCKER]${NC} amnezia-socks5proxy занимает порт ${WARP_SOCKS_PORT}"
                echo -e "         Измените WARP_SOCKS_PORT (п.13) на другой порт."
                has_blocker=1
            else
                echo -e "  ${GREEN}[✓]${NC} Конфликтов портов с Amnezia — нет"
                echo -e "         ${WHITE}Примечание:${NC} amnezia-xray на :443 и WARP SOCKS5 на"
                echo -e "         ${WHITE}127.0.0.1:${WARP_SOCKS_PORT} работают независимо друг от друга.${NC}"
            fi
            # Проверяем amn0 интерфейс
            if ip link show amn0 &>/dev/null 2>&1; then
                echo -e "  ${GREEN}[✓]${NC} Интерфейс amn0 (Amnezia) и warp0 (WARP) не конфликтуют"
            fi
        else
            echo -e "  ${GREEN}[✓]${NC} Контейнеры Amnezia — не найдены"
        fi
    fi

    echo ""
    if [ "$has_blocker" -eq 1 ]; then
        echo -e "${RED}[!] Обнаружены BLOCKER-конфликты. Разрешите их перед установкой WARP.${NC}"
        echo ""
        read -p "Нажмите Enter..."
        return 1
    else
        echo -e "${GREEN}[✓] Критических конфликтов не обнаружено.${NC}"
        echo ""
        read -p "Нажмите Enter..."
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════
#  XRAY CONFIG — безопасный патч
# ═══════════════════════════════════════════════════════════════

detect_xray_config() {
    local candidates=(
        "/usr/local/x-ui/bin/config.json"
        "/etc/x-ui/config.json"
        "/usr/local/3x-ui/bin/config.json"
        "/etc/3x-ui/config.json"
        "/usr/local/xray/config.json"
    )
    for f in "${candidates[@]}"; do
        [ -f "$f" ] && echo "$f" && return 0
    done
    return 1
}

backup_xray_config() {
    local cfg="$1"
    local bak="${BACKUP_DIR}/config.json.bak.$(date +%s)"
    cp "$cfg" "$bak" || { echo -e "${RED}[ERROR] Не удалось создать бэкап!${NC}"; return 1; }
    echo "$bak"
    log_action "BACKUP: ${cfg} → ${bak}"
}

validate_xray_config() {
    local cfg="$1"
    python3 -c "import json; json.load(open('${cfg}'))" 2>/dev/null && return 0
    return 1
}

rollback_xray_config() {
    local bak="$1"
    local cfg="${bak##*/}"          # config.json.bak.TIMESTAMP
    local orig
    orig=$(detect_xray_config)
    if [ -z "$orig" ]; then
        echo -e "${RED}[ERROR] Оригинальный config не найден!${NC}"; return 1
    fi
    cp "$bak" "$orig" || { echo -e "${RED}[ERROR] Rollback не удался!${NC}"; return 1; }
    systemctl restart x-ui 2>/dev/null
    echo -e "${GREEN}[OK] Rollback выполнен из: ${bak}${NC}"
    log_action "ROLLBACK: restored from ${bak}"
}

patch_xray_warp_outbound() {
    local cfg="$1" port="$2"
    python3 - <<EOF
import json, sys
try:
    with open('${cfg}') as f:
        c = json.load(f)
    # Удалить старый warp если есть
    c['outbounds'] = [o for o in c.get('outbounds', []) if o.get('tag') != 'warp']
    # Добавить новый
    c['outbounds'].append({
        "tag": "warp",
        "protocol": "socks",
        "settings": {
            "servers": [{"address": "127.0.0.1", "port": ${port}}]
        }
    })
    with open('${cfg}', 'w') as f:
        json.dump(c, f, ensure_ascii=False, indent=2)
    print("OK")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

remove_xray_warp_outbound() {
    local cfg="$1"
    python3 - <<EOF
import json, sys
try:
    with open('${cfg}') as f:
        c = json.load(f)
    before = len(c.get('outbounds', []))
    c['outbounds'] = [o for o in c.get('outbounds', []) if o.get('tag') != 'warp']
    after = len(c.get('outbounds', []))
    with open('${cfg}', 'w') as f:
        json.dump(c, f, ensure_ascii=False, indent=2)
    print(f"Removed {before - after} warp outbound(s)")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
EOF
}

apply_xray_warp() {
    local cfg
    cfg=$(detect_xray_config)
    if [ -z "$cfg" ]; then
        echo -e "${RED}[ERROR] xray config.json не найден.${NC}"
        echo -e "${WHITE}Проверен: /usr/local/x-ui/bin/config.json и другие пути.${NC}"
        read -p "Нажмите Enter..."; return 1
    fi

    echo -e "${CYAN}[*] Конфиг: ${WHITE}${cfg}${NC}"

    if ! is_warp_running; then
        echo -e "${RED}[ERROR] WARP не запущен! Сначала запустите WARP (п.9).${NC}"
        read -p "Нажмите Enter..."; return 1
    fi

    # Бэкап
    local bak
    bak=$(backup_xray_config "$cfg")
    if [ $? -ne 0 ]; then read -p "Нажмите Enter..."; return 1; fi
    echo -e "${GREEN}[✓] Бэкап: ${bak}${NC}"

    # Патч
    echo -e "${YELLOW}[*] Добавление outbound warp → 127.0.0.1:${WARP_SOCKS_PORT}...${NC}"
    local result
    result=$(patch_xray_warp_outbound "$cfg" "$WARP_SOCKS_PORT")
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] Патч не удался: ${result}${NC}"
        echo -e "${YELLOW}[*] Откат...${NC}"
        rollback_xray_config "$bak"
        read -p "Нажмите Enter..."; return 1
    fi

    # Валидация JSON
    if ! validate_xray_config "$cfg"; then
        echo -e "${RED}[ERROR] JSON невалиден после патча!${NC}"
        echo -e "${YELLOW}[*] Автоматический откат...${NC}"
        rollback_xray_config "$bak"
        read -p "Нажмите Enter..."; return 1
    fi

    # Перезапуск xray
    echo -e "${YELLOW}[*] Перезапуск x-ui...${NC}"
    systemctl restart x-ui 2>/dev/null
    sleep 2

    # Проверка
    if systemctl is-active x-ui &>/dev/null; then
        echo -e "${GREEN}[✓] x-ui запущен успешно!${NC}"
        log_action "XRAY PATCH: warp outbound added, port=${WARP_SOCKS_PORT}, cfg=${cfg}"
    else
        echo -e "${RED}[ERROR] x-ui не запустился после патча!${NC}"
        echo -e "${YELLOW}[*] Автоматический откат...${NC}"
        rollback_xray_config "$bak"
        read -p "Нажмите Enter..."; return 1
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Outbound 'warp' успешно добавлен!${NC}"
    echo -e "${WHITE}  SOCKS5: 127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo -e "${WHITE}  Бэкап:  ${bak}${NC}"
    echo -e "${WHITE}  Rollback: govpn rollback ${bak}${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Теперь добавьте routing rule в 3x-ui UI:${NC}"
    echo -e "  outboundTag: warp"
    echo -e "  domain: geosite:openai, geosite:netflix, ..."
    echo ""
    read -p "Нажмите Enter..."
}

show_xray_json() {
    clear
    echo -e "\n${CYAN}━━━ JSON для 3X-UI / x-ui-pro ━━━${NC}\n"
    echo -e "${WHITE}Xray Settings → Outbounds → добавить:${NC}\n"
    echo -e "${GREEN}── Outbound (warp) ──${NC}\n"
    cat <<EOF
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${WARP_SOCKS_PORT}
      }
    ]
  }
}
EOF
    echo -e "\n${GREEN}── Routing Rule (примеры) ──${NC}\n"
    cat <<EOF
{
  "outboundTag": "warp",
  "domain": [
    "geosite:openai",
    "geosite:netflix",
    "geosite:disney",
    "geosite:spotify",
    "domain:chat.openai.com",
    "domain:claude.ai"
  ]
}
EOF
    echo ""
    if is_warp_running; then
        local wip; wip=$(get_warp_ip)
        echo -e "${WHITE}WARP IP: ${GREEN}${wip}${NC}"
    fi
    echo -e "${WHITE}SOCKS5:  ${CYAN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

show_backups() {
    clear
    echo -e "\n${CYAN}━━━ Бэкапы xray config ━━━${NC}\n"
    local baks
    baks=$(ls -t "${BACKUP_DIR}"/config.json.bak.* 2>/dev/null)
    if [ -z "$baks" ]; then
        echo -e "${YELLOW}Бэкапов нет.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    local i=1
    declare -a bak_arr=()
    while IFS= read -r b; do
        local ts; ts=$(echo "$b" | grep -oE '[0-9]+$')
        local dt; dt=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")
        echo -e "  ${YELLOW}[${i}]${NC} ${dt}  ${WHITE}${b}${NC}"
        bak_arr+=("$b")
        ((i++))
    done <<< "$baks"
    echo -e "  ${YELLOW}[0]${NC} Назад"
    echo ""
    read -p "Восстановить из бэкапа (номер или 0): " ch
    [[ "$ch" == "0" || -z "$ch" ]] && return
    local idx=$((ch - 1))
    [ -z "${bak_arr[$idx]:-}" ] && return
    echo ""
    read -p "Восстановить из ${bak_arr[$idx]}? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    rollback_xray_config "${bak_arr[$idx]}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  WARP
# ═══════════════════════════════════════════════════════════════

is_warp_installed() {
    command -v warp-cli &>/dev/null
}

is_warp_running() {
    local st
    st=$(warp-cli --accept-tos status 2>/dev/null)
    # warp-cli выводит "Status update: Connected" или "Status update: Disconnected"
    if echo "$st" | grep -qi "disconnected"; then return 1; fi
    if echo "$st" | grep -qi "connected"; then return 0; fi
    return 1
}

get_warp_status_text() {
    if ! is_warp_installed; then echo "Не установлен"; return; fi
    local st
    st=$(warp-cli --accept-tos status 2>/dev/null)
    if echo "$st" | grep -qi "disconnected"; then echo "Отключён"
    elif echo "$st" | grep -qi "connected"; then echo "Подключён"
    elif echo "$st" | grep -qi "registration missing"; then echo "Нет регистрации"
    elif echo "$st" | grep -qi "unable to connect"; then echo "Ошибка подключения"
    else echo "Неизвестно ($(echo "$st" | head -1))"; fi
}

get_warp_ip() {
    local ip="" proxy="socks5://127.0.0.1:${WARP_SOCKS_PORT}"
    local services=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    for svc in "${services[@]}"; do
        ip=$(curl -s4 --max-time 8 --proxy "$proxy" "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return
        fi
    done
    echo "N/A"
}

# Возвращает IP с предупреждением если совпадает с реальным
get_warp_ip_display() {
    local wip; wip=$(get_warp_ip)
    if [ "$wip" = "N/A" ]; then
        echo -e "${RED}N/A${NC}"
    elif [ -n "$MY_IP" ] && [ "$wip" = "$MY_IP" ]; then
        echo -e "${YELLOW}${wip} ⚠ совпадает с реальным IP${NC}"
    else
        echo -e "${GREEN}${wip}${NC}"
    fi
}

_warp_detect_state() {
    # Возвращает: ok | no_registration | not_connected | not_installed | broken
    if ! is_warp_installed; then echo "not_installed"; return; fi
    local st
    st=$(warp-cli --accept-tos status 2>/dev/null)
    if echo "$st" | grep -qi "registration missing"; then echo "no_registration"; return; fi
    if echo "$st" | grep -qi "connected" && ! echo "$st" | grep -qi "disconnected"; then echo "ok"; return; fi
    if echo "$st" | grep -qi "disconnected"; then echo "not_connected"; return; fi
    echo "broken"
}

_warp_purge() {
    echo -e "${YELLOW}  [*] Полная очистка WARP...${NC}"
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    warp-cli --accept-tos registration delete > /dev/null 2>&1
    systemctl stop warp-svc > /dev/null 2>&1
    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y --purge cloudflare-warp > /dev/null 2>&1
    apt-get autoremove -y > /dev/null 2>&1
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    # Удалить WireGuard интерфейс если остался
    ip link delete warp0 2>/dev/null || true
    echo -e "${GREEN}  ✓ WARP полностью удалён${NC}"
    log_action "WARP PURGE: full cleanup done"
}

_warp_register() {
    # Принимает опциональный прокси $1
    local proxy="${1:-}"
    if [ -n "$proxy" ]; then
        [[ "$proxy" != socks5://* ]] && proxy="socks5://${proxy}"
        echo -e "${YELLOW}  [*] Регистрация через прокси ${proxy}...${NC}"
        ALL_PROXY="$proxy" warp-cli --accept-tos registration new > /dev/null 2>&1
    else
        warp-cli --accept-tos registration new > /dev/null 2>&1
    fi
    return $?
}

_warp_check_api() {
    # Возвращает 0 если API доступен, 1 если нет
    curl -s --max-time 8 --connect-timeout 5 \
        https://api.cloudflareclient.com/v0a2158/reg \
        -o /dev/null 2>/dev/null
    return $?
}

_warp_autorepair() {
    echo ""
    echo -e "${CYAN}━━━ Авторемонт WARP ━━━${NC}"
    echo ""

    # Шаг 1: проверка API
    echo -e "${YELLOW}[1/4]${NC} Проверка доступности Cloudflare API..."
    if _warp_check_api; then
        echo -e "${GREEN}  ✓ API доступен — продолжаем${NC}"
    else
        echo -e "${RED}  ✗ Cloudflare API недоступен с этого IP${NC}"
        echo ""
        echo -e "${CYAN}━━━ Диагностика ━━━${NC}"
        echo ""
        echo -e "${WHITE}Cloudflare блокирует регистрацию warp-cli с российских IP.${NC}"
        echo -e "${YELLOW}Важно:${NC} ${WHITE}warp-cli игнорирует SOCKS5 прокси при регистрации —"
        echo -e "передача прокси через ALL_PROXY не работает с официальным клиентом.${NC}"
        echo ""
        echo -e "${CYAN}━━━ Что делать ━━━${NC}"
        echo ""
        echo -e "  ${GREEN}[рекомендуется]${NC} WARP нужен на AMS (exit-ноде), не на RU-bridge."
        echo -e "  Запустите ${WHITE}govpn${NC} на AMS и установите там."
        echo -e "  На RU трафик и так идёт через AMS — WARP на RU бессмысленен."
        echo ""
        echo -e "  ${YELLOW}[альтернатива]${NC} warp-go — реализация WARP на Go,"
        echo -e "  которая умеет регистрироваться через прокси."
        echo -e "  Установить: ${CYAN}https://github.com/bepass-org/warp-plus${NC}"
        echo ""
        echo -e "  ${WHITE}[1]${NC} Попробовать переустановить и зарегистрировать напрямую"
        echo -e "      (сработает если блокировка временная или на другом хостинге)"
        echo -e "  ${WHITE}[0]${NC} Отмена"
        echo ""
        read -p "Выбор: " api_ch
        case "$api_ch" in
            1)
                echo -e "${YELLOW}  Продолжаем с попыткой прямой регистрации...${NC}"
                ;;
            0|*)
                echo -e "${CYAN}Отменено.${NC}"
                log_action "WARP AUTOREPAIR: cancelled (API unavailable)"
                return 1
                ;;
        esac
    fi

    # Шаг 2: сброс состояния
    echo -e "${YELLOW}[2/4]${NC} Сброс текущего состояния WARP..."
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    warp-cli --accept-tos registration delete > /dev/null 2>&1
    systemctl restart warp-svc > /dev/null 2>&1
    sleep 2
    echo -e "${GREEN}  ✓ Состояние сброшено${NC}"

    # Шаг 3: регистрация
    echo -e "${YELLOW}[3/4]${NC} Регистрация аккаунта..."
    if _warp_register; then
        echo -e "${GREEN}  ✓ Аккаунт зарегистрирован${NC}"
    else
        echo -e "${RED}  ✗ Регистрация не удалась${NC}"
        echo ""
        echo -e "${YELLOW}Попробовать полную переустановку пакета?${NC}"
        echo -e "${WHITE}(иногда помогает при повреждённом состоянии демона)${NC}"
        read -p "(y/n): " reinstall_ch
        if [[ "$reinstall_ch" == "y" ]]; then
            echo -e "${YELLOW}[*] Полная переустановка...${NC}"
            _warp_purge
            sleep 1
            detect_os
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y > /dev/null 2>&1
            apt-get install -y cloudflare-warp > /dev/null 2>&1
            systemctl start warp-svc > /dev/null 2>&1
            sleep 2
            if ! _warp_register; then
                echo -e "${RED}  ✗ Регистрация после переустановки не удалась.${NC}"
                echo ""
                echo -e "${CYAN}━━━ Итог ━━━${NC}"
                echo -e "${WHITE}API Cloudflare недоступен с этого IP."
                echo -e "warp-cli не поддерживает обход через SOCKS5 при регистрации."
                echo ""
                echo -e "Рекомендации:${NC}"
                echo -e "  1) Установите WARP на ${GREEN}AMS сервер${NC} (exit-нода) — там нет блокировки"
                echo -e "  2) Используйте ${CYAN}warp-plus${NC} вместо официального клиента:"
                echo -e "     ${WHITE}https://github.com/bepass-org/warp-plus${NC}"
                echo ""
                log_action "WARP AUTOREPAIR: failed after reinstall (API blocked)"
                return 1
            fi
            echo -e "${GREEN}  ✓ Переустановка успешна${NC}"
        else
            log_action "WARP AUTOREPAIR: registration failed, user declined reinstall"
            return 1
        fi
    fi

    # Шаг 4: подключение
    echo -e "${YELLOW}[4/4]${NC} Настройка и подключение..."
    warp-cli --accept-tos mode proxy > /dev/null 2>&1
    warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" > /dev/null 2>&1
    warp-cli --accept-tos connect > /dev/null 2>&1

    # Ждём стабилизации — до 15 секунд с проверкой каждые 3 секунды
    local connected=0
    for attempt in 1 2 3 4 5; do
        sleep 3
        if is_warp_running; then
            connected=1
            break
        fi
        echo -e "  ${YELLOW}[*] Ожидание... (${attempt}/5)${NC}"
    done

    if [ "$connected" -eq 1 ]; then
        local wip; wip=$(get_warp_ip)
        echo -e "${GREEN}  ✓ WARP подключён!${NC}"
        echo -e "    ${WHITE}WARP IP: ${GREEN}${wip}${NC}"
        log_action "WARP AUTOREPAIR: success, warp_ip=${wip}"
        echo ""
        echo -e "${GREEN}━━━ Авторемонт завершён успешно ━━━${NC}"
        return 0
    else
        local real_st; real_st=$(warp-cli --accept-tos status 2>/dev/null | head -3)
        echo -e "${RED}  ✗ Подключение не установлено после 15 секунд ожидания.${NC}"
        echo -e "${WHITE}  Текущий статус:${NC}"
        echo "$real_st" | while IFS= read -r l; do echo -e "  ${YELLOW}  ${l}${NC}"; done
        echo ""
        echo -e "${WHITE}  Попробуйте: ${CYAN}warp-cli --accept-tos connect${NC}"
        echo -e "${WHITE}  Или чистую переустановку: п.8p${NC}"
        log_action "WARP AUTOREPAIR: connect timeout after 15s"
        return 1
    fi
}

_warp_ask_proxy() {
    # Интерактивно спрашивает прокси, возвращает в REPLY_PROXY
    REPLY_PROXY=""
    echo ""
    echo -e "${CYAN}━━━ API недоступен — регистрация через прокси ━━━${NC}"
    echo -e "${WHITE}Введите SOCKS5 прокси для регистрации:${NC}"
    echo -e "${WHITE}Форматы:${NC}"
    echo -e "  ${CYAN}host:port${NC}               (анонимный)"
    echo -e "  ${CYAN}user:pass@host:port${NC}      (с авторизацией)"
    echo -e "  ${CYAN}socks5://user:pass@host:port${NC}"
    echo ""
    read -p "> " REPLY_PROXY
}

reinstall_warp() {
    clear
    echo -e "\n${RED}━━━ Чистая переустановка WARP ━━━${NC}\n"
    echo -e "${WHITE}Будет выполнено:${NC}"
    echo -e "  ${RED}1.${NC} Полное удаление текущего WARP (пакет + регистрация + интерфейс)"
    echo -e "  ${GREEN}2.${NC} Свежая установка cloudflare-warp"
    echo -e "  ${GREEN}3.${NC} Регистрация нового аккаунта"
    echo -e "  ${GREEN}4.${NC} Подключение в режиме SOCKS5"
    echo ""
    echo -e "${YELLOW}Текущий статус:${NC}"
    if is_warp_installed; then
        warp-cli --accept-tos status 2>/dev/null | head -2 | \
            while IFS= read -r l; do echo -e "  ${WHITE}${l}${NC}"; done
        warp-cli --version 2>/dev/null | while IFS= read -r l; do echo -e "  ${WHITE}${l}${NC}"; done
    else
        echo -e "  ${RED}WARP не установлен${NC}"
    fi
    echo ""
    echo -e "${CYAN}SOCKS5 порт после переустановки: ${WHITE}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo ""
    read -p "$(echo -e "${RED}Выполнить чистую переустановку? (y/n): ${NC}")" confirm
    [[ "$confirm" != "y" ]] && echo -e "${CYAN}Отменено.${NC}" && read -p "Enter..." && return

    echo ""
    echo -e "${YELLOW}[1/4]${NC} Полное удаление WARP..."
    _warp_purge
    sleep 2

    echo -e "${YELLOW}[2/4]${NC} Проверка доступности Cloudflare API..."
    if _warp_check_api; then
        echo -e "${GREEN}  ✓ API доступен${NC}"
    else
        echo -e "${RED}  ✗ API недоступен с этого IP${NC}"
        echo -e "${WHITE}  Пакет будет установлен, но регистрация может не пройти.${NC}"
        echo -e "${WHITE}  Это нормально для RU-серверов — WARP нужен только на AMS.${NC}"
    fi

    echo -e "${YELLOW}[3/4]${NC} Установка cloudflare-warp..."
    detect_os
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        echo -e "${RED}[ERROR] Поддерживается только Ubuntu/Debian. Ваша ОС: ${OS_ID}${NC}"
        read -p "Нажмите Enter..."; return
    fi
    local codename="${OS_CODENAME}"
    [ -z "$codename" ] && codename=$(lsb_release -cs 2>/dev/null || echo "focal")
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1
    apt-get install -y cloudflare-warp > /dev/null 2>&1
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}[ERROR] Установка пакета не удалась.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    systemctl enable warp-svc > /dev/null 2>&1
    systemctl start warp-svc > /dev/null 2>&1
    sleep 3
    echo -e "${GREEN}  ✓ $(warp-cli --version 2>/dev/null) установлен${NC}"

    echo -e "${YELLOW}[4/4]${NC} Регистрация и подключение..."
    if _warp_register; then
        warp-cli --accept-tos mode proxy > /dev/null 2>&1
        warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" > /dev/null 2>&1
        warp-cli --accept-tos connect > /dev/null 2>&1
        sleep 3
        if is_warp_running; then
            local wip; wip=$(get_warp_ip)
            echo -e "${GREEN}  ✓ WARP подключён!${NC}"
            echo -e "    ${WHITE}WARP IP: ${GREEN}${wip}${NC}"
            log_action "WARP REINSTALL: success, warp_ip=${wip}"
        else
            echo -e "${YELLOW}  ⚠ Установлен, но соединение не установлено.${NC}"
            echo -e "  ${WHITE}Попробуйте: govpn → п.10 (Запустить WARP)${NC}"
            log_action "WARP REINSTALL: installed, connection unconfirmed"
        fi
    else
        echo -e "${RED}  ✗ Регистрация не удалась (API заблокирован).${NC}"
        echo -e "${WHITE}  Пакет установлен. Попробуйте авторемонт (п.8r) позже.${NC}"
        log_action "WARP REINSTALL: package ok, registration failed"
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Переустановка завершена.${NC}"
    echo -e "${WHITE}  SOCKS5: 127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo -e "${GREEN}══════════════════════════════════════════${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

install_warp() {
    clear
    echo -e "\n${CYAN}━━━ Установка Cloudflare WARP ━━━${NC}\n"

    # Определяем текущее состояние
    local state
    state=$(_warp_detect_state)

    case "$state" in
        ok)
            echo -e "${GREEN}WARP уже установлен и подключён.${NC}"
            warp-cli --version 2>/dev/null || true
            local wip; wip=$(get_warp_ip)
            echo -e "${WHITE}WARP IP: ${GREEN}${wip}${NC}"
            echo ""
            read -p "Нажмите Enter..."; return
            ;;
        not_connected)
            echo -e "${YELLOW}WARP установлен но отключён. Попытка подключить...${NC}"
            warp-cli --accept-tos mode proxy > /dev/null 2>&1
            warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" > /dev/null 2>&1
            warp-cli --accept-tos connect > /dev/null 2>&1
            sleep 3
            if is_warp_running; then
                echo -e "${GREEN}[OK] WARP подключён.${NC}"
                log_action "WARP RECONNECT: ok"
            else
                echo -e "${RED}Не удалось подключить. Запускаем авторемонт...${NC}"
                sleep 1
                _warp_autorepair
            fi
            read -p "Нажмите Enter..."; return
            ;;
        no_registration)
            echo -e "${YELLOW}WARP установлен но нет регистрации. Запускаем авторемонт...${NC}"
            sleep 1
            _warp_autorepair
            read -p "Нажмите Enter..."; return
            ;;
        broken)
            echo -e "${RED}WARP в неработоспособном состоянии. Запускаем авторемонт...${NC}"
            sleep 1
            _warp_autorepair
            read -p "Нажмите Enter..."; return
            ;;
        not_installed)
            : # продолжаем установку ниже
            ;;
    esac

    # Проверка конфликтов перед установкой
    check_conflicts || return

    detect_os
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        echo -e "${RED}[ERROR] Поддерживаются только Ubuntu и Debian.${NC}"
        echo -e "${WHITE}Ваша ОС: ${YELLOW}${OS_ID} ${OS_VERSION}${NC}"
        read -p "Нажмите Enter..."; return
    fi

    echo -e "${YELLOW}[1/6]${NC} Добавление GPG-ключа Cloudflare..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] Не удалось добавить GPG-ключ.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "${GREEN}  ✓ GPG-ключ добавлен${NC}"

    echo -e "${YELLOW}[2/6]${NC} Добавление репозитория..."
    local codename="${OS_CODENAME}"
    [ -z "$codename" ] && codename=$(lsb_release -cs 2>/dev/null || echo "focal")
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ ${codename} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
    echo -e "${GREEN}  ✓ Репозиторий (${codename})${NC}"

    echo -e "${YELLOW}[3/6]${NC} Установка пакета..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y > /dev/null 2>&1
    apt-get install -y cloudflare-warp > /dev/null 2>&1
    if ! command -v warp-cli &>/dev/null; then
        echo -e "${RED}[ERROR] Установка не удалась.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "${GREEN}  ✓ cloudflare-warp установлен${NC}"

    echo -e "${YELLOW}[3.5/6]${NC} Проверка доступности Cloudflare API..."
    local install_proxy=""
    if _warp_check_api; then
        echo -e "${GREEN}  ✓ Cloudflare API доступен${NC}"
    else
        echo -e "${RED}  ✗ Cloudflare API недоступен с этого IP${NC}"
        echo ""
        echo -e "${WHITE}Cloudflare блокирует регистрацию WARP с некоторых IP.${NC}"
        echo -e "${WHITE}Чаще всего это российские и некоторые европейские хостинги.${NC}"
        echo ""
        echo -e "  ${GREEN}[1]${NC} Ввести SOCKS5 прокси для регистрации"
        echo -e "  ${YELLOW}[2]${NC} Продолжить без прокси (попытка напрямую)"
        echo -e "  ${CYAN}[3]${NC} Установить WARP на AMS (exit-ноду) вместо RU-bridge"
        echo -e "  ${RED}[0]${NC} Отмена"
        echo ""
        read -p "Выбор: " api_choice
        case "$api_choice" in
            1)
                _warp_ask_proxy
                install_proxy="$REPLY_PROXY"
                [ -z "$install_proxy" ] && echo -e "${RED}Прокси не указан. Отмена.${NC}" && read -p "Enter..." && return
                ;;
            2)
                echo -e "${YELLOW}  Продолжаем без прокси...${NC}"
                ;;
            3)
                echo -e "\n${CYAN}Запустите govpn на AMS сервере и установите WARP там.${NC}"
                echo -e "${WHITE}WARP на RU-bridge не нужен — трафик выходит через AMS.${NC}"
                read -p "Нажмите Enter..."; return
                ;;
            0|*)
                echo -e "${CYAN}Установка отменена.${NC}"
                read -p "Нажмите Enter..."; return
                ;;
        esac
    fi

    echo -e "${YELLOW}[4/6]${NC} Регистрация аккаунта..."
    if ! _warp_register "$install_proxy"; then
        echo -e "${RED}  ✗ Регистрация не удалась.${NC}"
        echo -e "${YELLOW}  Запускаем авторемонт...${NC}"
        sleep 1
        _warp_autorepair
        read -p "Нажмите Enter..."; return
    fi
    echo -e "${GREEN}  ✓ Аккаунт зарегистрирован${NC}"

    echo -e "${YELLOW}[5/6]${NC} Настройка SOCKS5-прокси на порту ${WARP_SOCKS_PORT}..."
    warp-cli --accept-tos mode proxy > /dev/null 2>&1
    warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" > /dev/null 2>&1
    save_config_val "WARP_SOCKS_PORT" "${WARP_SOCKS_PORT}"
    echo -e "${GREEN}  ✓ SOCKS5: 127.0.0.1:${WARP_SOCKS_PORT}${NC}"

    echo -e "${YELLOW}[6/6]${NC} Подключение..."
    warp-cli --accept-tos connect > /dev/null 2>&1
    sleep 3

    if is_warp_running; then
        local wip; wip=$(get_warp_ip)
        echo -e "${GREEN}  ✓ WARP подключён!${NC}"
        echo -e "    ${WHITE}WARP IP: ${GREEN}${wip}${NC}"
        log_action "WARP INSTALL: port=${WARP_SOCKS_PORT}, warp_ip=${wip}"
    else
        echo -e "${YELLOW}  ⚠ WARP установлен, но подключение не подтверждено.${NC}"
        echo -e "  ${WHITE}Попробуйте: ${CYAN}warp-cli --accept-tos connect${NC}"
        log_action "WARP INSTALL: installed, connection unconfirmed"
    fi

    echo ""
    echo -e "${CYAN}Следующий шаг: п.13 — применить в xray config автоматически.${NC}"
    echo ""
    read -p "Нажмите Enter..."
}

start_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен. Выполните п.8.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    if is_warp_running; then
        local wip; wip=$(get_warp_ip)
        echo -e "\n${GREEN}WARP уже подключён.${NC}"
        echo -e "  ${WHITE}WARP IP: ${GREEN}${wip}${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "\n${YELLOW}[*] Подключение WARP...${NC}"
    echo -e "${WHITE}    (может занять до 15 секунд)${NC}"
    warp-cli --accept-tos connect > /dev/null 2>&1

    # Ждём стабилизации — до 5 попыток по 3 секунды
    local connected=0
    for attempt in 1 2 3 4 5; do
        sleep 3
        if is_warp_running; then
            connected=1
            break
        fi
        echo -e "  ${YELLOW}[*] Ожидание... (${attempt}/5)${NC}"
    done

    if [ "$connected" -eq 1 ]; then
        local wip; wip=$(get_warp_ip)
        echo -e "${GREEN}[OK] WARP подключён.${NC}"
        echo -e "  ${WHITE}WARP IP: ${GREEN}${wip}${NC}"
        log_action "WARP START: warp_ip=${wip}"
    else
        local real_st; real_st=$(warp-cli --accept-tos status 2>/dev/null | head -3)
        echo -e "${RED}[ERROR] Не удалось подключить за 15 секунд.${NC}"
        echo -e "${WHITE}Статус:${NC}"
        echo "$real_st" | while IFS= read -r l; do echo -e "  ${YELLOW}${l}${NC}"; done
        echo ""
        echo -e "${WHITE}Если статус 'Connecting' — подождите ещё немного и попробуйте снова.${NC}"
        echo -e "${WHITE}Если не помогает — запустите авторемонт: п.8r${NC}"
    fi
    read -p "Нажмите Enter..."
}

stop_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "\n${YELLOW}[*] Отключение WARP...${NC}"
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    echo -e "${GREEN}[OK] WARP отключён.${NC}"
    log_action "WARP STOP"
    read -p "Нажмите Enter..."
}

show_warp_status() {
    clear
    echo -e "\n${CYAN}━━━ Статус WARP ━━━${NC}\n"
    if ! is_warp_installed; then
        echo -e "  ${WHITE}Статус: ${RED}Не установлен${NC}"
        read -p "Нажмите Enter..."; return
    fi
    local st_text st_color
    st_text=$(get_warp_status_text)
    st_color="$RED"
    [[ "$st_text" == "Подключён" ]] && st_color="$GREEN"
    [[ "$st_text" == "Отключён" ]] && st_color="$YELLOW"

    echo -e "  ${WHITE}Статус:      ${st_color}${st_text}${NC}"
    echo -e "  ${WHITE}Порт SOCKS5: ${CYAN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
    echo -e "  ${WHITE}Реальный IP: ${GREEN}${MY_IP}${NC}"

    if is_warp_running; then
        echo -e "  ${WHITE}WARP IP:     $(get_warp_ip_display)${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}── warp-cli status ──${NC}"
    warp-cli --accept-tos status 2>/dev/null | while IFS= read -r line; do
        echo -e "  ${WHITE}${line}${NC}"
    done
    echo ""
    read -p "Нажмите Enter..."
}

rekey_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "\n${CYAN}━━━ Перевыпуск ключа WARP ━━━${NC}\n"
    echo -e "${YELLOW}Регистрация будет пересоздана. WARP временно отключится.${NC}"
    read -p "Продолжить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}[1/4] Отключение...${NC}"
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    echo -e "${YELLOW}[2/4] Удаление регистрации...${NC}"
    warp-cli --accept-tos registration delete > /dev/null 2>&1
    echo -e "${YELLOW}[3/4] Новая регистрация...${NC}"
    warp-cli --accept-tos registration new > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}[ERROR] Регистрация не удалась.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "${YELLOW}[4/4] Подключение...${NC}"
    warp-cli --accept-tos mode proxy > /dev/null 2>&1
    warp-cli --accept-tos proxy port "${WARP_SOCKS_PORT}" > /dev/null 2>&1
    warp-cli --accept-tos connect > /dev/null 2>&1
    sleep 3

    if is_warp_running; then
        local wip; wip=$(get_warp_ip)
        echo -e "${GREEN}[OK] Новый WARP IP: ${wip}${NC}"
        log_action "WARP REKEY: warp_ip=${wip}"
    else
        echo -e "${YELLOW}[WARN] Подключение не подтверждено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

change_warp_port() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -p "Нажмите Enter..."; return
    fi
    echo -e "\n${CYAN}━━━ Изменение порта SOCKS5 ━━━${NC}\n"
    echo -e "${WHITE}Текущий порт: ${GREEN}${WARP_SOCKS_PORT}${NC}\n"
    local new_port
    while true; do
        read -p "Новый порт (1024-65535): " new_port
        [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )) && break
        echo -e "${RED}Некорректный порт.${NC}"
    done
    # Проверка что порт свободен
    if ss -tlnp 2>/dev/null | grep -q ":${new_port} "; then
        echo -e "${RED}[ERROR] Порт ${new_port} уже занят!${NC}"
        ss -tlnp 2>/dev/null | grep ":${new_port} "
        read -p "Нажмите Enter..."; return
    fi
    warp-cli --accept-tos proxy port "$new_port" > /dev/null 2>&1
    save_config_val "WARP_SOCKS_PORT" "$new_port"
    WARP_SOCKS_PORT="$new_port"
    echo -e "${GREEN}[OK] Порт изменён на ${new_port}.${NC}"
    echo -e "${YELLOW}Не забудьте обновить outbound в xray config (п.13)!${NC}"
    log_action "WARP PORT: changed to ${new_port}"
    read -p "Нажмите Enter..."
}

uninstall_warp() {
    clear
    echo -e "\n${RED}━━━ Удаление WARP ━━━${NC}\n"
    echo -e "${WHITE}Будут удалены:${NC}"
    echo -e "  ${RED}•${NC} Пакет cloudflare-warp"
    echo -e "  ${RED}•${NC} Репозиторий и GPG-ключ"
    echo -e "${GREEN}НЕ будет затронуто:${NC}"
    echo -e "  ${GREEN}•${NC} 3X-UI / xray (outbound 'warp' нужно убрать вручную или через п.13)"
    echo -e "  ${GREEN}•${NC} Конфигурация ${SCRIPT_NAME}"
    echo ""
    read -p "Удалить WARP? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    warp-cli --accept-tos disconnect > /dev/null 2>&1
    warp-cli --accept-tos registration delete > /dev/null 2>&1
    export DEBIAN_FRONTEND=noninteractive
    apt-get remove -y cloudflare-warp > /dev/null 2>&1
    apt-get autoremove -y > /dev/null 2>&1
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo -e "${GREEN}[OK] WARP удалён.${NC}"
    log_action "WARP UNINSTALL"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  VALIDATION & IP UTILS
# ═══════════════════════════════════════════════════════════════

validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for o in "${octets[@]}"; do (( o > 255 )) && return 1; done
        return 0
    fi
    return 1
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

read_validated_ip() {
    local prompt="${1:-Введите IP:}"
    while true; do
        echo -e "$prompt"
        read -p "> " _RET_IP
        validate_ip "$_RET_IP" && return 0
        echo -e "${RED}Некорректный IP-адрес!${NC}"
    done
}

read_validated_port() {
    local prompt="${1:-Введите порт:}"
    while true; do
        echo -e "$prompt"
        read -p "> " _RET_PORT
        validate_port "$_RET_PORT" && return 0
        echo -e "${RED}Порт должен быть числом от 1 до 65535!${NC}"
    done
}

# ═══════════════════════════════════════════════════════════════
#  ALIASES (имена серверов)
# ═══════════════════════════════════════════════════════════════

set_alias_full() {
    local ip="$1" name="$2" note="${3:-}" country="${4:-}" isp="${5:-}"
    local val="${name}|${note}|${country}|${isp}"
    if grep -q "^${ip}=" "$ALIASES_FILE" 2>/dev/null; then
        sed -i "s|^${ip}=.*|${ip}=${val}|" "$ALIASES_FILE"
    else
        echo "${ip}=${val}" >> "$ALIASES_FILE"
    fi
}

set_alias()      { local e; e=$(grep "^${1}=" "$ALIASES_FILE" 2>/dev/null | cut -d= -f2-); local _n _o _c _i; IFS='|' read -r _ _o _c _i <<< "$e"; set_alias_full "$1" "$2" "${_o}" "${_c}" "${_i}"; }
set_alias_note() { local e; e=$(grep "^${1}=" "$ALIASES_FILE" 2>/dev/null | cut -d= -f2-); local _n _o _c _i; IFS='|' read -r _n _ _c _i <<< "$e"; set_alias_full "$1" "${_n}" "$2" "${_c}" "${_i}"; }
set_alias_geo()  { local e; e=$(grep "^${1}=" "$ALIASES_FILE" 2>/dev/null | cut -d= -f2-); local _n _o _c _i; IFS='|' read -r _n _o _ _ <<< "$e"; set_alias_full "$1" "${_n}" "${_o}" "$2" "$3"; }

get_alias_field() {
    local ip="$1" field="$2"
    local raw; raw=$(grep "^${ip}=" "$ALIASES_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    local f_name f_note f_country f_isp
    IFS='|' read -r f_name f_note f_country f_isp <<< "$raw"
    case "$field" in
        name) echo "$f_name" ;; note) echo "$f_note" ;;
        country) echo "$f_country" ;; isp) echo "$f_isp" ;;
        *) echo "$f_name" ;;
    esac
}

get_alias() { get_alias_field "$1" "name"; }

fmt_ip() {
    local ip="$1"
    local name country isp
    name=$(get_alias_field "$ip" "name")
    country=$(get_alias_field "$ip" "country")
    isp=$(get_alias_field "$ip" "isp")
    local r=""
    [ -n "$name" ] && r="${name} " || r=""
    r+="($ip)"
    ( [ -n "$country" ] || [ -n "$isp" ] ) && r+=" " && \
        [ -n "$country" ] && r+="$country" && [ -n "$isp" ] && r+=" | $isp"
    echo "$r"
}

fmt_ip_short() {
    local name; name=$(get_alias_field "$1" "name")
    [ -n "$name" ] && echo "$name ($1)" || echo "$1"
}

manage_aliases_menu() {
    while true; do
        clear
        echo -e "${CYAN}━━━ Имена серверов ━━━${NC}"
        local -a ips=()
        while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
        if [ ${#ips[@]} -eq 0 ]; then
            echo -e "${YELLOW}Нет серверов в правилах.${NC}"
            read -p "Enter..."; return
        fi
        for i in "${!ips[@]}"; do
            echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip "${ips[$i]}")"
            local note; note=$(get_alias_field "${ips[$i]}" "note")
            [ -n "$note" ] && echo -e "       ${WHITE}${note}${NC}"
        done
        echo -e "  ${YELLOW}[0]${NC} Назад"
        read -p "Сервер: " choice
        [[ "$choice" == "0" || -z "$choice" ]] && return
        local idx=$((choice - 1))
        [ -z "${ips[$idx]:-}" ] && continue
        local sel="${ips[$idx]}"
        echo -e "Новое имя (Enter — оставить):"
        read -p "> " nn; [ -n "$nn" ] && set_alias "$sel" "$nn"
        echo -e "Примечание (Enter — оставить):"
        read -p "> " nt; [ -n "$nt" ] && set_alias_note "$sel" "$nt"
        echo -e "${GREEN}[OK]${NC}"; read -p "Enter..."
    done
}

# ═══════════════════════════════════════════════════════════════
#  GEOIP + PROBE
# ═══════════════════════════════════════════════════════════════

geoip_lookup() {
    curl -s --max-time 5 \
        "http://ip-api.com/json/${1}?fields=status,country,regionName,city,isp,org" 2>/dev/null
}

tcp_ping() {
    local ip="$1" port="$2" tout="${3:-3}"
    local raw
    raw=$(curl -so /dev/null -w '%{time_connect}' \
        --max-time "$tout" --connect-timeout "$tout" \
        "http://${ip}:${port}/" 2>/dev/null)
    [ -z "$raw" ] && return 1
    local ms
    ms=$(awk "BEGIN {v=$raw*1000; if(v<0.5) exit 1; printf \"%.2f\", v}" 2>/dev/null) || return 1
    echo "$ms"
}

smart_ping() {
    local ip="$1" tout="${2:-3}" port="${3:-}"
    local ms
    ms=$(ping -c 1 -W "$tout" "$ip" 2>/dev/null | \
        sed -n 's/.*time=\([0-9.]*\).*/\1/p')
    if [ -n "$ms" ]; then echo "ICMP|$ms"; return 0; fi
    [ -z "$port" ] && port=$(get_port_for_ip "$ip")
    [ -z "$port" ] && return 1
    ms=$(tcp_ping "$ip" "$port" "$tout")
    if [ -n "$ms" ]; then echo "TCP:${port}|$ms"; return 0; fi
    return 1
}

probe_server_cli() {
    local ip="$1" port="${2:-}"
    echo -e "\n${CYAN}━━━ Проверка ${ip} ━━━${NC}"

    echo -e "${YELLOW}[*] GeoIP...${NC}"
    local geo; geo=$(geoip_lookup "$ip")
    local geo_status; geo_status=$(echo "$geo" | jq -r '.status // "fail"' 2>/dev/null)
    if [ "$geo_status" = "success" ]; then
        local country city isp org loc provider
        country=$(echo "$geo" | jq -r '.country // ""')
        city=$(echo "$geo" | jq -r '.city // ""')
        isp=$(echo "$geo" | jq -r '.isp // ""')
        org=$(echo "$geo" | jq -r '.org // ""')
        loc="$country"; [ -n "$city" ] && loc+=", $city"
        provider="$isp"; [ -n "$org" ] && [ "$org" != "$isp" ] && provider+=" ($org)"
        echo -e "  ${WHITE}GeoIP:${NC} ${GREEN}${loc}${NC} | ${CYAN}${provider}${NC}"
        set_alias_geo "$ip" "$country" "$isp"
    else
        echo -e "  ${RED}GeoIP: не удалось определить${NC}"
    fi

    echo -e "${YELLOW}[*] Ping (3x)...${NC}"
    local -a pings=()
    local plost=0
    for n in 1 2 3; do
        local raw method="" ms=""
        raw=$(smart_ping "$ip" 3 "$port")
        if [ -n "$raw" ]; then
            method="${raw%%|*}"; ms="${raw#*|}"
            pings+=("$ms")
            echo -e "  #${n}: ${GREEN}${ms}ms${NC} ${CYAN}[${method}]${NC}"
        else
            ((plost++))
            echo -e "  #${n}: ${RED}timeout${NC}"
        fi
        [ "$n" -lt 3 ] && sleep 1
    done

    if [ ${#pings[@]} -gt 0 ]; then
        local pavg
        pavg=$(printf '%s\n' "${pings[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')
        echo -e "  ${WHITE}Среднее: ${pavg}ms  Потеряно: ${plost}/3${NC}"
    else
        echo -e "  ${RED}Сервер не отвечает на ping${NC}"
    fi

    echo ""
    local existing; existing=$(get_alias "$ip")
    [ -n "$existing" ] && echo -e "Текущее имя: ${GREEN}${existing}${NC}"
    echo -e "Имя сервера (Enter — пропустить):"
    read -p "> " _RET_NAME
    [ -n "$_RET_NAME" ] && set_alias "$ip" "$_RET_NAME"
    echo -e "Примечание (Enter — пропустить):"
    read -p "> " _RET_NOTE
    [ -n "$_RET_NOTE" ] && set_alias_note "$ip" "$_RET_NOTE"

    if [ ${#pings[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}Сервер не ответил на ICMP/TCP.${NC}"
        echo -e "${CYAN}Включить ping на удалённом сервере:${NC}"
        echo -e "  ${GREEN}sysctl -w net.ipv4.icmp_echo_ignore_all=0${NC}"
        echo -e "  ${GREEN}iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT${NC}"
        echo ""
        read -p "Продолжить добавление правила? (y/n): " ans
        [[ "$ans" != "y" ]] && return 1
    fi
    return 0
}

# ═══════════════════════════════════════════════════════════════
#  IPTABLES RULES
# ═══════════════════════════════════════════════════════════════

get_rules_list() {
    iptables -t nat -S PREROUTING 2>/dev/null | \
        grep "DNAT" | grep "govpn" | \
        sed -n 's/.*-p \([a-z]*\).*--dport \([0-9]*\).*--to-destination \([^[:space:]]*\).*/\1|\2|\3/p'
}

get_target_ips() {
    get_rules_list | awk -F'|' '{split($3,a,":"); print a[1]}' | sort -u
}

get_port_for_ip() {
    local ip="$1"
    get_rules_list | awk -F'|' -v ip="$ip" \
        '{split($3,a,":"); if(a[1]==ip){print a[2]; exit}}'
}

remove_rules_for_port() {
    local proto="$1" in_port="$2"
    iptables -t nat -S PREROUTING 2>/dev/null | grep "DNAT" | \
        grep -- "--dport ${in_port} " | grep -- "-p ${proto} " | \
        while read -r rule; do
            eval "iptables -t nat -D ${rule#-A }" 2>/dev/null
        done
    for chain in INPUT FORWARD; do
        iptables -S "$chain" 2>/dev/null | grep "govpn" | \
            grep -- "--dport ${in_port} " | grep -- "-p ${proto} " | \
            while read -r rule; do
                eval "iptables -D ${rule#-A }" 2>/dev/null
            done
        iptables -S "$chain" 2>/dev/null | grep "govpn" | \
            grep -- "--sport ${in_port} " | grep -- "-p ${proto} " | \
            while read -r rule; do
                eval "iptables -D ${rule#-A }" 2>/dev/null
            done
    done
}

apply_iptables_rules() {
    local proto="$1" in_port="$2" out_port="$3" target_ip="$4" name="$5"
    echo -e "${YELLOW}[*] Применение правил iptables...${NC}"
    log_action "ADD rule: ${proto} :${in_port} -> ${target_ip}:${out_port} (${name})"

    remove_rules_for_port "$proto" "$in_port"

    iptables -I INPUT -p "$proto" --dport "$in_port" \
        -m comment --comment "govpn:${in_port}:${proto}" -j ACCEPT

    iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" \
        -j DNAT --to-destination "${target_ip}:${out_port}"

    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    iptables -I FORWARD -p "$proto" -d "$target_ip" --dport "$out_port" \
        -m state --state NEW,ESTABLISHED,RELATED \
        -m comment --comment "govpn:${in_port}:${proto}" -j ACCEPT

    iptables -I FORWARD -p "$proto" -s "$target_ip" --sport "$out_port" \
        -m state --state ESTABLISHED,RELATED \
        -m comment --comment "govpn:${in_port}:${proto}" -j ACCEPT

    save_iptables
    echo -e "${GREEN}[OK] ${name} настроен!${NC}"
    echo -e "  ${proto}: ${MY_IP:-*}:${in_port} → ${target_ip}:${out_port}"
}

configure_rule() {
    local proto="$1" name="$2"
    clear
    echo -e "\n${CYAN}━━━ Настройка ${name} (${proto}) ━━━${NC}\n"

    echo -e "${WHITE}Что нужно:${NC}"
    echo -e "  Этот сервер будет принимать ${proto}-трафик на указанный порт"
    echo -e "  и перенаправлять его на exit-ноду (зарубежный сервер)."
    echo ""
    echo -e "${WHITE}Пример для AmneziaWG:${NC}"
    echo -e "  Exit-нода IP: ${CYAN}85.192.26.32${NC}  (AMS сервер)"
    echo -e "  Порт: ${CYAN}51820${NC}  (стандартный WireGuard)"
    echo ""

    # IP с защитой от пустого ввода
    local target_ip=""
    while true; do
        echo -e "${WHITE}Введите IP адрес exit-ноды (зарубежного сервера):${NC}"
        echo -e "${CYAN}Формат: xxx.xxx.xxx.xxx${NC}"
        read -p "> " target_ip
        if [ -z "$target_ip" ]; then
            echo -e "${YELLOW}IP не введён. Нажмите Enter для возврата в меню или введите IP.${NC}"
            read -p "> " target_ip
            [ -z "$target_ip" ] && return
        fi
        validate_ip "$target_ip" && break
        echo -e "${RED}Некорректный IP. Попробуйте снова.${NC}\n"
    done

    # Порт с защитой от пустого ввода
    local port=""
    while true; do
        echo ""
        echo -e "${WHITE}Введите порт (одинаковый на этом сервере и на exit-ноде):${NC}"
        case "$name" in
            *WireGuard*|*AmneziaWG*) echo -e "${CYAN}Стандартный порт для WireGuard: 51820${NC}" ;;
            *VLESS*|*XRay*)         echo -e "${CYAN}Стандартный порт для VLESS: 443 или 8443${NC}" ;;
            *MTProto*)              echo -e "${CYAN}Стандартный порт для MTProto: 8443${NC}" ;;
        esac
        read -p "> " port
        if [ -z "$port" ]; then
            echo -e "${YELLOW}Порт не введён. Нажмите Enter для возврата в меню или введите порт.${NC}"
            read -p "> " port
            [ -z "$port" ] && return
        fi
        validate_port "$port" && break
        echo -e "${RED}Некорректный порт (1-65535). Попробуйте снова.${NC}\n"
    done

    probe_server_cli "$target_ip" "$port" || return
    echo -e "\n${YELLOW}Будет создано правило:${NC}"
    echo -e "  ${WHITE}Протокол:${NC} ${proto}"
    echo -e "  ${WHITE}Входящий:${NC} ${MY_IP:-*}:${port}  ${CYAN}(этот сервер)${NC}"
    echo -e "  ${WHITE}Исходящий:${NC} $(fmt_ip_short "$target_ip"):${port}  ${CYAN}(exit-нода)${NC}"
    echo ""
    read -p "Применить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    apply_iptables_rules "$proto" "$port" "$port" "$target_ip" "$name"
    read -p "Нажмите Enter..."
}

configure_custom_rule() {
    clear
    echo -e "\n${CYAN}━━━ Кастомное правило ━━━${NC}\n"
    echo -e "${WHITE}Используйте когда входящий и исходящий порты разные,${NC}"
    echo -e "${WHITE}или когда нужен нестандартный протокол (SSH, RDP и т.д.)${NC}\n"

    # Протокол
    local proto=""
    while true; do
        echo -e "${WHITE}Протокол:${NC}"
        echo -e "  ${CYAN}tcp${NC} — для VLESS, MTProto, SSH, HTTP, HTTPS"
        echo -e "  ${CYAN}udp${NC} — для WireGuard, AmneziaWG, DNS"
        read -p "> " proto
        if [ -z "$proto" ]; then
            echo -e "${YELLOW}Не введено. Enter ещё раз — выход в меню:${NC}"
            read -p "> " proto
            [ -z "$proto" ] && return
        fi
        [[ "$proto" == "tcp" || "$proto" == "udp" ]] && break
        echo -e "${RED}Введите tcp или udp.${NC}\n"
    done

    # IP
    local target_ip=""
    while true; do
        echo ""
        echo -e "${WHITE}IP адрес exit-ноды (зарубежного сервера):${NC}"
        read -p "> " target_ip
        if [ -z "$target_ip" ]; then
            echo -e "${YELLOW}Не введено. Enter ещё раз — выход в меню:${NC}"
            read -p "> " target_ip
            [ -z "$target_ip" ] && return
        fi
        validate_ip "$target_ip" && break
        echo -e "${RED}Некорректный IP. Попробуйте снова.${NC}"
    done

    # Входящий порт
    local in_port=""
    while true; do
        echo ""
        echo -e "${WHITE}ВХОДЯЩИЙ порт — на ЭТОМ сервере (клиент подключается сюда):${NC}"
        read -p "> " in_port
        if [ -z "$in_port" ]; then
            echo -e "${YELLOW}Не введено. Enter ещё раз — выход в меню:${NC}"
            read -p "> " in_port
            [ -z "$in_port" ] && return
        fi
        validate_port "$in_port" && break
        echo -e "${RED}Некорректный порт (1-65535).${NC}"
    done

    # Исходящий порт
    local out_port=""
    while true; do
        echo ""
        echo -e "${WHITE}ИСХОДЯЩИЙ порт — на exit-ноде ${target_ip} (куда пересылать):${NC}"
        read -p "> " out_port
        if [ -z "$out_port" ]; then
            echo -e "${YELLOW}Не введено. Enter ещё раз — выход в меню:${NC}"
            read -p "> " out_port
            [ -z "$out_port" ] && return
        fi
        validate_port "$out_port" && break
        echo -e "${RED}Некорректный порт (1-65535).${NC}"
    done

    probe_server_cli "$target_ip" "$out_port" || return
    echo -e "\n${YELLOW}Будет создано правило:${NC}"
    echo -e "  ${WHITE}Протокол:${NC} ${proto}"
    echo -e "  ${WHITE}Входящий:${NC}  ${MY_IP:-*}:${in_port}  ${CYAN}(этот сервер)${NC}"
    echo -e "  ${WHITE}Исходящий:${NC} $(fmt_ip_short "$target_ip"):${out_port}  ${CYAN}(exit-нода)${NC}"
    echo ""
    read -p "Применить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    apply_iptables_rules "$proto" "$in_port" "$out_port" "$target_ip" "Custom"
    read -p "Нажмите Enter..."
}

list_active_rules() {
    echo -e "\n${CYAN}━━━ Активные переадресации ━━━${NC}"
    echo -e "${WHITE}Сервер: ${GREEN}${MY_IP:-N/A}${NC}\n"
    local rules; rules=$(get_rules_list)
    if [ -z "$rules" ]; then
        echo -e "${YELLOW}Нет активных правил.${NC}"
    else
        while IFS='|' read -r proto port dest; do
            local dest_ip="${dest%:*}"
            echo -e "  ${WHITE}${MY_IP:-*}:${port}${NC} (${proto}) → ${GREEN}${dest}${NC} $(fmt_ip "$dest_ip")"
        done <<< "$rules"
    fi
    echo ""
    read -p "Нажмите Enter..."
}

delete_single_rule() {
    echo -e "\n${CYAN}━━━ Удаление правила ━━━${NC}"
    local -a rules_arr=()
    local i=1
    while IFS='|' read -r proto port dest; do
        rules_arr[$i]="${proto}|${port}|${dest}"
        echo -e "${YELLOW}[${i}]${NC} ${MY_IP:-*}:${port} (${proto}) → $(fmt_ip_short "${dest%:*}")"
        ((i++))
    done <<< "$(get_rules_list)"
    if [ ${#rules_arr[@]} -eq 0 ]; then
        echo -e "${YELLOW}Нет правил.${NC}"; read -p "Enter..."; return
    fi
    read -p "Номер (0 — отмена): " rn
    [[ "$rn" == "0" || -z "${rules_arr[$rn]:-}" ]] && return
    IFS='|' read -r dp dr dd <<< "${rules_arr[$rn]}"
    iptables -t nat -D PREROUTING -p "$dp" --dport "$dr" \
        -j DNAT --to-destination "$dd" 2>/dev/null
    for chain in INPUT FORWARD; do
        iptables -S "$chain" 2>/dev/null | grep "govpn:${dr}:${dp}" | \
            while read -r rule; do eval "iptables -D ${rule#-A }" 2>/dev/null; done
    done
    save_iptables
    log_action "DELETE rule: ${dp} :${dr} -> ${dd}"
    echo -e "${GREEN}[OK] Правило удалено.${NC}"
    read -p "Нажмите Enter..."
}

flush_rules() {
    echo -e "\n${RED}[!] Будут удалены ВСЕ правила govpn.${NC}"
    read -p "Уверены? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return
    while IFS='|' read -r proto port dest; do
        iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "$dest" 2>/dev/null
    done <<< "$(get_rules_list)"
    for chain in INPUT FORWARD; do
        while iptables -S "$chain" 2>/dev/null | grep -q "govpn"; do
            local rule; rule=$(iptables -S "$chain" | grep "govpn" | head -1)
            eval "iptables -D ${rule#-A }" 2>/dev/null
        done
    done
    save_iptables
    log_action "FLUSH all govpn rules"
    echo -e "${GREEN}[OK] Все правила сброшены.${NC}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  LIVE PING
# ═══════════════════════════════════════════════════════════════

make_ping_bar() {
    local ms_str="$1" width=25
    local ms_int
    ms_int=$(awk "BEGIN {printf \"%d\", $ms_str + 0.5}")
    local filled=$(( ms_int * width / 100 ))
    (( filled > width )) && filled=$width
    (( filled < 1 )) && filled=1
    local empty=$(( width - filled ))
    local color="$GREEN"
    (( ms_int > 50 )) && color="$YELLOW"
    (( ms_int > 100 )) && color="$RED"
    local bar="${color}"
    for (( b=0; b<filled; b++ )); do bar+="▓"; done
    bar+="${NC}"
    for (( b=0; b<empty; b++ )); do bar+="░"; done
    echo "$bar"
}

ping_live() {
    local ip="$1"
    local label; label=$(fmt_ip_short "$ip")
    local -a results=()
    local count=0 lost=0 running=1
    local _port; _port=$(get_port_for_ip "$ip")
    trap 'running=0' INT
    while [ "$running" -eq 1 ]; do
        local raw method="" ms=""
        raw=$(smart_ping "$ip" 3 "${_port:-}")
        if [ -n "$raw" ]; then method="${raw%%|*}"; ms="${raw#*|}"; fi
        ((count++))
        clear
        echo -e "${CYAN}━━━ Live Ping: ${WHITE}${label}${CYAN}  [Ctrl+C — стоп] ━━━${NC}"
        if [ -n "$ms" ]; then
            results+=("$ms")
            local bar; bar=$(make_ping_bar "$ms")
            printf "  ${GREEN}#%-4d %7sms${NC} ${CYAN}[%s]${NC} %b\n" "$count" "$ms" "$method" "$bar"
        else
            ((lost++))
            printf "  ${RED}#%-4d   TIMEOUT${NC}  " "$count"
            for (( b=0; b<25; b++ )); do echo -ne "${RED}█${NC}"; done
            echo ""
        fi
        if [ ${#results[@]} -gt 0 ]; then
            local stats
            stats=$(printf '%s\n' "${results[@]}" | \
                awk 'BEGIN{mn=999999;mx=0;s=0} {s+=$1;if($1<mn)mn=$1;if($1>mx)mx=$1} END{printf "%.2f|%.2f|%.2f",mn,mx,s/NR}')
            IFS='|' read -r s_min s_max s_avg <<< "$stats"
            echo -e "  ${WHITE}Мин: ${s_min}ms │ Макс: ${s_max}ms │ Сред: ${s_avg}ms${NC}"
        fi
        echo -e "  ${WHITE}Потеряно: ${lost}/${count}${NC}"
        sleep 1
    done
    trap - INT
    echo ""
    read -p "Нажмите Enter..."
}

ping_menu() {
    while true; do
        clear
        echo -e "\n${CYAN}━━━ Ping & Мониторинг ━━━${NC}\n"

        # Показываем текущий статус всех серверов
        local -a ips=()
        while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"

        if [ ${#ips[@]} -gt 0 ]; then
            echo -e "${WHITE}Серверы в правилах:${NC}"
            for ip in "${ips[@]}"; do
                local raw; raw=$(smart_ping "$ip" 2 "$(get_port_for_ip "$ip")")
                if [ -n "$raw" ]; then
                    local ms; ms="${raw#*|}"
                    local method; method="${raw%%|*}"
                    local color="$GREEN"
                    local ms_int; ms_int=$(awk "BEGIN{printf \"%d\",$ms+0.5}")
                    (( ms_int > 50 )) && color="$YELLOW"
                    (( ms_int > 100 )) && color="$RED"
                    echo -e "  ${color}●${NC} $(fmt_ip_short "$ip")  ${color}${ms}ms${NC} ${WHITE}[${method}]${NC}"
                else
                    echo -e "  ${RED}●${NC} $(fmt_ip_short "$ip")  ${RED}TIMEOUT${NC}"
                fi
            done
            echo ""
        fi

        # Статус мониторинга
        local mon_status="${RED}Выключен${NC}"
        if [ -f "$MONITOR_PID_FILE" ] && kill -0 "$(cat "$MONITOR_PID_FILE" 2>/dev/null)" 2>/dev/null; then
            local mon_interval; mon_interval=$(cat "${CONF_DIR}/monitor_interval" 2>/dev/null || echo "60")
            mon_status="${GREEN}Работает (каждые ${mon_interval}с)${NC}"
        fi
        echo -e "${WHITE}Автомониторинг: ${mon_status}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC} Live ping (выбрать сервер)"
        echo -e "  ${YELLOW}[2]${NC} Проверить все серверы сейчас"
        echo -e "  ${GREEN}[3]${NC} Включить автомониторинг"
        echo -e "  ${RED}[4]${NC} Выключить автомониторинг"
        echo -e "  ${YELLOW}[5]${NC} Показать лог мониторинга"
        echo -e "  ${YELLOW}[0]${NC} Назад"
        echo ""
        read -p "Выбор: " choice
        case "$choice" in
            1)
                if [ ${#ips[@]} -eq 0 ]; then
                    echo -e "${YELLOW}Нет серверов. Введите IP:${NC}"
                    read -p "> " manual_ip
                    validate_ip "$manual_ip" && ping_live "$manual_ip"
                else
                    echo -e "\nСерверы:"
                    for i in "${!ips[@]}"; do
                        echo -e "  ${YELLOW}[$((i+1))]${NC} $(fmt_ip "${ips[$i]}")"
                    done
                    echo -e "  ${YELLOW}[m]${NC} Ввести IP вручную"
                    read -p "Выбор: " pc
                    case "$pc" in
                        m|M)
                            read -p "IP: " manual_ip
                            validate_ip "$manual_ip" && ping_live "$manual_ip"
                            ;;
                        *)
                            local idx=$((pc - 1))
                            [ -n "${ips[$idx]:-}" ] && ping_live "${ips[$idx]}"
                            ;;
                    esac
                fi
                ;;
            2)
                echo -e "\n${CYAN}Проверка всех серверов...${NC}\n"
                if [ ${#ips[@]} -eq 0 ]; then
                    echo -e "${YELLOW}Нет серверов в правилах.${NC}"
                else
                    for ip in "${ips[@]}"; do
                        local raw; raw=$(smart_ping "$ip" 3 "$(get_port_for_ip "$ip")")
                        if [ -n "$raw" ]; then
                            local ms="${raw#*|}"; local method="${raw%%|*}"
                            echo -e "  ${GREEN}✓${NC} $(fmt_ip_short "$ip")  ${GREEN}${ms}ms${NC} [${method}]"
                        else
                            echo -e "  ${RED}✗${NC} $(fmt_ip_short "$ip")  ${RED}НЕДОСТУПЕН${NC}"
                            log_action "MONITOR CHECK: ${ip} TIMEOUT"
                        fi
                    done
                fi
                echo ""
                read -p "Нажмите Enter..."
                ;;
            3)
                _start_monitor
                ;;
            4)
                _stop_monitor
                read -p "Нажмите Enter..."
                ;;
            5)
                clear
                echo -e "${CYAN}━━━ Лог мониторинга (последние 30 строк) ━━━${NC}\n"
                grep "MONITOR" "$LOG_FILE" 2>/dev/null | tail -30 || \
                    echo -e "${YELLOW}Лог пуст.${NC}"
                echo ""
                read -p "Нажмите Enter..."
                ;;
            0|"") return ;;
        esac
    done
}

_start_monitor() {
    clear
    echo -e "\n${CYAN}━━━ Настройка автомониторинга ━━━${NC}\n"

    local -a ips=()
    while read -r ip; do [ -n "$ip" ] && ips+=("$ip"); done <<< "$(get_target_ips)"
    if [ ${#ips[@]} -eq 0 ]; then
        echo -e "${YELLOW}Нет серверов в правилах iptables.${NC}"
        echo -e "${WHITE}Сначала добавьте правило (п.1-4).${NC}"
        read -p "Нажмите Enter..."; return
    fi

    echo -e "${WHITE}Серверы для мониторинга:${NC}"
    for ip in "${ips[@]}"; do echo -e "  ${CYAN}•${NC} $(fmt_ip_short "$ip")"; done
    echo ""

    echo -e "${WHITE}Интервал проверки:${NC}"
    echo -e "  ${YELLOW}[1]${NC} 30 секунд"
    echo -e "  ${YELLOW}[2]${NC} 1 минута ${WHITE}(рекомендуется)${NC}"
    echo -e "  ${YELLOW}[3]${NC} 5 минут"
    echo -e "  ${YELLOW}[4]${NC} Свой интервал"
    read -p "Выбор [2]: " int_ch
    local interval=60
    case "${int_ch:-2}" in
        1) interval=30 ;;
        2) interval=60 ;;
        3) interval=300 ;;
        4)
            read -p "Интервал в секундах: " interval
            [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 10 )) && interval=60
            ;;
    esac

    # Остановить старый если был
    _stop_monitor_silent

    # Записать интервал
    echo "$interval" > "${CONF_DIR}/monitor_interval"

    # Запустить daemon в фоне
    _monitor_daemon "$interval" &
    local pid=$!
    echo "$pid" > "$MONITOR_PID_FILE"
    disown "$pid"

    echo -e "${GREEN}[OK] Автомониторинг запущен (PID: ${pid}, интервал: ${interval}с)${NC}"
    echo -e "${WHITE}Серверы проверяются каждые ${interval} секунд.${NC}"
    echo -e "${WHITE}Результаты: ${CYAN}${LOG_FILE}${NC} (фильтр: MONITOR)${NC}"
    log_action "MONITOR START: interval=${interval}s, servers=${ips[*]}"
    read -p "Нажмите Enter..."
}

_stop_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid; pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            echo -e "${GREEN}[OK] Автомониторинг остановлен (PID: ${pid}).${NC}"
            log_action "MONITOR STOP"
        else
            echo -e "${YELLOW}Процесс не найден (уже остановлен?).${NC}"
        fi
        rm -f "$MONITOR_PID_FILE"
    else
        echo -e "${YELLOW}Мониторинг не запущен.${NC}"
    fi
}

_stop_monitor_silent() {
    [ -f "$MONITOR_PID_FILE" ] && \
        kill "$(cat "$MONITOR_PID_FILE" 2>/dev/null)" 2>/dev/null && \
        rm -f "$MONITOR_PID_FILE"
    true
}

_monitor_daemon() {
    local interval="${1:-60}"
    # Daemon loop — работает в фоне
    while true; do
        sleep "$interval"
        # Получаем актуальный список серверов из iptables
        local ips_now
        ips_now=$(iptables -t nat -S PREROUTING 2>/dev/null | \
            grep "DNAT" | grep "govpn" | \
            sed -n 's/.*--to-destination \([^:]*\).*/\1/p' | sort -u)
        [ -z "$ips_now" ] && continue
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            local port
            port=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "govpn" | \
                grep "$ip" | sed -n 's/.*--to-destination [^:]*:\([0-9]*\).*/\1/p' | head -1)
            local raw; raw=$(smart_ping "$ip" 3 "$port")
            if [ -n "$raw" ]; then
                local ms="${raw#*|}"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR OK: ${ip} ${ms}ms" >> "$LOG_FILE"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] MONITOR TIMEOUT: ${ip} — сервер не отвечает" >> "$LOG_FILE"
            fi
        done <<< "$ips_now"
    done
}

# ═══════════════════════════════════════════════════════════════
#  SYSTEM STATS
# ═══════════════════════════════════════════════════════════════

show_system_stats() {
    clear
    echo -e "\n${CYAN}━━━ Системная информация ━━━${NC}\n"
    local cpu_count load_avg mem_info disk_info uptime_str cpu_usage
    cpu_count=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
    load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
    mem_info=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB (%.1f%%)", $3, $2, $3/$2*100}')
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    uptime_str=$(uptime -p 2>/dev/null || uptime | sed 's/.*up //; s/,.*load.*//')
    cpu_usage=$(awk '/^cpu / {u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; if(t>0) printf "%.1f%%", u/t*100}' /proc/stat 2>/dev/null)

    echo -e "  ${WHITE}Uptime:  ${GREEN}${uptime_str}${NC}"
    echo -e "  ${WHITE}CPU:     ${GREEN}${cpu_count} ядер | ${cpu_usage}${NC}"
    echo -e "  ${WHITE}Load:    ${GREEN}${load_avg}${NC}"
    echo -e "  ${WHITE}RAM:     ${GREEN}${mem_info}${NC}"
    echo -e "  ${WHITE}Диск /:  ${GREEN}${disk_info}${NC}"
    echo -e "  ${WHITE}IP:      ${GREEN}${MY_IP}${NC}"
    echo -e "  ${WHITE}Iface:   ${GREEN}${IFACE}${NC}"
    echo ""

    # Топ процессы по CPU
    echo -e "${CYAN}━━━ Топ процессы (CPU) ━━━${NC}"
    ps aux --sort=-%cpu 2>/dev/null | head -6 | tail -5 | \
        awk '{printf "  %-20s CPU: %s%%  MEM: %s%%\n", $11, $3, $4}'
    echo ""
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  AMNEZIA WG — роутер
# ═══════════════════════════════════════════════════════════════

show_amnezia_router() {
    clear
    echo -e "\n${CYAN}━━━ AmneziaWG на роутер (OpenWrt / Keenetic) ━━━${NC}\n"
    echo -e "${WHITE}Требования:${NC}"
    echo -e "  • Роутер с OpenWrt и entware, или Keenetic с OPKG"
    echo -e "  • SSH доступ к роутеру"
    echo -e "  • Роутер имеет доступ в интернет"
    echo ""
    echo -e "${CYAN}Команда для выполнения на роутере через SSH:${NC}\n"

    local CMD='opkg update && opkg install wget-ssl ca-bundle curl && mkdir -p /opt/etc/opkg/ && opkg update && wget -qO- https://raw.githubusercontent.com/hoaxisr/awg-manager/main/scripts/install.sh | sh'

    echo -e "${GREEN}${CMD}${NC}"
    echo ""
    echo -e "${YELLOW}Шаги:${NC}"
    echo -e "  1. Подключитесь к роутеру: ${WHITE}ssh root@192.168.1.1${NC}"
    echo -e "  2. Выполните команду выше"
    echo -e "  3. После установки: ${WHITE}awg-manager${NC}"
    echo ""
    echo -e "${CYAN}Что это даёт:${NC}"
    echo -e "  • AmneziaWG (обфусцированный WireGuard) на роутере"
    echo -e "  • Весь трафик сети через VPN без настройки каждого устройства"
    echo -e "  • Обход DPI — AmneziaWG добавляет мусорные пакеты к handshake"
    echo ""
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  ПОЛНОЕ УДАЛЕНИЕ
# ═══════════════════════════════════════════════════════════════

full_uninstall() {
    clear
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║            ⚠  ПОЛНОЕ УДАЛЕНИЕ GoVPN Manager  ⚠             ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Будут удалены:${NC}"
    echo -e "  ${RED}•${NC} Все правила iptables (govpn)"
    echo -e "  ${RED}•${NC} Конфигурация ${WHITE}${CONF_DIR}/${NC}"
    echo -e "  ${RED}•${NC} Команда ${WHITE}${INSTALL_PATH}${NC}"
    echo -e "  ${RED}•${NC} Логи ${WHITE}${LOG_FILE}${NC}"
    echo ""
    echo -e "${GREEN}НЕ будет затронуто:${NC}"
    echo -e "  ${GREEN}•${NC} WARP (управляйте через п.8-14 или удалите отдельно п.14)"
    echo -e "  ${GREEN}•${NC} 3X-UI / xray (outbound 'warp' останется — удалите вручную)"
    echo -e "  ${GREEN}•${NC} Системные пакеты, sysctl, BBR"
    echo ""
    read -p "$(echo -e "${RED}Удалить GoVPN Manager? (y/n): ${NC}")" c1
    [[ "$c1" != "y" ]] && echo -e "${CYAN}Отменено.${NC}" && read -p "Enter..." && return

    local words=("УДАЛИТЬ" "СТЕРЕТЬ" "СНЕСТИ" "ПРОЩАЙ" "CONFIRM")
    local word="${words[$((RANDOM % ${#words[@]}))]}"
    echo -e "\n${RED}Введите слово ${WHITE}${word}${RED} для подтверждения:${NC}"
    read -p "> " c2
    if [[ "$c2" != "$word" ]]; then
        echo -e "${CYAN}Неверное слово. Отменено.${NC}"
        read -p "Enter..."; return
    fi

    echo ""
    echo -e "${YELLOW}Удаление...${NC}\n"

    # Остановить мониторинг
    _stop_monitor_silent
    echo -e "  ${GREEN}✓${NC}  Мониторинг остановлен"

    # Правила iptables
    while IFS='|' read -r proto port dest; do
        iptables -t nat -D PREROUTING -p "$proto" --dport "$port" \
            -j DNAT --to-destination "$dest" 2>/dev/null
    done <<< "$(get_rules_list)"
    for chain in INPUT FORWARD; do
        while iptables -S "$chain" 2>/dev/null | grep -q "govpn"; do
            local rule; rule=$(iptables -S "$chain" | grep "govpn" | head -1)
            eval "iptables -D ${rule#-A }" 2>/dev/null
        done
    done
    save_iptables
    echo -e "  ${GREEN}✓${NC}  Правила iptables удалены"

    rm -rf "$CONF_DIR"
    echo -e "  ${GREEN}✓${NC}  Конфигурация удалена"

    rm -f "$LOG_FILE"
    echo -e "  ${GREEN}✓${NC}  Логи удалены"

    rm -f "$INSTALL_PATH"
    echo -e "  ${GREEN}✓${NC}  Команда ${SCRIPT_NAME} удалена"

    echo ""
    echo -e "${GREEN}GoVPN Manager удалён.${NC}"
    echo -e "${WHITE}WARP и xray outbound удалите отдельно если нужно.${NC}"
    echo ""
    exit 0
}

# ═══════════════════════════════════════════════════════════════
#  SELF-UPDATE
# ═══════════════════════════════════════════════════════════════

self_update() {
    # Место для URL своего репозитория
    local REPO_URL="${GOVPN_REPO_URL:-}"
    if [ -z "$REPO_URL" ]; then
        echo -e "\n${YELLOW}URL репозитория не задан.${NC}"
        echo -e "Установите переменную ${WHITE}GOVPN_REPO_URL${NC} или укажите URL:"
        read -p "> " REPO_URL
        [ -z "$REPO_URL" ] && return
    fi

    echo -e "${YELLOW}[*] Загрузка обновления из ${REPO_URL}...${NC}"
    local tmp="/tmp/${SCRIPT_NAME}_update.sh"
    curl -fsSL "$REPO_URL" -o "$tmp" 2>/dev/null

    if [ ! -f "$tmp" ] || ! head -1 "$tmp" 2>/dev/null | grep -q "#!/bin/bash"; then
        echo -e "${RED}[ERROR] Не удалось загрузить или файл некорректен.${NC}"
        rm -f "$tmp"
        read -p "Нажмите Enter..."; return
    fi

    # Бэкап текущей версии
    local bak="${BACKUP_DIR}/${SCRIPT_NAME}.sh.bak.$(date +%s)"
    cp "$INSTALL_PATH" "$bak" 2>/dev/null
    echo -e "${GREEN}[✓] Бэкап текущей версии: ${bak}${NC}"

    cp -f "$tmp" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    rm -f "$tmp"

    echo -e "${GREEN}[OK] Обновлён! Перезапустите: ${SCRIPT_NAME}${NC}"
    log_action "SELF-UPDATE from ${REPO_URL}"
    read -p "Нажмите Enter..."
    exit 0
}

warp_test() {
    clear
    echo -e "\n${CYAN}━━━ Тест WARP ━━━${NC}\n"
    echo -e "${WHITE}Проверяем каждый компонент по порядку...${NC}\n"

    local all_ok=1

    # 1. Демон запущен?
    echo -ne "  ${WHITE}[1/6]${NC} warp-svc демон...         "
    if systemctl is-active warp-svc &>/dev/null; then
        echo -e "${GREEN}✓ запущен${NC}"
    else
        echo -e "${RED}✗ не запущен${NC}"
        echo -e "        ${WHITE}Исправление: ${CYAN}systemctl start warp-svc${NC}"
        all_ok=0
    fi

    # 2. Регистрация есть?
    echo -ne "  ${WHITE}[2/6]${NC} Регистрация аккаунта...   "
    local st; st=$(warp-cli --accept-tos status 2>/dev/null)
    if echo "$st" | grep -qi "registration missing"; then
        echo -e "${RED}✗ нет регистрации${NC}"
        echo -e "        ${WHITE}Исправление: п.8r (авторемонт)${NC}"
        all_ok=0
    else
        echo -e "${GREEN}✓ есть${NC}"
    fi

    # 3. Подключён?
    echo -ne "  ${WHITE}[3/6]${NC} Статус подключения...     "
    if is_warp_running; then
        echo -e "${GREEN}✓ Connected${NC}"
    else
        local reason; reason=$(echo "$st" | grep -i "reason\|status" | head -1)
        echo -e "${RED}✗ не подключён${NC}"
        [ -n "$reason" ] && echo -e "        ${YELLOW}${reason}${NC}"
        echo -e "        ${WHITE}Исправление: п.10 или п.8r${NC}"
        all_ok=0
    fi

    # 4. Режим proxy?
    echo -ne "  ${WHITE}[4/6]${NC} Режим WarpProxy...        "
    local mode; mode=$(warp-cli --accept-tos settings 2>/dev/null | grep -i "mode:" | head -1)
    if echo "$mode" | grep -qi "warpproxy\|proxy"; then
        local port; port=$(echo "$mode" | grep -oE 'port [0-9]+' | grep -oE '[0-9]+')
        echo -e "${GREEN}✓ proxy на порту ${port:-${WARP_SOCKS_PORT}}${NC}"
    else
        echo -e "${RED}✗ неверный режим${NC}"
        echo -e "        ${YELLOW}${mode}${NC}"
        echo -e "        ${WHITE}Исправление: ${CYAN}warp-cli --accept-tos mode proxy${NC}"
        all_ok=0
    fi

    # 5. Порт слушает?
    echo -ne "  ${WHITE}[5/6]${NC} SOCKS5 порт ${WARP_SOCKS_PORT}...        "
    if ss -tlnp 2>/dev/null | grep -q ":${WARP_SOCKS_PORT} "; then
        echo -e "${GREEN}✓ слушает${NC}"
    else
        echo -e "${RED}✗ порт не открыт${NC}"
        echo -e "        ${WHITE}Исправление: ${CYAN}warp-cli --accept-tos proxy port ${WARP_SOCKS_PORT}${NC}"
        all_ok=0
    fi

    # 6. Реальный тест — запрос через SOCKS5
    echo -ne "  ${WHITE}[6/6]${NC} HTTP запрос через WARP... "
    local direct_ip warp_ip
    direct_ip=$(curl -s4 --max-time 5 https://api4.ipify.org 2>/dev/null | tr -d '[:space:]')
    warp_ip=$(curl -s4 --max-time 8 \
        --proxy "socks5://127.0.0.1:${WARP_SOCKS_PORT}" \
        https://api4.ipify.org 2>/dev/null | tr -d '[:space:]')

    if [[ "$warp_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        if [ "$warp_ip" = "$direct_ip" ]; then
            echo -e "${YELLOW}⚠ IP не изменился${NC}"
            echo -e "        ${WHITE}Прямой IP:  ${direct_ip}${NC}"
            echo -e "        ${WHITE}WARP IP:    ${warp_ip}${NC}"
            echo -e "        ${YELLOW}WARP проксирует трафик, но выходной IP совпадает.${NC}"
            echo -e "        ${WHITE}Это может быть нормально если сервер уже в сети Cloudflare.${NC}"
        else
            echo -e "${GREEN}✓ IP изменился${NC}"
            echo -e "        ${WHITE}Прямой IP:  ${WHITE}${direct_ip}${NC}"
            echo -e "        ${WHITE}WARP IP:    ${GREEN}${warp_ip}${NC} ${CYAN}(Cloudflare)${NC}"
        fi
    else
        echo -e "${RED}✗ нет ответа через SOCKS5${NC}"
        echo -e "        ${WHITE}curl не смог получить IP через socks5://127.0.0.1:${WARP_SOCKS_PORT}${NC}"
        all_ok=0
    fi

    # Итог
    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$all_ok" -eq 1 ]; then
        echo -e "  ${GREEN}✅ WARP работает корректно!${NC}"
        echo ""
        echo -e "  ${WHITE}Прямой IP сервера:  ${direct_ip}${NC}"
        echo -e "  ${WHITE}IP через WARP:      ${GREEN}${warp_ip}${NC}"
        echo ""
        echo -e "  ${CYAN}Как использовать:${NC}"
        echo -e "  Настройте приложение на использование SOCKS5 прокси:"
        echo -e "  ${WHITE}socks5://127.0.0.1:${WARP_SOCKS_PORT}${NC}"
        echo -e "  Или добавьте как outbound в xray (п.16) — тогда весь"
        echo -e "  трафик клиентов будет выходить через Cloudflare."
    else
        echo -e "  ${RED}❌ Найдены проблемы — следуйте инструкциям выше.${NC}"
        echo -e "  ${WHITE}Быстрое исправление: п.8r (авторемонт)${NC}"
    fi
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log_action "WARP TEST: direct=${direct_ip} warp=${warp_ip} ok=${all_ok}"
    read -p "Нажмите Enter..."
}

# ═══════════════════════════════════════════════════════════════
#  MAIN MENU
# ═══════════════════════════════════════════════════════════════

show_menu() {
    while true; do
        clear
        local warp_st warp_color
        warp_st=$(get_warp_status_text)
        warp_color="$RED"
        [[ "$warp_st" == "Подключён" ]] && warp_color="$GREEN"
        [[ "$warp_st" == "Отключён" ]] && warp_color="$YELLOW"

        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        echo -e "${WHITE}  GoVPN Manager v${VERSION}${NC}"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        echo -e "  ${WHITE}IP:    ${GREEN}${MY_IP}${NC}   ${WHITE}Iface: ${CYAN}${IFACE}${NC}"
        if is_warp_running; then
            local _wip; _wip=$(get_warp_ip)
            echo -e "  ${WHITE}WARP:  ${warp_color}${warp_st}${NC}   ${WHITE}CF IP: ${GREEN}${_wip}${NC}   ${WHITE}SOCKS5: ${CYAN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
        else
            echo -e "  ${WHITE}WARP:  ${warp_color}${warp_st}${NC}   ${WHITE}SOCKS5: ${CYAN}127.0.0.1:${WARP_SOCKS_PORT}${NC}"
        fi
        echo -e "${MAGENTA}──────────────────────────────────────────────${NC}"
        echo -e " ${CYAN}── IPTABLES ПРОБРОС ─────────────────${NC}"
        echo -e "  1)  AmneziaWG / WireGuard  ${WHITE}(UDP)${NC}"
        echo -e "  2)  VLESS / XRay           ${WHITE}(TCP)${NC}"
        echo -e "  3)  MTProto / TProxy       ${WHITE}(TCP)${NC}"
        echo -e "  4)  Кастомное правило"
        echo -e "  5)  Список правил"
        echo -e "  6)  Удалить правило"
        echo -e "  7)  ${RED}Сбросить все правила${NC}"
        echo -e " ${CYAN}── WARP ─────────────────────────────${NC}"
        echo -e "  8)  Установить WARP"
        echo -e "  8r) ${YELLOW}Авторемонт WARP${NC}"
        echo -e "  8p) ${RED}Чистая переустановка WARP${NC}"
        echo -e "  9)  Статус WARP"
        echo -e " 10)  Запустить WARP"
        echo -e " 11)  Остановить WARP"
        echo -e " 12)  Перевыпустить ключ"
        echo -e " 13)  Изменить порт SOCKS5"
        echo -e " 14)  ${RED}Удалить WARP${NC}"
        echo -e " ${CYAN}── 3X-UI / XRAY ─────────────────────${NC}"
        echo -e " 15)  JSON для ручного добавления"
        echo -e " 16)  ${GREEN}Применить в config.json (авто)${NC}"
        echo -e " 17)  Бэкапы и Rollback"
        echo -e " ${CYAN}── ИНСТРУМЕНТЫ ──────────────────────${NC}"
        echo -e " 18)  Ping (live)"
        echo -e " 19)  Системная статистика"
        echo -e " 20)  Имена серверов"
        echo -e " 25)  ${GREEN}Тест WARP (проверить что работает)${NC}"
        echo -e " ${CYAN}── РОУТЕР ───────────────────────────${NC}"
        echo -e " 21)  AmneziaWG на OpenWrt / Keenetic"
        echo -e " ${CYAN}── СИСТЕМА ──────────────────────────${NC}"
        echo -e " 22)  Проверка конфликтов"
        echo -e " 23)  Обновить скрипт"
        echo -e " 24)  ${RED}Полное удаление${NC}"
        echo -e "  0)  Выход"
        echo -e "${MAGENTA}══════════════════════════════════════════════${NC}"
        read -p "Выбор: " ch
        case $ch in
            1)  configure_rule "udp" "AmneziaWG/WireGuard" ;;
            2)  configure_rule "tcp" "VLESS/XRay" ;;
            3)  configure_rule "tcp" "MTProto/TProxy" ;;
            4)  configure_custom_rule ;;
            5)  list_active_rules ;;
            6)  delete_single_rule ;;
            7)  flush_rules ;;
            8)  install_warp ;;
            8r) _warp_autorepair; read -p "Нажмите Enter..." ;;
            8p) reinstall_warp ;;
            9)  show_warp_status ;;
            10) start_warp ;;
            11) stop_warp ;;
            12) rekey_warp ;;
            13) change_warp_port ;;
            14) uninstall_warp ;;
            15) show_xray_json ;;
            16) apply_xray_warp ;;
            17) show_backups ;;
            18) ping_menu ;;
            19) show_system_stats ;;
            20) manage_aliases_menu ;;
            21) show_amnezia_router ;;
            22) check_conflicts ;;
            23) self_update ;;
            24) full_uninstall ;;
            25) warp_test ;;
            0)  clear; exit 0 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════
#  STARTUP
# ═══════════════════════════════════════════════════════════════

run_startup() {
    local total=6 s=0

    clear; echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║              GoVPN Manager v${VERSION} — Загрузка                      ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Проверка прав root..." "$s" "$total"
    check_root
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Права root                          \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Загрузка конфигурации..." "$s" "$total"
    init_config
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Конфигурация загружена               \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка зависимостей..." "$s" "$total"
    check_deps
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Зависимости на месте                 \n" "$s" "$total"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Сеть (интерфейс + BBR)..." "$s" "$total"
    detect_interface
    prepare_system
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Iface: %-20s         \n" "$s" "$total" "$IFACE"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Внешний IP..." "$s" "$total"
    get_my_ip
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   IP: %-25s            \n" "$s" "$total" "$MY_IP"

    ((s++))
    printf "  ${CYAN}[%d/%d]${NC}  ${YELLOW}⏳${NC}  Установка команды ${SCRIPT_NAME}..." "$s" "$total"
    if [ "$(readlink -f "$0" 2>/dev/null)" != "$INSTALL_PATH" ]; then
        cp -f "$0" "$INSTALL_PATH"; chmod +x "$INSTALL_PATH"
    fi
    printf "\r  ${CYAN}[%d/%d]${NC}  ${GREEN}✓${NC}   Команда: ${SCRIPT_NAME}                     \n" "$s" "$total"

    echo ""
    local bar=""
    for ((i=0; i<40; i++)); do bar+="█"; done
    echo -e "  ${CYAN}[${GREEN}${bar}${CYAN}]${NC} ${GREEN}100%${NC}"
    echo ""
    echo -e "  ${GREEN}✅  GoVPN Manager v${VERSION} готов!${NC}"
    echo ""
    sleep 1
    show_menu
}

# ═══════════════════════════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════════════════════════

case "${1:-}" in
    rollback)
        init_config
        check_root
        if [ -z "${2:-}" ]; then
            echo "Usage: ${SCRIPT_NAME} rollback <path_to_backup>"
            exit 1
        fi
        rollback_xray_config "$2"
        ;;
    --monitor-daemon)
        init_config
        interval=$(cat "${CONF_DIR}/monitor_interval" 2>/dev/null || echo "60")
        _monitor_daemon "$interval"
        ;;
    *)
        run_startup
        ;;
esac
