#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
PORT=40000

draw_logo() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${WHITE}WARP MANAGER v5.6 — Amnezia Optimized${NC}"
    echo -e "  ${CYAN}Engine: Official Cloudflare WARP (SOCKS5)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

check_status() {
    # Проверка процесса
    if pgrep -x "warp-svc" > /dev/null; then
        STATUS_COLOR=$GREEN
        STATUS_TEXT="РАБОТАЕТ"
    else
        STATUS_COLOR=$RED
        STATUS_TEXT="ОСТАНОВЛЕН"
    fi
    
    # Более надежная проверка IP (используем eth0.me)
    MAIN_IP=$(curl -s4 --max-time 2 eth0.me || echo "Ошибка связи")
    WARP_IP=$(curl -s4 --proxy socks5h://127.0.0.1:$PORT --max-time 2 eth0.me || echo -e "${RED}OFF${NC}")
}

show_info() {
    check_status
    echo -e "  Статус службы:  ${STATUS_COLOR}● $STATUS_TEXT${NC}"
    echo -e "  Основной IP:    ${YELLOW}$MAIN_IP${NC}"
    echo -e "  WARP IP:        ${GREEN}$WARP_IP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# --- МЕНЮ ---
while true; do
    draw_logo
    show_info
    echo -e "  ${WHITE}1)${NC} ${GREEN}Установить / Переустановить${NC}"
    echo -e "  ${WHITE}2)${NC} ${CYAN}Включить (Connect)${NC}"
    echo -e "  ${WHITE}3)${NC} ${YELLOW}Выключить (Disconnect)${NC}"
    echo -e "  ${WHITE}4)${NC} ${MAGENTA}Как использовать с Amnezia?${NC}"
    echo -e "  ${WHITE}5)${NC} Удалить WARP"
    echo -e "  ${WHITE}0)${NC} Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
    read -p " Выберите действие [0-5]: " choice

    case $choice in
        1) # (Код установки остается прежним, как в v5.5) 
           ;;
        2) warp-cli connect && sleep 2 ;;
        3) warp-cli disconnect && sleep 1 ;;
        4) clear
           echo -e "${CYAN}Как подружить это с Amnezia (без 3X-UI):${NC}\n"
           echo -e "1. ${WHITE}Для самого сервера:${NC} Теперь любые команды через"
           echo -e "   proxychains или curl --proxy socks5h://127.0.0.1:40000"
           echo -e "   будут идти через Cloudflare."
           echo -e "2. ${WHITE}Для Docker-контейнеров:${NC} Если Amnezia ставит"
           echo -e "   контейнеры, они могут использовать хостовый порт 40000."
           echo -e "3. ${WHITE}Цепочка:${NC} Чтобы клиенты Amnezia ходили через WARP,"
           echo -e "   нужен мост (Xray или Tun2Socks)."
           echo -e "\n${YELLOW}В текущем виде WARP защищает твой SSH и дает серверу"
           echo -e "чистый выход в мир для обновлений и работы.${NC}"
           read -p "Нажми Enter..." ;;
        5) warp-cli disconnect; apt-get purge -y cloudflare-warp; echo "Удалено."; read ;;
        0) exit 0 ;;
    esac
done
