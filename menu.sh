#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Функция вывода заголовка
show_header() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "   ${WHITE}WARP MANAGER v5.5 — Official Mode${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    
    # Проверка статуса
    STATUS=$(warp-cli status | grep "Status update:" | awk '{print $3}')
    if [[ "$STATUS" == "Connected" ]]; then
        echo -e " Статус: ${GREEN}● ПОДКЛЮЧЕН${NC}"
        # Получаем IP через прокси
        W_IP=$(curl -s4 --proxy socks5h://127.0.0.1:40000 ifconfig.me)
        echo -e " WARP IP: ${GREEN}$W_IP${NC}"
    else
        echo -e " Статус: ${RED}○ ОТКЛЮЧЕН${NC}"
    fi
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
}

# Основное меню
while true; do
    show_header
    echo -e " 1) ${GREEN}ЗАПУСТИТЬ${NC} WARP"
    echo -e " 2) ${RED}ОСТАНОВИТЬ${NC} WARP"
    echo -e " 3) Перезагрузить (Reconnect)"
    echo -e " 4) Показать JSON для 3X-UI"
    echo -e " 5) Логи (Journalctl)"
    echo -e " 0) Выход"
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    read -p " Выберите пункт: " choice

    case $choice in
        1)
            echo -e "${YELLOW}Запуск...${NC}"
            warp-cli connect
            sleep 2 ;;
        2)
            echo -e "${YELLOW}Остановка...${NC}"
            warp-cli disconnect
            sleep 1 ;;
        3)
            warp-cli disconnect && sleep 1 && warp-cli connect
            echo -e "${GREEN}Перезапущено${NC}"
            sleep 1 ;;
        4)
            echo -e "${CYAN}Скопируйте этот блок в Outbounds вашего 3X-UI:${NC}"
            echo -e "${YELLOW}"
            cat <<EOF
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [{ "address": "127.0.0.1", "port": 40000 }]
  }
}
EOF
            echo -e "${NC}"
            read -p "Нажмите Enter, чтобы вернуться..." ;;
        5)
            journalctl -u warp-svc -n 50 --no-pager
            read -p "Нажми Enter..." ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}"; sleep 1 ;;
    esac
done
