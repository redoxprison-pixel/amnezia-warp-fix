#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Конфигурация
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/WarpGo"
AMN_SUBNET="172.29.172.0/24"
AMN_PORT="47684"
WARP_PORT="40000"
TUN_DEV="tun0"
LOG_FILE="/var/log/tun2socks.log"

MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
check_deps() {
    echo -e "${CYAN}Проверка системных компонентов...${NC}"
    DEPS=("curl" "wget" "unzip" "iptables" "conntrack")
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}Установка: $dep...${NC}"
            apt update && apt install $dep -y
        fi
    done
}

# --- ПРОВЕРКА IP ---
check_ips() {
    echo -e "${CYAN}--- Статус IP ---${NC}"
    REAL_IP=$(curl -s --interface $MAIN_IFACE eth0.me || echo "Ошибка")
    WARP_IP=$(curl -s --proxy socks5h://127.0.0.1:$WARP_PORT eth0.me || echo "ВЫКЛ")
    
    echo -e "IP Сервера: ${YELLOW}$REAL_IP${NC}"
    echo -e "IP WARP:    ${GREEN}$WARP_IP${NC}"
    echo "--------------------------"
}

# --- МЕНЕДЖЕР ЛОГОВ ---
manage_logs() {
    clear
    echo -e "${CYAN}══ Менеджер Логов ══${NC}"
    echo -e "1) Просмотр логов (Ctrl+C для выхода)"
    echo -e "2) Очистить файл логов"
    echo -e "3) Настроить автоудаление (Logrotate)"
    echo -e "0) Назад"
    read -p "Выбор: " log_choice
    case $log_choice in
        1) tail -n 50 -f $LOG_FILE ;;
        2) cat /dev/null > $LOG_FILE && echo "Логи очищены." && sleep 1 ;;
        3) 
            cat <<EOF > /etc/logrotate.d/tun2socks
$LOG_FILE {
    size 10M
    rotate 3
    copytruncate
    compress
    missingok
}
EOF
            echo "Автоудаление настроено." && sleep 1 ;;
    esac
}

# --- РЕГИСТРАЦИЯ WARP ---
register_warp() {
    echo -e "${YELLOW}Регистрация аккаунта Cloudflare WARP...${NC}"
    wget -q --show-progress https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    yes | /usr/local/bin/wgcf register
    /usr/local/bin/wgcf generate
    echo -e "${GREEN}Готово! Профиль: /etc/WarpGo/wgcf-profile.conf${NC}"
    sleep 2
}

# --- МАРШРУТЫ ---
routing_up() {
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then echo "100 warp" >> /etc/iproute2/rt_tables; fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev $TUN_DEV table warp
    ip rule add dport $AMN_PORT priority 5 table main 2>/dev/null
    ip rule add sport $AMN_PORT priority 6 table main 2>/dev/null
    ip rule add from $AMN_SUBNET priority 100 table warp 2>/dev/null
    iptables -t nat -I POSTROUTING -s $AMN_SUBNET ! -d $AMN_SUBNET -j MASQUERADE
    iptables -t nat -I PREROUTING -i amn0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    conntrack -F &>/dev/null
    echo -e "${GREEN}Маршруты подняты!${NC}"
    sleep 1
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршрутизация отключена.${NC}"
    sleep 1
}

# --- УСТАНОВКА ---
install_all() {
    check_deps
    register_warp
    echo -e "${GREEN}Установка tun2socks...${NC}"
    VERSION=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q --show-progress "https://github.com/xjasonlyu/tun2socks/releases/download/$VERSION/tun2socks-linux-amd64.zip" -O tun2socks.zip
    unzip -o tun2socks.zip && mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Service
After=network.target

[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable tun2socks && systemctl start tun2socks
    routing_up
    echo -e "${GREEN}Установка завершена!${NC}"
    read -p "Нажмите Enter для возврата..."
}

# --- ОБНОВЛЕНИЕ ---
check_update() {
    echo -e "${YELLOW}Проверка обновлений...${NC}"
    curl -sL "$GITHUB_RAW" -o /tmp/WarpGo_upd.sh
    if ! diff -q "$LOCAL_PATH" /tmp/WarpGo_upd.sh > /dev/null; then
        echo -e "${CYAN}Найдена новая версия!${NC}"
        read -p "Обновить? (y/n): " confirm
        if [[ $confirm == "y" ]]; then
            mv /tmp/WarpGo_upd.sh "$LOCAL_PATH" && chmod +x "$LOCAL_PATH"
            echo -e "${GREEN}WarpGo обновлен. Перезапустите его.${NC}"
            exit 0
        fi
    else
        echo -e "${GREEN}Обновлений нет.${NC}"
        sleep 1
    fi
}

# --- ГЛАВНЫЙ ЦИКЛ МЕНЮ ---
while true; do
    clear
    echo -e "${CYAN}═══ WarpGo v3.1 ═══${NC}"
    check_ips
    echo -e "1) ${GREEN}Полная установка (Soft + WARP)${NC}"
    echo -e "2) Включить маршруты (UP)"
    echo -e "3) Выключить маршруты (DOWN)"
    echo -e "4) Настройки 3X-UI (JSON)"
    echo -e "5) Перевыпустить ключи WARP"
    echo -e "6) Менеджер Логов"
    echo -e "--------------------------------"
    echo -e "12) Обновить WarpGo"
    echo -e "11) ${RED}Удалить всё${NC}"
    echo -e "0) Выход"
    read -p "Выбор: " choice

    case $choice in
        1) install_all ;;
        2) routing_up ;;
        3) routing_down ;;
        4) echo '{"protocol": "socks","settings": {"servers": [{ "address": "127.0.0.1", "port": 40000 }]},"tag": "warp"}' && read -p "Нажмите Enter..." ;;
        5) register_warp ;;
        6) manage_logs ;;
        11) 
            systemctl stop tun2socks && systemctl disable tun2socks
            rm -f /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks /usr/local/bin/wgcf
            rm -rf /etc/WarpGo
            routing_down
            echo "Все компоненты удалены." && sleep 2 ;;
        12) check_update ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный пункт!${NC}" && sleep 1 ;;
    esac
done
