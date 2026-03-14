#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="3.9"
WARP_PORT="40000"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -f "warp-plus" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo -e "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Gool Engine Mode"
    echo -e " Architecture: $(uname -m)"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: $W_IP"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

routing_down() {
    echo -e "${YELLOW}Остановка...${NC}"
    systemctl stop warp-plus >/dev/null 2>&1
    killall warp-plus >/dev/null 2>&1
    iptables -t nat -F
}

routing_up() {
    routing_down
    if [ ! -f /usr/local/bin/warp-plus ]; then
        echo -e "${RED}Файл не найден! Сначала пункт 1.${NC}"; sleep 2; return
    fi
    echo -e "${YELLOW}Запуск Gool...${NC}"
    systemctl start warp-plus
    sleep 5
    
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 10 google.com > /dev/null; then
        echo -e "${GREEN}✓ ГОТОВО! WARP активен.${NC}"
    else
        echo -e "${RED}✗ ОШИБКА: Прокси не отвечает. Проверь логи (п.6)${NC}"
        read -p "Нажми Enter..."
    fi
}

full_install() {
    routing_down
    echo -e "${BLUE}Определяю архитектуру и скачиваю Gool...${NC}"
    
    ARCH=$(uname -m)
    URL=""
    
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-amd64"
    elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-arm64"
    else
        echo -e "${RED}Неизвестная архитектура: $ARCH${NC}"; return
    fi

    # Скачивание с проверкой
    wget -qO /usr/local/bin/warp-plus "$URL"
    if [ $? -ne 0 ]; then echo -e "${RED}Ошибка загрузки!${NC}"; return; fi
    
    chmod +x /usr/local/bin/warp-plus

    # ПРОВЕРКА ЗАПУСКАЕМОСТИ (Тот самый фикс Exec format error)
    if ! /usr/local/bin/warp-plus --version >/dev/null 2>&1; then
        echo -e "${RED}ОШИБКА: Файл скачан, но не запускается (Exec format error).${NC}"
        echo -e "${YELLOW}Пробую альтернативный метод...${NC}"
        # Если amd64 не пошел, возможно нужна 386 версия (редко, но бывает)
        wget -qO /usr/local/bin/warp-plus "https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-386"
        chmod +x /usr/local/bin/warp-plus
    fi

    # Создание сервиса
    cat <<EOF > /etc/systemd/system/warp-plus.service
[Unit]
Description=Warp-Plus Gool Service
After=network.target

[Service]
ExecStart=/usr/local/bin/warp-plus --socks-addr 127.0.0.1:$WARP_PORT --gool
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-plus
    echo -e "${GREEN}Установка завершена успешно!${NC}"
    sleep 2
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) Установить Gool (Fix Exec Format)"
    echo -e " 2) ЗАПУСТИТЬ WARP"
    echo -e " 3) ОСТАНОВИТЬ"
    echo -e " 6) Логи (Journalctl)"
    echo -e " 13) ПОЛНОЕ УДАЛЕНИЕ"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        6) journalctl -u warp-plus -n 20 --no-pager; read -p "Enter..." ;;
        13) routing_down; rm -f /usr/local/bin/warp-plus /etc/systemd/system/warp-plus.service; echo "Очищено."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
