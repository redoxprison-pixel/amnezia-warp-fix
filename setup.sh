#!/bin/bash

# Цвета
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Ссылки и конфиг
GITHUB_RAW="https://raw.githubusercontent.com/redoxprison-pixel/amnezia-warp-fix/main/setup.sh"
LOCAL_PATH="/usr/local/bin/warp-manager"
AMN_SUBNET="172.29.172.0/24"
AMN_PORT="47684"
WARP_PORT="40000"
TUN_DEV="tun0"

show_header() {
    clear
    echo -e "${CYAN}═══ CLOUDFLARE WARP MANAGER ═══${NC}"
    echo -e "Инструмент для маршрутизации Amnezia/3X-UI через WARP"
    echo ""
}

# --- НОВЫЙ БЛОК: ОБНОВЛЕНИЕ ---
check_update() {
    echo -e "${YELLOW}Проверка обновлений...${NC}"
    # Скачиваем временную версию для сравнения
    curl -sL "$GITHUB_RAW" -o /tmp/warp_check.sh
    
    if ! diff -q "$LOCAL_PATH" /tmp/warp_check.sh > /dev/null; then
        echo -e "${CYAN}Найдена новая версия скрипта!${NC}"
        echo -e "Что нового: Исправление багов, улучшенное меню и стабильность."
        echo ""
        echo "1) Установить обновление"
        echo "2) Описание обновления"
        echo "0) Отмена (назад в меню)"
        echo -n "Выберите действие: "
        read up_choice
        
        case $up_choice in
            1)
                sudo mv /tmp/warp_check.sh "$LOCAL_PATH"
                sudo chmod +x "$LOCAL_PATH"
                echo -e "${GREEN}Скрипт успешно обновлен! Перезапустите его.${NC}"
                exit 0
                ;;
            2)
                echo -e "${YELLOW}Описание:${NC} Оптимизация маршрутов, фикс утечки DNS и кнопка авто-апдейта."
                read -p "Нажмите Enter для возврата..."
                ;;
            *)
                return
                ;;
        esac
    else
        echo -e "${GREEN}У вас установлена актуальная версия.${NC}"
        sleep 2
    fi
}

show_menu() {
    echo -e "${YELLOW}Меню управления:${NC}"
    echo -e "1) ${GREEN}Установить WARP${NC}"
    echo -e "2) ${GREEN}Запустить маршрутизацию${NC}"
    echo -e "3) ${RED}Остановить маршрутизацию${NC}"
    echo -e "4) 📊 Статус и конфигурация"
    echo -e "5) 📋 JSON для 3X-UI Outbound"
    echo -e "--------------------------------"
    echo -e "12) 🔄 Проверить обновление"
    echo -e "11) ⚠️ Полное удаление"
    echo -e "0) Выход"
    echo -n "Выберите пункт: "
}

# --- ФУНКЦИИ УПРАВЛЕНИЯ (БЕЗ ИЗМЕНЕНИЙ) ---
install_warp() {
    echo -e "${GREEN}Установка...${NC}"
    VERSION=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget -q --show-progress "https://github.com/xjasonlyu/tun2socks/releases/download/$VERSION/tun2socks-linux-amd64.zip" -O tun2socks.zip
    apt update && apt install unzip -y
    unzip -o tun2socks.zip
    mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    
    cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=Tun2Socks Warp Service
After=network.target

[Service]
ExecStart=/usr/local/bin/tun2socks -device $TUN_DEV -proxy socks5://127.0.0.1:$WARP_PORT -interface ens3
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tun2socks
    systemctl start tun2socks
    echo -e "${GREEN}Готово!${NC}"
    read -p "Enter..."
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
    echo -e "${GREEN}Маршрутизация включена!${NC}"
    read -p "Enter..."
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршрутизация отключена.${NC}"
    read -p "Enter..."
}

show_status() {
    echo -e "${CYAN}--- Статус сервиса tun2socks ---${NC}"
    systemctl is-active tun2socks
    echo -e "${CYAN}--- Активные правила ip rule ---${NC}"
    ip rule show | grep -E "warp|main"
    read -p "Enter..."
}

show_json() {
    echo -e "${YELLOW}Outbound для 3X-UI:${NC}"
    echo '{"protocol": "socks","settings": {"servers": [{ "address": "127.0.0.1", "port": 40000 }]},"tag": "warp"}'
    read -p "Enter..."
}

uninstall() {
    systemctl stop tun2socks
    systemctl disable tun2socks
    rm /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks
    routing_down
    echo -e "${RED}Удалено.${NC}"
    read -p "Enter..."
}

# Главный цикл
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
