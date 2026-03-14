#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="1.7"
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

# --- ШАПКА И СТАТУС ---
get_header() {
    if pgrep -x "tun2socks" > /dev/null || ip link show "$TUN_DEV" >/dev/null 2>&1; then
        STATUS_WARP="${GREEN}● РАБОТАЕТ${NC}"
    else
        STATUS_WARP="${RED}○ ВЫКЛЮЧЕН${NC}"
    fi
    S_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 1 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo $UPDATE_LABEL | $STATUS_WARP"
    echo -e " IP Сервера: ${YELLOW}$S_IP${NC}"
    echo -e " IP WARP:    ${GREEN}$W_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПУНКТ 4: УПРАВЛЕНИЕ КОМПОНЕНТАМИ ---
manage_components() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление компонентами ━━━${NC}\n"
        T2S_V=$([ -f /usr/local/bin/tun2socks ] && /usr/local/bin/tun2socks -version | awk '{print $3}' || echo "Нет")
        WGCF_V=$([ -f /usr/local/bin/wgcf ] && wgcf --help | grep "wgcf version" | awk '{print $3}' || echo "Нет")
        SPEED_V=$(command -v speedtest >/dev/null && echo "ОК" || echo "Нет")
        
        echo -e " [1] tun2socks     [Версия: ${YELLOW}$T2S_V${NC}]"
        echo -e " [2] wgcf (WARP)   [Версия: ${YELLOW}$WGCF_V${NC}]"
        echo -e " [3] Speedtest-CLI [Статус: ${YELLOW}$SPEED_V${NC}]"
        echo -e "-----------------------------------------------"
        echo -e " [u1] Удалить tun2socks | [u2] Удалить wgcf"
        echo -e " [0] Назад"
        read -p " Выбор: " comp_c
        case $comp_c in
            1) 
                V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
                wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
                unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks; rm t2s.zip ;;
            2) wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf; chmod +x /usr/local/bin/wgcf ;;
            3) curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && apt install speedtest ;;
            u1) rm -f /usr/local/bin/tun2socks && systemctl stop tun2socks ;;
            u2) rm -f /usr/local/bin/wgcf && rm -rf /etc/WarpGo ;;
            0) break ;;
        esac
    done
}

# --- ПУНКТ 5: ОБНОВЛЕНИЕ РЕГИСТРАЦИИ ---
re-register_warp() {
    clear
    echo -e "${BLUE}━━━ Перерегистрация аккаунта WARP ━━━${NC}"
    read -p " Продолжить? Данные будут стерты. (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    echo -n " Обработка новой регистрации..."
    systemctl stop tun2socks >/dev/null 2>&1
    cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf >/dev/null 2>&1
    yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
    systemctl start tun2socks >/dev/null 2>&1
    sleep 3
    
    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        echo -e " ${GREEN}✓ Успешно подключено!${NC}"
    else
        echo -e " ${RED}✗ Ошибка подключения.${NC}"
    fi
    read -p " Нажмите Enter..."
}

# --- ПУНКТ 7: JSON 3X-UI ---
show_json_page() {
    clear
    echo -e "${BLUE}━━━ Конфигурация для 3X-UI ━━━${NC}"
    echo -e "\n${YELLOW}SOCKS5 прокси:${NC} 127.0.0.1:$WARP_PORT"
    echo -e "${YELLOW}WARP IP:${NC} $(curl -s --proxy socks5h://127.0.0.1:$WARP_PORT --max-time 2 eth0.me || echo "Error")"
    
    echo -e "\n${CYAN}1. Только определённые сайты через WARP (Routing Rule):${NC}\n"
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
    read -p " Нажмите Enter..."
}

# --- ПУНКТ 8: SPEEDTEST ---
show_diagnostics_page() {
    clear
    echo -e "${BLUE}━━━ Диагностика и Скорость ━━━${NC}"
    echo -e "\n${YELLOW}Замер скорости (10МБ файл через WARP):${NC}"
    SPEED=$(curl -L -s -w "%{speed_download}\n" --proxy socks5h://127.0.0.1:"$WARP_PORT" https://bin.msk.fast.vps.vc/10mb.bin -o /dev/null)
    SPEED_MB=$(echo "scale=2; $SPEED / 1024 / 1024 * 8" | bc)
    echo -e " Скорость загрузки: ${GREEN}$SPEED_MB Mbit/s${NC}"

    echo -e "\n${YELLOW}Задержка (RTT Google):${NC}"
    RTT=$(curl -o /dev/null -s -w "%{time_starttransfer}\n" --proxy socks5h://127.0.0.1:"$WARP_PORT" google.com)
    MS=$(echo "scale=0; $RTT * 1000 / 1" | bc)
    echo -e " Время отклика: ${GREEN}${MS} ms${NC}"
    
    read -p " Нажмите Enter..."
}

# --- ПУНКТ 9: DNS МЕНЮ ---
manage_dns() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление DNS ━━━${NC}\n"
        echo -e "1) ${CYAN}AdGuard DNS${NC} (Без рекламы)"
        echo -e "   - IP: 94.140.14.14"
        echo -e "   - DoH: https://dns.adguard.com/dns-query"
        echo ""
        echo -e "2) ${CYAN}Cloudflare${NC}"
        echo -e "   - IP: 1.1.1.1"
        echo -e "   - DoH: https://1.1.1.1/dns-query"
        echo ""
        echo -e "3) ${CYAN}Google DNS${NC}"
        echo -e "   - IP: 8.8.8.8"
        echo ""
        echo -e "off) Сбросить на стандартные"
        echo -e "0) Назад"
        read -p " Выберите DNS для установки: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf; echo "Применено AdGuard."; sleep 1 ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "Применено Cloudflare."; sleep 1 ;;
            3) echo "nameserver 8.8.8.8" > /etc/resolv.conf; echo "Применено Google."; sleep 1 ;;
            off) echo "nameserver 8.8.8.8" > /etc/resolv.conf; echo "Сброшено."; sleep 1 ;;
            0) break ;;
        esac
    done
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

# --- МЕНЮ ---
check_update_silent
while true; do
    clear
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить WARP"
    echo -e "  2) Запустить (UP)"
    echo -e "  3) Остановить (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты"
    echo -e "  5) Перерегистрация (WGCF)"
    echo -e "  6) Показать логи"
    echo -e "  7) Конфиг 3X-UI (JSON)"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ И DNS:${NC}"
    echo -e "  8) Диагностика и Speedtest"
    echo -e "  9) Управление DNS"
    
    echo -e "\n${YELLOW} [4] ОБСЛУЖИВАНИЕ:${NC}"
    echo -e " 12) ОБНОВИТЬ СКРИПТ (WarpGo)"
    echo ""
    echo -e " 13) ${RED}Удалить всё${NC}"
    echo ""
    echo -e "  0) Выход"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    
    read -p " Выберите пункт: " choice
    case $choice in
        1) install_all ;;
        2) systemctl start tun2socks && routing_up ;;
        3) systemctl stop tun2socks && routing_down ;;
        4) manage_components ;;
        5) re-register_warp ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) show_json_page ;;
        8) show_diagnostics_page ;;
        9) manage_dns ;;
        12) self_update ;;
        13) systemctl stop tun2socks; rm -rf /etc/WarpGo /usr/local/bin/tun2socks; routing_down ;;
        0) exit 0 ;;
    esac
done
