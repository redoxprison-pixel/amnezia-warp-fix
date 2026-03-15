#!/bin/bash
# WARP SOCKS5 Installer (Clean Version)

# 1. Подготовка системы
apt-get update && apt-get install -y curl gpg lsb-release

# 2. Добавление официального репозитория Cloudflare
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list

# 3. Установка
apt-get update && apt-get install -y cloudflare-warp

# 4. Настройка в режиме SOCKS5 (Порт 40000)
# Эти команды — сердце алгоритма из твоего файла
warp-cli --accept-tos registration new 2>/dev/null
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect

# 5. Проверка
echo "------------------------------------------------"
echo "Проверка прокси (должен быть IP Cloudflare):"
curl -s4 --proxy socks5h://127.0.0.1:40000 ifconfig.me
echo -e "\n------------------------------------------------"
