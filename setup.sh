#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="1.8"
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКА ОБНОВЛЕНИЯ СКРИПТА ---
check_update_silent() {
    REMOTE_VER=$(curl -sL --max-time 2 "$GITHUB_RAW" | grep -m1 'VERSION=' | cut -d'"' -f2)
    if [[ "$REMOTE_VER" != "$VERSION" && -n "$REMOTE_VER" ]]; then
        UPDATE_LABEL="${RED}[ ДОСТУПНА v$REMOTE_VER ]${NC}"
    else
        UPDATE_LABEL="${GREEN}(v$VERSION)${NC}"
    fi
}

# --- ШАПКА И СТАТУСЫ ---
get_header() {
    # Статус Интернета (Сервера)
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then S_STAT="${GREEN}● OK${NC}"; else S_STAT="${RED}● OFF${NC}"; fi
    # Статус WARP
    if ip link show "$TUN_DEV" >/dev/null 2>&1 && pgrep -x "tun2socks" >/dev/null; then W_STAT="${GREEN}● OK${NC}"; else W_STAT="${RED}● OFF${NC}"; fi
    # Статус DNS
    DNS_IP=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
    
    S_IP=$(curl -s --interface "$MAIN_IFACE" --max-time 1 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 1 eth0.me || echo "ВЫКЛ")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo $UPDATE_LABEL"
    echo -e " Сервер: $S_STAT | IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP:   $W_STAT | IP: ${GREEN}$W_IP${NC}"
    echo -e " DNS:    ${CYAN}$DNS_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- УПРАВЛЕНИЕ КОМПОНЕНТАМИ ---
manage_components() {
    while true; do
        clear
        echo -e "${BLUE}━━━ Управление компонентами ━━━${NC}\n"
        
        # Проверка tun2socks
        if [ -f /usr/local/bin/tun2socks ]; then T2S_INFO="${GREEN}[АКТУАЛЬНО]${NC}"; else T2S_INFO="${RED}[НЕ УСТАНОВЛЕНО]${NC}"; fi
        # Проверка wgcf
        if [ -f /usr/local/bin/wgcf ]; then WGCF_INFO="${GREEN}[АКТУАЛЬНО]${NC}"; else WGCF_INFO="${RED}[НЕ УСТАНОВЛЕНО]${NC}"; fi
        # Проверка Speedtest
        if command -v speedtest >/dev/null 2>&1; then SPD_INFO="${GREEN}[УСТАНОВЛЕНО]${NC}"; else SPD_INFO="${RED}[НЕТ]${NC}"; fi

        echo -e " 1) tun2socks      $T2S_INFO"
        echo -e " 2) wgcf (WARP)    $WGCF_INFO"
        echo -e " 3) Speedtest-CLI  $SPD_INFO"
        echo -e "-----------------------------------------------"
        echo -e " u1) Удалить tun2socks | u2) Удалить wgcf"
        echo -e " u3) Удалить Speedtest"
        echo -e " 0) Назад"
        
        read -p " Выбор: " comp_c
        case $comp_c in
            1) 
                V=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
                wget -q "https://github.com/xjasonlyu/tun2socks/releases/download/$V/tun2socks-linux-amd64.zip" -O t2s.zip
                unzip -o t2s.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks; rm t2s.zip 
                echo "tun2socks обновлен."; sleep 1 ;;
            2) 
                wget -q https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
                chmod +x /usr/local/bin/wgcf; echo "wgcf обновлен."; sleep 1 ;;
            3) 
                curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
                apt install speedtest -y; echo "Speedtest установлен."; sleep 1 ;;
            u1) rm -f /usr/local/bin/tun2socks && systemctl stop tun2socks; echo "Удалено."; sleep 1 ;;
            u2) rm -f /usr/local/bin/wgcf && rm -rf /etc/WarpGo; echo "Удалено."; sleep 1 ;;
            u3) apt remove speedtest -y; echo "Удалено."; sleep 1 ;;
            0) break ;;
        esac
    done
}

# --- ОБНОВЛЕНИЕ КЛЮЧЕЙ CLOUDFLARE ---
re-register_warp() {
    clear
    echo -e "${BLUE}━━━ Обновление ключей CloudFlare ━━━${NC}"
    read -p " Продолжить? (y/n): " confirm
    [[ "$confirm" != "y" ]] && return

    echo -n " Перевыпуск ключей и перезапуск..."
    systemctl stop tun2socks >/dev/null 2>&1
    cd /etc/WarpGo && rm -f wgcf-account.json wgcf-profile.conf >/dev/null 2>&1
    yes | wgcf register >/dev/null 2>&1 && wgcf generate >/dev/null 2>&1
    systemctl start tun2socks >/dev/null 2>&1
    sleep 3
    echo -e " ${GREEN}✓ Готово!${NC}"
    read -p " Нажмите Enter..."
}

# --- УПРАВЛЕНИЕ DNS ---
manage_dns() {
    while true; do
        clear
        CUR_DNS=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -n1)
        echo -e "${BLUE}━━━ Управление DNS (Текущий: $CUR_DNS) ━━━${NC}\n"
        echo -e " 1) AdGuard DNS (Блок рекламы) -> 94.140.14.14"
        echo -e " 2) Cloudflare DNS            -> 1.1.1.1"
        echo -e " 3) Google DNS                -> 8.8.8.8"
        echo -e " 4) Сбросить на стандарт (Google)"
        echo -e " 0) Назад"
        read -p " Выбор: " d_choice
        case $d_choice in
            1) echo "nameserver 94.140.14.14" > /etc/resolv.conf; echo "Применено."; sleep 1 ;;
            2) echo "nameserver 1.1.1.1" > /etc/resolv.conf; echo "Применено."; sleep 1 ;;
            3|4) echo "nameserver 8.8.8.8" > /etc/resolv.conf; echo "Применено."; sleep 1 ;;
            0) break ;;
        esac
    done
}

# --- МАРШРУТЫ (UP/DOWN) ---
routing_up() { 
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev "$TUN_DEV" table warp
    ip rule add dport 47684 priority 5 table main 2>/dev/null
    ip rule add sport 47684 priority 6 table main 2>/dev/null
    ip rule add from 172.29.172.0/24 priority 100 table warp 2>/dev/null
    iptables -t nat -I POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE
    echo -e "${GREEN}Маршруты активированы.${NC}"; sleep 1 
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    iptables -t nat -D POSTROUTING -s 172.29.172.0/24 ! -d 172.29.172.0/24 -j MASQUERADE 2>/dev/null
    echo -e "${YELLOW}Маршруты удалены.${NC}"; sleep 1
}

# --- ОБНОВЛЕНИЕ СКРИПТА (ПУНКТ 12) ---
self_update() {
    echo -e "${YELLOW}Принудительное обновление...${NC}"
    curl -sL "$GITHUB_RAW" -o "$LOCAL_PATH"
    chmod +x "$LOCAL_PATH"
    echo -e "${GREEN}Обновлено! Перезапустите: WarpGo${NC}"
    exit 0
}

# --- МЕНЮ ---
check_update_silent
while true; do
    clear
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить WARP (Все компоненты)"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить WARP (DOWN)"
    
    echo -e "\n${YELLOW} [2] СЕРВИС И КОНФИГИ:${NC}"
    echo -e "  4) Компоненты (Обновление/Удаление)"
    echo -e "  5) Обновление ключей CloudFlare"
    echo -e "  6) Показать логи (tun2socks)"
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
        1) install_all ;; # Функция установки из v1.3
        2) systemctl start tun2socks && routing_up ;;
        3) systemctl stop tun2socks && routing_down ;;
        4) manage_components ;;
        5) re-register_warp ;;
        6) tail -n 50 "$LOG_FILE" && read -p "Enter..." ;;
        7) show_json_page ;; # Функция из v1.7
        8) show_diagnostics_page ;; # Функция из v1.7
        9) manage_dns ;;
        12) self_update ;;
        13) systemctl stop tun2socks; rm -rf /etc/WarpGo /usr/local/bin/tun2socks; routing_down ;;
        0) exit 0 ;;
    esac
done
