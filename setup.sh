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

# Автоопределение основного интерфейса (ens3, eth0 и т.д.)
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

show_header() {
    clear
    echo -e "${CYAN}═══ WarpGo: Менеджер Cloudflare WARP ═══${NC}"
    echo -e "Интерфейс: ${YELLOW}$MAIN_IFACE${NC} | Подсеть: ${YELLOW}$AMN_SUBNET${NC}"
    echo ""
}

check_update() {
    echo -e "${YELLOW}Проверка обновлений...${NC}"
    curl -sL "$GITHUB_RAW" -o /tmp/WarpGo_check.sh
    
    if ! diff -q "$LOCAL_PATH" /tmp/WarpGo_check.sh > /dev/null; then
        echo -e "${CYAN}Найдено обновление для WarpGo!${NC}"
        echo -e "1) ${GREEN}Установить обновление${NC}"
        echo -e "2) Описание изменений"
        echo -e "0) Назад"
        read -p "Выберите действие: " up_choice
        
        case $up_choice in
            1)
                sudo mv /tmp/WarpGo_check.sh "$LOCAL_PATH"
                sudo chmod +x "$LOCAL_PATH"
                echo -e "${GREEN}WarpGo успешно обновлен! Перезапустите команду.${NC}"
                exit 0
                ;;
            2)
                echo -e "${YELLOW}Что нового:${NC}"
                echo -e "- Переименовано в WarpGo"
                echo -e "- Автоопределение сетевого интерфейса ($MAIN_IFACE)"
                echo -e "- Оптимизация проверки обновлений"
                read -p "Нажмите Enter..."
                ;;
        esac
    else
        echo -e "${GREEN}У вас самая свежая версия WarpGo.${NC}"
        sleep 1.5
    fi
}

show_menu() {
    echo -e "${YELLOW}Главное меню:${NC}"
    echo -e "1) ${GREEN}Установить WARP (tun2socks)${NC}"
    echo -e "2) ${GREEN}Запустить маршрутизацию (UP)${NC}"
    echo -e "3) ${RED}Остановить маршрутизацию (DOWN)${NC}"
    echo -e "4) 📊 Статус системы"
    echo -e "5) 📋 Настройки для 3X-UI (JSON)"
    echo -e "--------------------------------"
    echo -e "12) 🔄 Проверить обновление WarpGo"
    echo -e "11) ⚠️ Полное удаление"
    echo -e "0) Выход"
    echo -n "Выберите пункт: "
}

install_warp() {
    echo -e "${GREEN}Установка компонентов...${NC}"
    VERSION=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q --show-progress "https://github.com/xjasonlyu/tun2socks/releases/download/$VERSION/tun2socks-linux-amd64.zip" -O tun2socks.zip
    apt update && apt install unzip -y
    unzip -o tun2socks.zip
    mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=WarpGo Tun2Socks Service
After=network.target

[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface $MAIN_IFACE
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tun2socks
    systemctl start tun2socks
    echo -e "${GREEN}Установка WarpGo завершена!${NC}"
    read -p "Нажмите Enter..."
}

routing_up() {
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then
        echo "100 warp" >> /etc/iproute2/rt_tables
    fi
    ip route flush table warp
    ip route add default via 192.168.100.2 dev $TUN_DEV table warp
    ip rule add dport $AMN_PORT priority 5 table main 2>/dev/null
    ip rule add sport $AMN_PORT priority 6 table main 2>/dev/null
    ip rule add from $AMN_SUBNET priority 100 table warp 2>/dev/null
    
    iptables -t nat -I POSTROUTING -s $AMN_SUBNET ! -d $AMN_SUBNET -j MASQUERADE
    iptables -t nat -I PREROUTING -i amn0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    echo -e "${GREEN}Маршруты WarpGo активны!${NC}"
    read -p "Нажмите Enter..."
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршрутизация WarpGo отключена.${NC}"
    read -p "Нажмите Enter..."
}

show_status() {
    echo -e "${CYAN}--- Статус tun2socks ---${NC}"
    systemctl is-active tun2socks
    echo -e "${CYAN}--- Правила IP Rule ---${NC}"
    ip rule show | grep -E "warp|main"
    echo -e "${CYAN}--- Интерфейс ---${NC}"
    ip addr show $TUN_DEV 2>/dev/null | grep "inet " || echo "tun0 не активен"
    read -p "Нажмите Enter..."
}

show_json() {
    echo -e "${YELLOW}Скопируйте это в Outbounds (3X-UI):${NC}"
    echo '{"protocol": "socks","settings": {"servers": [{ "address": "127.0.0.1", "port": 40000 }]},"tag": "warp"}'
    read -p "Нажмите Enter..."
}

uninstall() {
    systemctl stop tun2socks && systemctl disable tun2socks
    rm /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks
    routing_down
    echo -e "${RED}WarpGo полностью удален.${NC}"
    read -p "Нажмите Enter..."
}

# Цикл меню
while true; do
    show_header
    show_menu
    read choice
    case $choice in
        1) install_warp ;;
        2) routing_up ;;
        3) routing_down ;;
        4) show_status ;;
        5) show_json ;;
        12) check_update ;;
        11) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}Ошибка!${NC}" && sleep 1 ;;
    esac
done
