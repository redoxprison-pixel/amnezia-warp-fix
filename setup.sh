#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="1.5"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКА ОБНОВЛЕНИЯ ---
check_update_silent() {
    REMOTE_VER=$(curl -sL --max-time 2 "$GITHUB_RAW" | grep -m1 'VERSION=' | cut -d'"' -f2)
    if [[ "$REMOTE_VER" != "$VERSION" && -n "$REMOTE_VER" ]]; then
        UPDATE_LABEL="${RED}[ ДОСТУПНА v$REMOTE_VER ]${NC}"
    else
        UPDATE_LABEL="${GREEN}(v$VERSION)${NC}"
    fi
}

# --- СТАТУС ---
check_status() {
    if pgrep -x "tun2socks" > /dev/null || ip link show "$TUN_DEV" >/dev/null 2>&1; then
        STATUS_WARP="${GREEN}● РАБОТАЕТ${NC}"
    else
        STATUS_WARP="${RED}○ ВЫКЛЮЧЕН${NC}"
    fi
}

# --- ПУНКТ 7: КОНФИГУРАЦИЯ 3X-UI ---
show_json_page() {
    clear
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo "Error")
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}               ━━━ Конфигурация для 3X-UI ━━━                ${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo -e "\n${YELLOW}Общие данные:${NC}"
    echo -e " SOCKS5 прокси: ${GREEN}127.0.0.1:$WARP_PORT${NC}"
    echo -e " WARP IP:       ${GREEN}$W_IP${NC}"

    echo -e "\n${YELLOW}1. Добавить Outbound (Входящий узел):${NC}"
    cat <<EOF
{
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "127.0.0.1", "port": $WARP_PORT}]
  },
  "tag": "warp"
}
EOF

    echo -e "\n${YELLOW}2. Правило маршрутизации (Routing Rule):${NC}"
    echo -e "${CYAN}Только определённые сайты через WARP:${NC}"
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
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p " Нажмите Enter, чтобы вернуться..."
}

# --- ПУНКТ 8: ДИАГНОСТИКА И SPEEDTEST ---
show_diagnostics_page() {
    while true; do
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BLUE}               ━━━ Диагностика и Скорость ━━━                ${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # Проверка ПО
        [ -d "/opt/amnezia" ] && AMN="${GREEN}Установлена${NC}" || AMN="${RED}Нет${NC}"
        [ -d "/usr/local/x-ui" ] && XUI="${GREEN}Установлен${NC}" || XUI="${RED}Нет${NC}"
        echo -e " Amnezia VPN: $AMN | 3X-UI: $XUI"
        
        echo -e "\n${YELLOW}Замер скорости (Загрузка 10МБ через WARP):${NC}"
        echo -e " Тестирование... (может занять 5-10 сек)"
        
        # Реальный тест скорости через curl
        SPEED=$(curl -L -s -w "%{speed_download}\n" --proxy socks5h://127.0.0.1:"$WARP_PORT" https://bin.msk.fast.vps.vc/10mb.bin -o /dev/null)
        SPEED_MB=$(echo "scale=2; $SPEED / 1024 / 1024 * 8" | bc)
        
        echo -e " Скорость: ${GREEN}$SPEED_MB Mbit/s${NC}"
        
        echo -e "\n${YELLOW}Задержка (RTT):${NC}"
        RTT=$(curl -o /dev/null -s -w "%{time_starttransfer}\n" --proxy socks5h://127.0.0.1:"$WARP_PORT" google.com)
        echo -e " Отклик Google: ${GREEN}${RTT} сек.${NC}"

        echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e " [R] Обновить | [M] В главное меню"
        read -n 1 -s key
        [[ "$key" == "r" || "$key" == "R" ]] && continue
        [[ "$key" == "m" || "$key" == "M" ]] && break
        break
    done
}

# --- ПУНКТ 5: ПЕРЕРЕГИСТРАЦИЯ С АНИМАЦИЕЙ ---
re-register_warp() {
    clear
    echo -e "${YELLOW}Текущая регистрация будет удалена и создана новая.${NC}"
    echo -e "${YELLOW}WARP будет временно отключён.${NC}"
    read -p "Продолжить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    echo -n "[1/4] Отключение..."
    systemctl stop tun2socks >/dev/null 2>&1
    echo -e " ${GREEN}✓${NC}"

    echo -n "[2/4] Удаление регистрации..."
    cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf >/dev/null 2>&1
    echo -e " ${GREEN}✓${NC}"

    echo -n "[3/4] Новая регистрация..."
    yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
    echo -e " ${GREEN}✓${NC}"

    echo -n "[4/4] Подключение..."
    systemctl start tun2socks >/dev/null 2>&1
    sleep 3
    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        echo -e " ${GREEN}✓ Регистрация обновлена, подключение подтверждено!${NC}"
    else
        echo -e " ${RED}⚠ Ошибка подключения.${NC}"
    fi
    read -p " Нажмите Enter..."
}

# --- УСТАНОВКА / УДАЛЕНИЕ КОМПОНЕНТОВ ---
manage_components() {
    clear
    echo -e "${CYAN}═══ Управление компонентами ═══${NC}"
    # Проверка версий
    T2S_V=$([ -f /usr/local/bin/tun2socks ] && /usr/local/bin/tun2socks -version | head -n1 | awk '{print $3}' || echo "Нет")
    WGCF_V=$([ -f /usr/local/bin/wgcf ] && wgcf version | grep version | awk '{print $3}' || echo "Нет")
    
    echo -e "1) tun2socks  [Версия: $T2S_V]"
    echo -e "2) wgcf (WARP) [Версия: $WGCF_V]"
    echo -e "3) bc (Калькулятор для тестов)"
    echo -e "--------------------------------"
    echo -e "u1) Удалить tun2socks | u2) Удалить wgcf"
    echo -e "0) Назад"
    read -p "Выбор: " comp_c
    case $comp_c in
        1) 
            V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
            wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
            unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks && rm t2s.zip
            echo "Обновлено."; sleep 1 ;;
        u1) rm -f /usr/local/bin/tun2socks && systemctl stop tun2socks; echo "Удалено."; sleep 1 ;;
    esac
}

# --- DNS БЛОК ---
show_dns_info() {
    clear
    echo -e "${BLUE}━━━ Настройка DNS (AdGuard / Privacy) ━━━${NC}"
    echo -e "\n${YELLOW}Актуальные сервисы:${NC}"
    echo -e "1. ${CYAN}AdGuard DNS${NC} (Блокировка рекламы):"
    echo -e "   - DNS: 94.140.14.14 | DoH: https://dns.adguard.com/dns-query"
    echo -e "2. ${CYAN}Cloudflare${NC} (Скорость):"
    echo -e "   - DNS: 1.1.1.1 | DoH: https://1.1.1.1/dns-query"
    echo -e "3. ${CYAN}Comss.one${NC} (Для РФ/СНГ):"
    echo -e "   - DNS: 76.76.2.22"
    
    echo -e "\n${YELLOW}Как использовать:${NC}"
    echo -e " В 3X-UI в разделе DNS замените стандартные IP на выбранные выше."
    echo -e " Для DoH/DoT - используйте соответствующие ссылки в конфиге X-Ray."
    read -p " Нажмите Enter..."
}

# --- МАРШРУТЫ ---
routing_up() { 
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport 47684 priority 5 table main 2>/dev/null
    ip rule add sport 47684 priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -I POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    echo -e "${GREEN}Маршруты подняты.${NC}"; sleep 1 
}

# --- ГЛАВНОЕ МЕНЮ ---
check_update_silent
while true; do
    clear
    check_status
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        WarpGo $UPDATE_LABEL              ${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " $STATUS_WARP | IP: ${GREEN}$W_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"

    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить WARP (Все компоненты)"
    echo -e "  2) Запустить (UP) | 3) Остановить (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты (Версии/Удаление)"
    echo -e "  5) Перерегистрация ключей (WGCF)"
    echo -e "  6) Показать логи"
    echo -e "  7) Конфигурация для 3X-UI (JSON)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ И DNS:${NC}"
    echo -e "  8) Диагностика и Speedtest"
    echo -e "  9) Информация о DNS (AdGuard/DoH)"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 12) ОБНОВИТЬ СКРИПТ (WarpGo)"
    echo -e " 13) ${RED}Удалить всё${NC} | 0) Выход"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice

    case $choice in
        1) install_all ;; # Здесь твоя функция установки из v1.3
        2) systemctl start tun2socks && routing_up ;;
        3) systemctl stop tun2socks && routing_down ;;
        4) manage_components ;;
        5) re-register_warp ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) show_json_page ;;
        8) show_diagnostics_page ;;
        9) show_dns_info ;;
        12) self_update ;;
        13) systemctl stop tun2socks && rm -rf /etc/WarpGo /usr/local/bin/tun2socks && routing_down ;;
        0) exit 0 ;;
    esac
done
