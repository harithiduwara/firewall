#!/usr/bin/env python3
"""Network probe used by the test lab. Standard library only.

  probe.py serve SPEC [SPEC...]        SPEC = tcp:PORT | udp:PORT  (dual-stack)
  probe.py connect tcp|udp HOST PORT [--src ADDR] [--sport N] [--timeout S]
  probe.py rawtcp SRC DST DPORT FLAGS  send one crafted IPv4 TCP segment
  probe.py icmp6send DST               send an unsolicited ICMPv6 destination-unreachable
  probe.py icmp6listen TIMEOUT         exit 0 if an ICMPv6 destination-unreachable arrives

`serve` answers every TCP connection / UDP datagram with "ok <peer-ip>".
`connect` prints the peer IP the server saw and exits 0, or exits 1 if the
connection was blocked, refused or timed out.
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time


def _peer(addr):
    ip = addr[0]
    return ip[7:] if ip.startswith("::ffff:") else ip


def _listener(kind, port):
    stype = socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM
    if socket.has_ipv6 and os.path.exists("/proc/net/if_inet6"):
        s = socket.socket(socket.AF_INET6, stype)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.bind(("::", port))
    else:  # kernel without IPv6
        s = socket.socket(socket.AF_INET, stype)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
    if kind == "tcp":
        s.listen(64)
        while True:
            conn, addr = s.accept()
            with conn:
                conn.sendall(f"ok {_peer(addr)}\n".encode())
    else:
        while True:
            _data, addr = s.recvfrom(2048)
            s.sendto(f"ok {_peer(addr)}\n".encode(), addr)


def serve(specs):
    threads = []
    for spec in specs:
        kind, port = spec.split(":")
        t = threading.Thread(target=_listener, args=(kind, int(port)), daemon=True)
        t.start()
        threads.append(t)
    print("ready", flush=True)
    for t in threads:
        t.join()


def connect(kind, host, port, src, sport, timeout):
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM)
    family, stype, proto, _cn, sockaddr = infos[0]
    s = socket.socket(family, stype, proto)
    s.settimeout(timeout)
    try:
        if src or sport:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            bind_host = src or ("::" if family == socket.AF_INET6 else "0.0.0.0")
            s.bind((bind_host, sport or 0))
        if kind == "tcp":
            s.connect(sockaddr)
            data = s.recv(256)
        else:
            s.sendto(b"probe", sockaddr)
            data, _ = s.recvfrom(256)
    except OSError:
        return 1
    finally:
        s.close()
    text = data.decode(errors="replace").strip()
    if not text.startswith("ok "):
        return 1
    print(text[3:])
    return 0


def _csum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def rawtcp(src, dst, dport, flags):
    bits = {"F": 0x01, "S": 0x02, "R": 0x04, "P": 0x08, "A": 0x10}
    fl = sum(bits[c] for c in flags)
    sport = 40000
    tcp = struct.pack("!HHIIBBHHH", sport, dport, 1234, 5678, 5 << 4, fl, 64240, 0, 0)
    pseudo = struct.pack("!4s4sBBH", socket.inet_aton(src), socket.inet_aton(dst), 0, socket.IPPROTO_TCP, len(tcp))
    tcp = tcp[:16] + struct.pack("!H", _csum(pseudo + tcp)) + tcp[18:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), 1, 0, 64, socket.IPPROTO_TCP, 0,
                     socket.inet_aton(src), socket.inet_aton(dst))
    ip = ip[:10] + struct.pack("!H", _csum(ip)) + ip[12:]
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_RAW)
    s.sendto(ip + tcp, (dst, 0))
    s.close()
    return 0


ICMP6_DST_UNREACH = 1


def icmp6send(dst):
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    # type, code, checksum (filled in by the kernel), unused, then a fake
    # "invoking packet" (an IPv6 header plus 8 bytes).
    s.sendto(struct.pack("!BBHI", ICMP6_DST_UNREACH, 0, 0, 0) + bytes(48), (dst, 0))
    s.close()
    return 0


def icmp6listen(timeout):
    s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
    deadline = time.monotonic() + timeout
    print("ready", flush=True)
    while (left := deadline - time.monotonic()) > 0:
        s.settimeout(left)
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            break
        if data and data[0] == ICMP6_DST_UNREACH:
            print(addr[0])
            return 0
    return 1


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sv = sub.add_parser("serve")
    sv.add_argument("specs", nargs="+")
    c = sub.add_parser("connect")
    c.add_argument("kind", choices=["tcp", "udp"])
    c.add_argument("host")
    c.add_argument("port", type=int)
    c.add_argument("--src")
    c.add_argument("--sport", type=int, default=0)
    c.add_argument("--timeout", type=float, default=2.0)
    r = sub.add_parser("rawtcp")
    r.add_argument("src")
    r.add_argument("dst")
    r.add_argument("dport", type=int)
    r.add_argument("flags")
    i6s = sub.add_parser("icmp6send")
    i6s.add_argument("dst")
    i6l = sub.add_parser("icmp6listen")
    i6l.add_argument("timeout", type=float)
    a = p.parse_args()
    if a.cmd == "serve":
        serve(a.specs)
        return 0
    if a.cmd == "connect":
        return connect(a.kind, a.host, a.port, a.src, a.sport, a.timeout)
    if a.cmd == "icmp6send":
        return icmp6send(a.dst)
    if a.cmd == "icmp6listen":
        return icmp6listen(a.timeout)
    return rawtcp(a.src, a.dst, a.dport, a.flags)


if __name__ == "__main__":
    sys.exit(main())
