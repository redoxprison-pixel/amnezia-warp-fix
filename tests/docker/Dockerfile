FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 iptables wireguard-tools python3 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY tests/docker/fixture-network /usr/local/bin/fixture-network
COPY tests/docker/wg-quick /usr/local/bin/wg-quick
COPY tests/docker/start.sh /opt/amnezia/start.sh
COPY tests/docker/awg0.conf /opt/amnezia/awg/awg0.conf
COPY tests/docker/probe.py /usr/local/bin/probe.py
RUN chmod 755 /usr/local/bin/fixture-network /usr/local/bin/wg-quick /opt/amnezia/start.sh
ENTRYPOINT ["/bin/sh", "/opt/amnezia/start.sh"]
