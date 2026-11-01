FROM govpn-warp-test:local
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd && rm -rf /var/lib/apt/lists/*
