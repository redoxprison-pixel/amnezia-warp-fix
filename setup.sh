#!/bin/bash
# Подготовка компонентов
apt update && apt install -y curl gpg lsb-release unzip iptables

# Установка официального WARP
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp

# Установка Tun2Socks
ARCH=$(uname -m)
[ "$ARCH" == "x86_64" ] && URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-amd64.zip"
[ "$ARCH" == "aarch64" ] && URL="https://github.com/xjasonlyu/tun2socks/releases/latest/download/tun2socks-linux-arm64.zip"
curl -L "$URL" -o /tmp/t2s.zip && unzip -o /tmp/t2s.zip -d /tmp/
mv /tmp/tun2socks-linux-* /usr/local/bin/tun2socks && chmod +x /usr/local/bin/tun2socks

# Регистрация WARP
warp-cli --accept-tos registration new 2>/dev/null
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect
