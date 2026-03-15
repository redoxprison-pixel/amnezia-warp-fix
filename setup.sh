#!/bin/bash
# WARP + Tun2Socks Setup (Aeza Ubuntu 24.04)

# Цвета
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'; RED='\033[0;31m'

echo -e "${YELLOW}Начинаю установку базовых компонентов...${NC}"

# 1. Обновление и зависимости
apt update && apt install -y curl gpg lsb-release unzip iptables sed

# 2. Установка Cloudflare WARP
echo -e "${YELLOW}Установка Cloudflare WARP...${NC}"
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp

# 3. Установка Tun2Socks
echo -e "${YELLOW}Установка Tun2Socks...${NC}"
ARCH=$(uname -m)
if [ "$ARCH" == "x86_64" ]; then
    URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip"
else
    URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-arm64.zip"
fi

curl -L "$URL" -o /tmp/t2s.zip && unzip -o /tmp/t2s.zip -d /tmp/
mv /tmp/tun2socks-linux-* /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks

# 4. Настройка WARP
echo -e "${YELLOW}Регистрация и настройка WARP в режиме прокси...${NC}"
warp-cli --accept-tos registration new 2>/dev/null
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect

echo -e "${GREEN}Настройка завершена! Используйте команду 'warp' для управления.${NC}"
