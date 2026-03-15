#!/bin/bash
# Universal WARP-SOCKS for 3X-UI & Amnezia

# 1. Установка официального репозитория
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list

# 2. Установка пакета
apt-get update && apt-get install -y cloudflare-warp

# 3. Настройка (как в твоем файле)
warp-cli --accept-tos registration new 2>/dev/null || echo "Уже в сети"
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect

echo "------------------------------------------------"
echo "Проверка через прокси (должен быть IP Cloudflare):"
curl -s4 --proxy socks5h://127.0.0.1:40000 ifconfig.me
echo -e "\n------------------------------------------------"
