#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
VERSION="4.0"
WARP_PORT="40000"
BIN_PATH="/usr/local/bin/warp-plus"
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

get_header() {
    clear
    pgrep -f "warp-plus" >/dev/null && W_STAT="${GREEN}● RUNNING${NC}" || W_STAT="${RED}● STOPPED${NC}"
    S_IP=$(curl -s --max-time 2 eth0.me || echo "Error")
    W_IP=$(curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 2 eth0.me || echo -e "${RED}ВЫКЛ${NC}")
    
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | Fix Arch Mode"
    echo -e " Архитектура: $(uname -m)"
    echo -e " Main IP: ${YELLOW}$S_IP${NC}"
    echo -e " WARP IP: $W_IP"
    echo -e " Status:  $W_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

routing_down() {
    echo -e "${YELLOW}Остановка сервисов...${NC}"
    systemctl stop warp-plus >/dev/null 2>&1
    killall warp-plus >/dev/null 2>&1
}

routing_up() {
    routing_down
    if [ ! -s "$BIN_PATH" ]; then
        echo -e "${RED}Файл бинарника пуст или отсутствует! Сначала пункт 1.${NC}"
        sleep 2; return
    fi
    echo -e "${YELLOW}Запуск Gool Engine...${NC}"
    systemctl start warp-plus
    sleep 5
    
    if curl -s --proxy socks5h://127.0.0.1:"$WARP_PORT" --max-time 10 google.com > /dev/null; then
        echo -e "${GREEN}✓ УСПЕХ! WARP работает.${NC}"
    else
        echo -e "${RED}✗ ОШИБКА: Коннекта нет. Проверь логи (п. 6)${NC}"
        read -p "Нажми Enter..."
    fi
}

full_install() {
    routing_down
    echo -e "${BLUE}Определяю архитектуру системы...${NC}"
    
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-amd64" ;;
        aarch64|arm64) URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-arm64" ;;
        i386|i686) URL="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-386" ;;
        *) echo -e "${RED}Неподдерживаемая архитектура: $ARCH${NC}"; return ;;
    esac

    echo -e "${YELLOW}Скачиваю: $URL${NC}"
    # Используем -L для редиректов и -f чтобы упасть при ошибке 404
    curl -Lf "$URL" -o "$BIN_PATH"
    
    if [ ! -s "$BIN_PATH" ]; then
        echo -e "${RED}Ошибка: Файл не скачался или пуст!${NC}"
        return
    fi

    chmod +x "$BIN_PATH"

    # Прямая проверка: может ли файл запуститься?
    echo -e "${YELLOW}Проверка совместимости бинарника...${NC}"
    if ! "$BIN_PATH" --version >/dev/null 2>&1; then
        echo -e "${RED}Критическая ошибка: Файл скачан, но система не может его выполнить (Exec format error).${NC}"
        echo -e "${YELLOW}Попробуем альтернативный метод (32-bit)...${NC}"
        curl -Lf "https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus-linux-386" -o "$BIN_PATH"
        chmod +x "$BIN_PATH"
        if ! "$BIN_PATH" --version >/dev/null 2>&1; then
             echo -e "${RED}Альтернативный метод тоже не помог. Проверь права доступа к /usr/local/bin.${NC}"
             return
        fi
    fi

    echo -e "${GREEN}Бинарник проверен и готов к работе.${NC}"

    # Создание сервиса
    cat <<EOF > /etc/systemd/system/warp-plus.service
[Unit]
Description=Warp-Plus Gool Service
After=network.target

[Service]
ExecStart=$BIN_PATH --socks-addr 127.0.0.1:$WARP_PORT --gool
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-plus
    echo -e "${GREEN}Установка завершена!${NC}"
    sleep 2
}

# --- МЕНЮ ---
while true; do
    get_header
    echo -e " 1) ПЕРЕУСТАНОВИТЬ (Fix 203/EXEC)"
    echo -e " 2) ЗАПУСТИТЬ WARP"
    echo -e " 3) ОСТАНОВИТЬ"
    echo -e " 6) Логи (Journalctl)"
    echo -e " 13) СБРОС СЕТИ И УДАЛЕНИЕ"
    echo -e " 0) Выход"
    
    read -p " Выбор: " choice
    case $choice in
        1) full_install ;;
        2) routing_up ;;
        3) routing_down ;;
        6) journalctl -u warp-plus -n 20 --no-pager; read -p "Enter..." ;;
        13) routing_down; rm -f "$BIN_PATH" /etc/systemd/system/warp-plus.service; echo "Стерто."; sleep 1 ;;
        0) exit 0 ;;
    esac
done
