#!/bin/bash

# Цвета и оформление
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

# --- БЛОК ПРОВЕРКИ ЗАВИСИМОСТЕЙ ---
check_dependencies() {
    echo -e "${CYAN}Проверка системных компонентов...${NC}"
    DEPS=("curl" "wget" "unzip" "iptables" "conntrack")
    for dep in "${DEPS[@]}"; do
        if ! command -v $dep &> /dev/null; then
            echo -e "${YELLOW}Установка недостающего компонента: $dep...${NC}"
            apt update && apt install $dep -y
        fi
    done
}

# --- БЛОК РАБОТЫ С IP ---
check_ips() {
    echo -e "${CYAN}--- Проверка IP адресов ---${NC}"
    REAL_IP=$(curl -s --interface $MAIN_IFACE eth0.me || echo "Ошибка")
    WARP_IP=$(curl -s --proxy socks5h://127.0.0.1:$WARP_PORT eth0.me || echo "ВЫКЛ")
    
    echo -e "IP Сервера: ${YELLOW}$REAL_IP${NC}"
    echo -e "IP WARP:    ${GREEN}$WARP_IP${NC}"
    echo "--------------------------"
}

# --- БЛОК ЛОГОВ ---
manage_logs() {
    show_header
    echo -e "1) Просмотр логов в реальном времени (Ctrl+C для выхода)"
    echo -e "2) Полная очистка файла логов"
    echo -e "3) Настроить автоудаление (Logrotate)"
    echo -e "0) Назад"
    read -p "Выберите: " log_choice
    case $log_choice in
        1) tail -f $LOG_FILE ;;
        2) cat /dev/null > $LOG_FILE && echo "Логи очищены." ;;
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
            echo "Автоудаление настроено (макс. 3 файла по 10МБ)."
            ;;
    esac
}

# --- ГЕНЕРАЦИЯ КЛЮЧЕЙ WARP (WGCF) ---
register_warp() {
    echo -e "${YELLOW}Регистрация аккаунта Cloudflare WARP...${NC}"
    wget -q --show-progress https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 -O /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
    mkdir -p /etc/WarpGo && cd /etc/WarpGo
    yes | /usr/local/bin/wgcf register
    /usr/local/bin/wgcf generate
    echo -e "${GREEN}Ключи сгенерированы в /etc/WarpGo/wgcf-profile.conf${NC}"
    read -p "Enter..."
}

# --- ГЛАВНОЕ МЕНЮ ---
show_header() {
    clear
    echo -e "${CYAN}═══ WarpGo v3.0: Ultra Edition ═══${NC}"
    check_ips
}

show_menu() {
    echo -e "${YELLOW}Управление:${NC}"
    echo -e "1) ${GREEN}Полная установка (Soft + WARP)${NC}"
    echo -e "2) ${GREEN}Включить маршруты (UP)${NC}"
    echo -e "3) ${RED}Выключить маршруты (DOWN)${NC}"
    echo -e "4) 📋 Настройки для 3X-UI"
    echo -e "5) 🔑 Перевыпустить ключи WARP"
    echo -e "6) 📝 Менеджер Логов"
    echo -e "--------------------------------"
    echo -e "12) 🔄 Обновить WarpGo"
    echo -e "11) ⚠️ Удалить всё"
    echo -e "0) Выход"
    echo -n "Выбор: "
}

# --- ФУНКЦИИ УСТАНОВКИ И МАРШРУТОВ ---
install_warp() {
    check_dependencies
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
}

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
    echo -e "${GREEN}WarpGo запущен!${NC}"
}

routing_down() {
    ip rule del priority 5 2>/dev/null
    ip rule del priority 6 2>/dev/null
    ip rule del priority 100 2>/dev/null
    echo -e "${YELLOW}Маршрутизация отключена.${NC}"
}

uninstall() {
    systemctl stop tun2socks && systemctl disable tun2socks
    rm /etc/systemd/system/tun2socks.service /usr/local/bin/tun2socks /usr/local/bin/wgcf
    rm -rf /etc/WarpGo
    routing_down
    echo -e "${RED}WarpGo полностью удален.${NC}"
}

# (Вставь сюда функцию check_update из прошлого ответа, поправив локальные пути)

# Главный цикл
while true; do
    show_header
    show_menu
    read choice
    case $choice in
        1) install_warp ;;
        2) routing_up ;;
        3) routing_down ;;
        4) echo '{"protocol": "socks","settings": {"servers": [{ "address": "127.0.0.1", "port": 40000 }]},"tag": "warp"}' && read ;;
        5) register_warp ;;
        6) manage_logs ;;
        11) uninstall ;;
        0) exit 0 ;;
    esac
done#!/bin/bash

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
