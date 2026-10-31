"""Inject actual client packets on veth ingress and inspect the kernel path."""
import select
import socket
import struct
import sys
import time

source, expected = sys.argv[1:]
v6 = ':' in source
token = b'govpn-isolated-probe'
destination = '2001:db8:2::10' if v6 else '203.0.113.10'
udp = struct.pack('!HHHH', 43000, 9999, 8 + len(token), 0) + token
if v6:
    src, dst = socket.inet_pton(socket.AF_INET6, source), socket.inet_pton(socket.AF_INET6, destination)
    pseudo = src + dst + struct.pack('!I3xB', len(udp), 17)
else:
    src, dst = socket.inet_aton(source), socket.inet_aton(destination)

def checksum(data):
    if len(data) % 2:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff

if v6:
    value = checksum(pseudo + udp) or 65535
    udp = udp[:6] + struct.pack('!H', value) + udp[8:]
    packet = struct.pack('!IHBB16s16s', 6 << 28, len(udp), 17, 64, src, dst) + udp
else:
    header = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(udp), 1234, 0, 64, 17, 0, src, dst)
    header = header[:10] + struct.pack('!H', checksum(header)) + header[12:]
    packet = header + udp

listeners = {}
for dev in ('uplink', 'warp'):
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
        sock.bind((dev, 0))
        sock.setblocking(False)
        listeners[sock] = dev
    except OSError:
        if dev != 'warp':
            raise
mac = bytes.fromhex(open('/sys/class/net/awg0/address').read().strip().replace(':', ''))
sender_mac = bytes.fromhex(open('/sys/class/net/client0/address').read().strip().replace(':', ''))
sender = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
sender.bind(('client0', 0))
sender.send(mac + sender_mac + struct.pack('!H', 0x86dd if v6 else 0x800) + packet)
seen = set()
deadline = time.monotonic() + 0.6
while time.monotonic() < deadline:
    ready, _, _ = select.select(list(listeners), [], [], max(0, deadline - time.monotonic()))
    for sock in ready:
        if token in sock.recv(65535):
            seen.add(listeners[sock])
assert seen == (set() if expected == 'drop' else {expected}), (source, expected, seen)
print(source + ': ' + expected)
