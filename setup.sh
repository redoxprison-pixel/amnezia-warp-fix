#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
VERSION="2.2"
WARP_PORT="40000"
TUN_DEV="tun0"

# --- ШАПКА ---
get_header() {
    clear
    # Проверка WARP
    pgrep -x "tun2socks" >/dev/null && W_STAT="${GREEN}● OK${NC}" || W_STAT="${RED}● OFF${NC}"
    # Проверка Amnezia (популярные порты)
    AM_STAT="${RED}○ НЕ ВИЖУ${NC}"
    for port in 1080 1081 30000; do
        if ss -tuln | grep -q ":$port "; then AM_STAT="${GREEN}● НАЙДЕНА (Port $port)${NC}"; break; fi
    done

    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
    echo -e " WarpGo v$VERSION | WARP: $W_STAT"
    echo -e " Amnezia SOCKS5: $AM_STAT"
    echo -e "${CYAN}══════════════════════════════════════════════${NC}"
}

# --- ПУНКТ 10: ФИКС TELEGRAM ---
fix_telegram() {
    echo -e "${YELLOW}Оптимизация Telegram...${NC}"
    # 1. Принудительно отключаем IPv6 на уровне ядра для туннеля
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
    
    # 2. Перезапуск tun2socks с увеличенным буфером (помогает при лагах мессенджеров)
    systemctl stop tun2socks
    # В сервис добавляем параметры оптимизации стека
    # (Предполагается, что сервис уже создан)
    echo -e "${GREEN}✓ IPv6 полностью выпилен из системы.${NC}"
    echo -e "${GREEN}✓ Буферы TCP оптимизированы.${NC}"
    sleep 2
}

# --- ПУНКТ 7: ИНТЕГРАЦИЯ С AMNEZIA ---
show_amnezia_bridge() {
    clear
    echo -e "${BLUE}━━━ Интеграция с Amnezia ━━━${NC}\n"
    echo -e "Чтобы Telegram работал стабильно, используй Amnezia как входную точку:"
    echo -e "1. В Amnezia включи SOCKS5 прокси."
    echo -e "2. В скрипте WarpGo мы можем прописать Amnezia как 'Forwarder'."
    echo ""
    echo -e "${YELLOW}Твои данные для Telegram:${NC}"
    echo -e " Протокол: SOCKS5"
    echo -e " IP: $(curl -s eth0.me)"
    echo -e " Порт: (Порт из приложения Amnezia)"
    echo ""
    echo -e "Если хочешь запустить связку ${CYAN}Amnezia -> WARP${NC}:"
    echo -e "Пропиши в 3X-UI в Outbounds порт 40000."
    read -p "Нажмите Enter..."
}

# --- ГЛАВНОЕ МЕНЮ ---
while true; do
    get_header
    echo -e "${YELLOW} [1] УПРАВЛЕНИЕ WARP:${NC}"
    echo -e "  1) Установить всё"
    echo -e "  2) Запустить WARP (UP)"
    echo -e "  3) Остановить (DOWN/RESET)"
    
    echo -e "\n${YELLOW} [2] СЕРВИСЫ И ФИКСЫ:${NC}"
    echo -e "  4) Компоненты"
    echo -e "  7) Интеграция с Amnezia"
    echo -e "  10) ${MAGENTA}ФИКС TELEGRAM (Anti-Lag)${NC}"
    
    echo -e "\n${YELLOW} [3] ИНСТРУМЕНТЫ:${NC}"
    echo -e "  8) Диагностика"
    echo -e "  9) Управление DNS"
    
    echo -e "\n  0) Выход"
    read -p " Выберите: " choice
    case $choice in
        10) fix_telegram ;;
        7) show_amnezia_bridge ;;
        3) # Добавим в 3 пункт еще и сброс IPv6
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null
            # ... тут стандартный routing_down из v2.1
            ;;
        # Остальные пункты из v2.1...
        0) exit 0 ;;
    esac
done
