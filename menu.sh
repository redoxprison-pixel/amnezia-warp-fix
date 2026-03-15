#!/bin/bash

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Параметры
PORT=40000
TUN_DEV="tun0"
SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -n1 || echo 22)

# Функция защиты SSH
setup_ssh_safety() {
    echo -e "${YELLOW}Настройка защиты SSH (порт $SSH_PORT)...${NC}"
    # Получаем IP шлюза и интерфейс провайдера
    GATEWAY=$(ip route show default | awk '/default/ {print $3}')
    INTERFACE=$(ip route show default | awk '/default/ {print $5}')
    
    # Прямой маршрут для твоего текущего подключения, чтобы не вылететь
    CURRENT_IP=$(echo $SSH_CLIENT | awk '{print $1}')
    if [ ! -z "$CURRENT_IP" ]; then
        ip route add $CURRENT_IP via $GATEWAY dev $INTERFACE > /dev/null 2>&1
    fi
    
    # Общее правило: трафик SSH всегда идет через основной шлюз
    iptables -t mangle -A OUTPUT -p tcp --sport $SSH_PORT -j ACCEPT
    echo -e "${GREEN}SSH защищен.${NC}"
}

up_tun() {
    echo -e "${YELLOW}Очистка ресурсов...${NC}"
    killall tun2socks > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    sleep 1

    setup_ssh_safety

    echo -e "${YELLOW}Запуск Tun2Socks на $TUN_DEV...${NC}"
    
    # 1. Создаем интерфейс
    ip tuntap add dev $TUN_DEV mode tun
    ip addr add 10.0.0.1/24 dev $TUN_DEV
    ip link set $TUN_DEV up

    # 2. Запускаем tun2socks (используем логи для отладки)
    nohup tun2socks -proxy socks5://127.0.0.1:$PORT -interface $TUN_DEV -loglevel info > /var/log/tun2socks.log 2>&1 &
    sleep 2

    # 3. Маршрутизация через таблицу 100
    # Мы не меняем основной шлюз системы (default), чтобы не потерять SSH.
    # Мы создаем маршрут только для тех, кто явно хочет идти через tun0.
    ip route add default dev $TUN_DEV table 100
    ip rule add from 10.0.0.0/24 lookup 100
    
    # Тестовый пинг через туннель
    echo -e "${CYAN}Проверка туннеля...${NC}"
    if ping -I $TUN_DEV -c 2 8.8.8.8 > /dev/null 2>&1; then
        echo -e "${GREEN}УСПЕХ: Туннель работает!${NC}"
    else
        echo -e "${RED}ОШИБКА: Пинг через туннель не прошел.${NC}"
        echo -e "Проверь: warp-cli status"
    fi
}

down_tun() {
    echo -e "${YELLOW}Отключение туннеля...${NC}"
    killall tun2socks > /dev/null 2>&1
    ip rule del lookup 100 > /dev/null 2>&1
    ip route flush table 100 > /dev/null 2>&1
    ip link delete $TUN_DEV > /dev/null 2>&1
    echo -e "${GREEN}Готово. Система в исходном состоянии.${NC}"
}

# Меню
clear
echo -e "${CYAN}=== Tun2Socks Safe Manager ===${NC}"
echo -e "1) Поднять туннель (с защитой SSH)"
echo -e "2) Положить туннель"
echo -e "0) Выход"
read -p "Выбор: " ch

case $ch in
    1) up_tun ;;
    2) down_tun ;;
    *) exit 0 ;;
esac
