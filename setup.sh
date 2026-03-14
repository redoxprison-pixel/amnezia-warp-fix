#!/bin/bash

# Цвета для вывода
GREEN='\033[0;32m'
NC='\033[0m'

# Параметры (подставь свои, если отличаются)
AMN_SUBNET="172.29.172.0/24"
AMN_PORT="47684"
WARP_PORT="40000" # Порт, на котором слушает WARP/tun2socks
TUN_DEV="tun0"

set_routes() {
    echo -e "${GREEN}Настройка маршрутизации...${NC}"
    # Добавляем таблицу warp, если её нет
    if ! grep -q "100 warp" /etc/iproute2/rt_tables; then
        echo "100 warp" >> /etc/iproute2/rt_tables
    fi

    # Очищаем и создаем маршрут через tun0
    ip route flush table warp
    ip route add default via 192.168.100.2 dev $TUN_DEV table warp

    # Исключаем порт Amnezia из туннелирования (чтобы не терять связь)
    ip rule add dport $AMN_PORT priority 5 table main 2>/dev/null
    ip rule add sport $AMN_PORT priority 6 table main 2>/dev/null
    
    # Направляем трафик Amnezia в WARP
    ip rule add from $AMN_SUBNET priority 100 table warp 2>/dev/null

    # NAT и DNS
    iptables -t nat -I POSTROUTING -s $AMN_SUBNET ! -d $AMN_SUBNET -j MASQUERADE
    iptables -t nat -I PREROUTING -i amn0 -p udp --dport 53 -j DNAT --to-destination 1.1.1.1
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

install_tun2socks() {
    echo -e "${GREEN}Установка tun2socks с GitHub...${NC}"
    VERSION=$(curl -s https://api.github.com/repos/xjasonlyu/tun2socks/releases/latest | grep tag_name | cut -d '"' -f 4)
    wget "https://github.com/xjasonlyu/tun2socks/releases/download/$VERSION/tun2socks-linux-amd64.zip"
    apt update && apt install unzip -y
    unzip tun2socks-linux-amd64.zip
    mv tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    
    # Создание сервиса
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
}

case "$1" in
    install)
        install_tun2socks
        set_routes
        ;;
    up)
        set_routes
        ;;
    down)
        ip rule del priority 5 2>/dev/null
        ip rule del priority 6 2>/dev/null
        ip rule del priority 100 2>/dev/null
        echo "Маршрутизация через WARP отключена. Трафик идет напрямую."
        ;;
    *)
        echo "Использование: $0 {install|up|down}"
        ;;
esac
