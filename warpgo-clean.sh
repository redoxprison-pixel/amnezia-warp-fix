#!/usr/bin/env bash

set -Eeuo pipefail

APP_NAME="WARP Manager"
APP_VERSION="2.1.4"
INSTALL_BIN="/usr/local/bin/warpgo"
CONFIG_DIR="/etc/warp-manager"
CONFIG_FILE="$CONFIG_DIR/config"
LOG_FILE="/var/log/warp-manager.log"
DEBUG_FILE="/var/log/warp-manager-debug.log"
DEFAULT_PORT=40000
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/refs/heads/main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SOCKS_PORT="$DEFAULT_PORT"
MY_IP="N/A"

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

log_action() {
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$(date '+%F %T')] $*" >>"$LOG_FILE"
}

log_debug() {
    mkdir -p "$(dirname "$DEBUG_FILE")"
    echo "[$(date '+%F %T')] $*" >>"$DEBUG_FILE"
}

run_warp() {
    warp-cli --accept-tos "$@" 2>/dev/null
}

capture_cmd() {
    "$@" 2>&1 || true
}

init_config() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_FILE" ]; then
        cat >"$CONFIG_FILE" <<EOF
SOCKS_PORT="${DEFAULT_PORT}"
EOF
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    SOCKS_PORT="${SOCKS_PORT:-$DEFAULT_PORT}"
}

save_config_val() {
    local key="$1" value="$2"
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$CONFIG_FILE"
    else
        echo "${key}=\"${value}\"" >>"$CONFIG_FILE"
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

get_my_ip() {
    MY_IP="$(curl -4fsS --max-time 5 https://ifconfig.co 2>/dev/null || echo "N/A")"
}

get_warp_ip() {
    curl -4fsS --max-time 8 --proxy "socks5h://127.0.0.1:${SOCKS_PORT}" https://ifconfig.co 2>/dev/null || echo "N/A"
}

is_warp_installed() {
    command -v warp-cli >/dev/null 2>&1
}

is_warp_running() {
    local st
    st="$(run_warp status || true)"
    echo "$st" | grep -qi "connected" && ! echo "$st" | grep -qi "disconnected"
}

proxy_listening() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$SOCKS_PORT$"
}

get_warp_status_text() {
    if ! is_warp_installed; then
        echo "Не установлен"
        return
    fi

    local status
    status="$(run_warp status || true)"
    if echo "$status" | grep -qi "registration missing"; then
        echo "Нет регистрации"
    elif echo "$status" | grep -qi "connected"; then
        echo "Подключён"
    elif echo "$status" | grep -qi "disconnected"; then
        echo "Отключён"
    else
        echo "Неизвестно"
    fi
}

registration_missing() {
    local status
    status="$(run_warp status || true)"
    echo "$status" | grep -qi "registration missing"
}

daemon_starting() {
    local status
    status="$(run_warp status || true)"
    echo "$status" | grep -qi "daemon startup"
}

wait_for_registration_ready() {
    local attempts="${1:-15}"
    while [ "$attempts" -gt 0 ]; do
        if ! registration_missing; then
            return 0
        fi
        sleep 2
        attempts=$((attempts - 1))
    done
    return 1
}

proxy_port_cmd() {
    run_warp set-proxy-port "$SOCKS_PORT" || run_warp proxy port "$SOCKS_PORT"
}

restart_warp_daemon() {
    systemctl stop warp-svc >/dev/null 2>&1 || true
    rm -f /run/cloudflare-warp/warp_service_ipc
    systemctl start warp-svc >/dev/null 2>&1 || true
    sleep 3
}

reset_warp_registration_state() {
    rm -f /var/lib/cloudflare-warp/reg.json
    rm -f /var/lib/cloudflare-warp/settings.json
    rm -f /run/cloudflare-warp/warp_service_ipc
}

show_warp_diagnostics() {
    local status_text service_text journal_text
    status_text="$(capture_cmd warp-cli --accept-tos status)"
    service_text="$(capture_cmd systemctl status warp-svc --no-pager)"
    journal_text="$(capture_cmd journalctl -u warp-svc -n 40 --no-pager)"

    log_debug "warp-cli status:"
    log_debug "$status_text"
    log_debug "systemctl status warp-svc:"
    log_debug "$service_text"
    log_debug "journalctl -u warp-svc -n 40:"
    log_debug "$journal_text"

    echo ""
    echo -e "${RED}Диагностика регистрации WARP:${NC}"
    echo -e "${CYAN}--- warp-cli status ---${NC}"
    echo "$status_text"
    echo -e "${CYAN}--- systemctl status warp-svc ---${NC}"
    echo "$service_text" | tail -n 20
    echo -e "${CYAN}--- journalctl -u warp-svc ---${NC}"
    echo "$journal_text" | tail -n 20
    echo ""
    echo -e "${YELLOW}Полный debug log:${NC} ${WHITE}${DEBUG_FILE}${NC}"
}

ensure_warp_service() {
    systemctl enable --now warp-svc >/dev/null 2>&1 || true
    sleep 2
    if ! systemctl is-active --quiet warp-svc; then
        restart_warp_daemon
    fi
}

ensure_warp_registration() {
    if ! registration_missing; then
        return 0
    fi

    ensure_warp_service
    run_warp disconnect || true

    run_warp registration new || true
    if wait_for_registration_ready 20; then
        return 0
    fi

    restart_warp_daemon
    run_warp registration new || true
    if wait_for_registration_ready 20; then
        return 0
    fi

    reset_warp_registration_state
    restart_warp_daemon
    run_warp registration new || true
    if wait_for_registration_ready 20; then
        return 0
    fi

    show_warp_diagnostics
    return 1
}

configure_warp_proxy() {
    run_warp mode proxy || die "failed to switch WARP to proxy mode"
    proxy_port_cmd || die "failed to set SOCKS5 port"
}

connect_warp() {
    ensure_warp_service
    ensure_warp_registration || die "failed to register WARP"
    configure_warp_proxy
    run_warp connect || die "failed to connect WARP"
    sleep 3
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_CODENAME=""
    fi
}

check_deps() {
    local missing=()
    for cmd in curl gpg ss sed awk grep; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl ca-certificates gnupg iproute2 procps >/dev/null 2>&1
    fi
}

install_self() {
    if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_BIN" ]; then
        install -m 755 "$0" "$INSTALL_BIN"
    fi
}

install_warp() {
    clear
    echo -e "\n${CYAN}━━━ Установка Cloudflare WARP ━━━${NC}\n"

    detect_os
    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        echo -e "${RED}Поддерживаются только Debian/Ubuntu.${NC}"
        echo -e "${WHITE}Текущая ОС: ${YELLOW}${OS_ID} ${OS_VERSION}${NC}"
        read -r -p "Нажмите Enter..."
        return
    fi

    echo -e "${YELLOW}[1/5]${NC} Установка зависимостей..."
    check_deps

    echo -e "${YELLOW}[2/5]${NC} Установка пакета cloudflare-warp..."
    if ! is_warp_installed; then
        install -d -m 755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        local codename="$OS_CODENAME"
        if [ -z "$codename" ]; then
            codename="$(lsb_release -cs 2>/dev/null || echo "bookworm")"
        fi
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" >/etc/apt/sources.list.d/cloudflare-client.list
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1
        apt-get install -y cloudflare-warp >/dev/null 2>&1
    fi
    is_warp_installed || die "cloudflare-warp install failed"

    echo -e "${YELLOW}[3/5]${NC} Подготовка сервиса warp-svc..."
    ensure_warp_service

    echo -e "${YELLOW}[4/5]${NC} Регистрация WARP..."
    ensure_warp_registration || die "WARP registration failed"

    echo -e "${YELLOW}[5/5]${NC} Настройка SOCKS5 и подключение..."
    configure_warp_proxy
    run_warp connect >/dev/null 2>&1 || true
    sleep 3

    echo -e "${GREEN}WARP установлен.${NC}"
    if proxy_listening; then
        echo -e "${WHITE}SOCKS5: ${GREEN}127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "${WHITE}WARP IP: ${GREEN}$(get_warp_ip)${NC}"
    fi
    log_action "INSTALL: warp installed on port ${SOCKS_PORT}"
    read -r -p "Нажмите Enter..."
}

start_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -r -p "Нажмите Enter..."
        return
    fi

    connect_warp
    sleep 3

    if proxy_listening; then
        echo -e "\n${GREEN}[OK] WARP proxy поднят.${NC}"
        echo -e "${WHITE}SOCKS5: ${CYAN}127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "${WHITE}WARP IP: ${GREEN}$(get_warp_ip)${NC}"
        log_action "START: warp connected"
    else
        echo -e "\n${RED}[ERROR] WARP proxy не поднялся.${NC}"
    fi
    read -r -p "Нажмите Enter..."
}

stop_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -r -p "Нажмите Enter..."
        return
    fi

    run_warp disconnect >/dev/null 2>&1 || true
    echo -e "\n${GREEN}[OK] WARP отключён.${NC}"
    log_action "STOP: warp disconnected"
    read -r -p "Нажмите Enter..."
}

show_status() {
    clear
    get_my_ip
    echo -e "\n${CYAN}━━━ Статус WARP ━━━${NC}\n"
    echo -e "  ${WHITE}Статус:      ${GREEN}$(get_warp_status_text)${NC}"
    echo -e "  ${WHITE}Сервер IP:   ${GREEN}${MY_IP}${NC}"
    echo -e "  ${WHITE}SOCKS5:      ${CYAN}127.0.0.1:${SOCKS_PORT}${NC}"
    echo -e "  ${WHITE}Proxy:       ${GREEN}$(proxy_listening && echo listening || echo not-listening)${NC}"
    if proxy_listening; then
        echo -e "  ${WHITE}WARP IP:     ${GREEN}$(get_warp_ip)${NC}"
    fi
    echo ""
    run_warp status || true
    echo ""
    read -r -p "Нажмите Enter..."
}

show_xui_json() {
    clear
    echo -e "\n${CYAN}━━━ Конфигурация для 3x-ui / Xray ━━━${NC}\n"
    cat <<EOF
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": ${SOCKS_PORT}
      }
    ]
  }
}
EOF
    echo ""
    cat <<'EOF'
Пример routing rule:
{
  "outboundTag": "warp",
  "domain": [
    "geosite:openai",
    "geosite:netflix",
    "domain:chat.openai.com",
    "domain:claude.ai"
  ]
}
EOF
    echo ""
    echo -e "${YELLOW}Важно:${NC} режим WARP proxy нормально подходит для TCP-трафика 3x-ui."
    echo -e "${YELLOW}UDP через этот режим ограничен самим warp-cli.${NC}"
    echo ""
    read -r -p "Нажмите Enter..."
}

rekey_warp() {
    if ! is_warp_installed; then
        echo -e "\n${RED}WARP не установлен.${NC}"
        read -r -p "Нажмите Enter..."
        return
    fi

    echo -e "\n${YELLOW}Текущая регистрация будет удалена и создана заново.${NC}"
    read -r -p "Продолжить? (y/n): " confirm
    [ "$confirm" = "y" ] || return

    run_warp disconnect >/dev/null 2>&1 || true
    run_warp registration delete >/dev/null 2>&1 || true
    reset_warp_registration_state
    connect_warp
    sleep 3

    echo -e "\n${GREEN}[OK] Регистрация обновлена.${NC}"
    [ "$(proxy_listening && echo yes || echo no)" = "yes" ] && echo -e "${WHITE}WARP IP: ${GREEN}$(get_warp_ip)${NC}"
    log_action "REKEY: registration renewed"
    read -r -p "Нажмите Enter..."
}

change_port() {
    local new_port
    echo -e "\n${WHITE}Текущий порт: ${GREEN}${SOCKS_PORT}${NC}"
    while true; do
        read -r -p "Новый порт (1024-65535): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )); then
            break
        fi
        echo -e "${RED}Некорректный порт.${NC}"
    done

    save_config_val "SOCKS_PORT" "$new_port"
    SOCKS_PORT="$new_port"

    if is_warp_installed; then
        proxy_port_cmd >/dev/null 2>&1 || true
    fi

    echo -e "\n${GREEN}[OK] Порт изменён на ${SOCKS_PORT}.${NC}"
    log_action "PORT: changed to ${SOCKS_PORT}"
    read -r -p "Нажмите Enter..."
}

update_self() {
    need_root
    need_cmd curl
    local tmp
    tmp="$(mktemp)"
    curl -fsSL "$RAW_BASE/warpgo-clean.sh" -o "$tmp" || die "failed to download update"
    install -m 755 "$tmp" "$INSTALL_BIN"
    rm -f "$tmp"
    echo -e "\n${GREEN}[OK] Скрипт обновлён.${NC}"
    read -r -p "Нажмите Enter..."
}

full_uninstall() {
    echo -e "\n${RED}Будет удалён WARP и конфиг менеджера.${NC}"
    read -r -p "Удалить? (y/n): " confirm
    [ "$confirm" = "y" ] || return

    run_warp disconnect >/dev/null 2>&1 || true
    run_warp registration delete >/dev/null 2>&1 || true
    apt-get remove -y cloudflare-warp >/dev/null 2>&1 || true
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -f /etc/apt/sources.list.d/cloudflare-client.list
    rm -f /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -rf "$CONFIG_DIR"
    rm -f "$LOG_FILE"
    rm -f "$INSTALL_BIN"
    echo -e "\n${GREEN}[OK] WARP Manager удалён.${NC}"
    exit 0
}

show_info() {
    clear
    echo -e "\n${CYAN}━━━ О скрипте ━━━${NC}\n"
    echo -e "${WHITE}Схема работы:${NC}"
    echo -e "  ${GREEN}Клиент 3x-ui/Xray${NC} -> ${CYAN}SOCKS5 127.0.0.1:${SOCKS_PORT}${NC} -> ${GREEN}Cloudflare WARP${NC}"
    echo ""
    echo -e "${WHITE}Что делает скрипт:${NC}"
    echo -e "  1) Ставит cloudflare-warp"
    echo -e "  2) Переключает WARP в режим SOCKS5 proxy"
    echo -e "  3) Показывает готовый outbound для 3x-ui"
    echo ""
    read -r -p "Нажмите Enter..."
}

show_menu() {
    while true; do
        clear
        get_my_ip
        local status_text
        status_text="$(get_warp_status_text)"

        echo -e "${MAGENTA}******************************************************${NC}"
        echo -e " ${WHITE}${APP_NAME} v${APP_VERSION}${NC}"
        echo -e " ${WHITE}Server IP:${NC} ${GREEN}${MY_IP}${NC}"
        echo -e " ${WHITE}WARP:${NC} ${GREEN}${status_text}${NC}"
        echo -e " ${WHITE}SOCKS5:${NC} ${CYAN}127.0.0.1:${SOCKS_PORT}${NC}"
        echo -e "${MAGENTA}******************************************************${NC}"
        echo -e " 1) ${GREEN}Установить WARP${NC}"
        echo -e " 2) ${CYAN}Запустить WARP${NC}"
        echo -e " 3) ${YELLOW}Остановить WARP${NC}"
        echo -e " 4) ${WHITE}Статус${NC}"
        echo -e " 5) ${CYAN}JSON для 3x-ui${NC}"
        echo -e " 6) ${YELLOW}Перевыпуск ключа${NC}"
        echo -e " 7) ${WHITE}Изменить порт SOCKS5${NC}"
        echo -e " 8) ${CYAN}Обновить скрипт${NC}"
        echo -e " 9) ${WHITE}Информация${NC}"
        echo -e "10) ${RED}Удалить WARP Manager${NC}"
        echo -e " 0) Выход"
        echo -e "------------------------------------------------------"
        read -r -p "Выбор: " choice
        case "$choice" in
            1) install_warp ;;
            2) start_warp ;;
            3) stop_warp ;;
            4) show_status ;;
            5) show_xui_json ;;
            6) rekey_warp ;;
            7) change_port ;;
            8) update_self ;;
            9) show_info ;;
            10) full_uninstall ;;
            0) exit 0 ;;
        esac
    done
}

run_startup() {
    need_root
    init_config
    install_self
    get_my_ip
    show_menu
}

case "${1:-}" in
    install) need_root; init_config; install_self; install_warp ;;
    start) need_root; init_config; start_warp ;;
    stop) need_root; init_config; stop_warp ;;
    status) need_root; init_config; show_status ;;
    xui) need_root; init_config; show_xui_json ;;
    rekey) need_root; init_config; rekey_warp ;;
    port) need_root; init_config; change_port ;;
    update) need_root; init_config; update_self ;;
    uninstall) need_root; init_config; full_uninstall ;;
    *) run_startup ;;
esac
