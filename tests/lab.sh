# shellcheck shell=bash
# Virtual home network built from Linux network namespaces.
#
#   hf-inet  (internet / attacker on the ISP segment)
#      | eth0 11.0.0.2   2a00:1::2
#      |
#      | wan0 11.0.0.1   2a00:1::1
#   hf-fw    (the router running the firewall)
#      | lan0   192.168.1.1   2a00:2:0:1::1  ── hf-lan   eth0 192.168.1.10   2a00:2:0:1::10
#      | guest0 192.168.20.1  2a00:2:0:20::1 ── hf-guest eth0 192.168.20.10  2a00:2:0:20::10
#      | iot0   192.168.30.1  2a00:2:0:30::1 ── hf-iot   eth0 192.168.30.10  2a00:2:0:30::10
#
# 11.0.0.0/8 and 2a00::/16 are used because they are NOT bogons, so the bogon
# filter does not interfere with ordinary "internet" traffic in the lab.

LAB_NS=(hf-inet hf-fw hf-lan hf-guest hf-iot)

v6on() { if ((HAVE_IPV6)); then "$@"; fi; }

in_ns() { local ns=$1; shift; ip netns exec "${ns}" "$@"; }

lab_down() {
    local ns
    for ns in "${LAB_NS[@]}"; do
        if ip netns pids "${ns}" >/dev/null 2>&1; then
            ip netns pids "${ns}" | xargs -r kill 2>/dev/null || true
        fi
        ip netns del "${ns}" 2>/dev/null || true
    done
}

_link() { # fw-ifname peer-ns
    ip link add "$1" netns hf-fw type veth peer name eth0 netns "$2"
    in_ns hf-fw ip link set "$1" up
    in_ns "$2" ip link set eth0 up
}

lab_up() {
    lab_down
    local ns
    for ns in "${LAB_NS[@]}"; do
        ip netns add "${ns}"
        in_ns "${ns}" ip link set lo up
    done

    _link wan0 hf-inet
    _link lan0 hf-lan
    _link guest0 hf-guest
    _link iot0 hf-iot

    in_ns hf-fw ip addr add 11.0.0.1/24 dev wan0
    v6on in_ns hf-fw ip addr add 2a00:1::1/64 dev wan0 nodad
    in_ns hf-fw ip route add default via 11.0.0.2
    v6on in_ns hf-fw ip -6 route add default via 2a00:1::2

    in_ns hf-inet ip addr add 11.0.0.2/24 dev eth0
    v6on in_ns hf-inet ip addr add 2a00:1::2/64 dev eth0 nodad
    # An attacker next to us on the ISP segment trying to route straight in.
    in_ns hf-inet ip route add 192.168.0.0/16 via 11.0.0.1
    v6on in_ns hf-inet ip -6 route add 2a00:2::/48 via 2a00:1::1

    local zone net
    for zone in lan:1 guest:20 iot:30; do
        net=${zone#*:}; zone=${zone%:*}
        in_ns hf-fw ip addr add "192.168.${net}.1/24" dev "${zone}0"
        v6on in_ns hf-fw ip addr add "2a00:2:0:${net}::1/64" dev "${zone}0" nodad
        in_ns "hf-${zone}" ip addr add "192.168.${net}.10/24" dev eth0
        v6on in_ns "hf-${zone}" ip addr add "2a00:2:0:${net}::10/64" dev eth0 nodad
        in_ns "hf-${zone}" ip route add default via "192.168.${net}.1"
        v6on in_ns "hf-${zone}" ip -6 route add default via "2a00:2:0:${net}::1"
    done

    in_ns hf-fw sysctl -q -w net.ipv4.ip_forward=1
    v6on in_ns hf-fw sysctl -q -w net.ipv6.conf.all.forwarding=1

    # Servers: the "internet", one device per zone, and services on the router.
    _serve hf-inet  tcp:80 tcp:25 tcp:445 udp:137 udp:53 tcp:22
    _serve hf-lan   tcp:8080
    _serve hf-guest tcp:8080
    _serve hf-iot   tcp:8080
    _serve hf-fw    tcp:22 tcp:53 udp:53 udp:67 udp:68 udp:546 udp:547 tcp:8080
    # Let link-local addresses settle (they skip DAD only with nodad).
    sleep 2
}

_serve() {
    local ns=$1; shift
    in_ns "${ns}" python3 -I "${PROBE}" serve "$@" >/dev/null 2>&1 &
    for _ in $(seq 50); do
        # Wait until the first port is listening.
        in_ns "${ns}" ss -lntu 2>/dev/null | grep -q ":${1#*:} " && return 0
        sleep 0.1
    done
    echo "server in ${ns} did not start" >&2
    return 1
}

# load RULESET — load a ruleset into the router namespace with the lab zones.
load_ruleset() {
    in_ns hf-fw nft -I "${TESTS_DIR}/fixtures" -f "$1"
}

# probe NS tcp|udp HOST PORT [extra args]
probe() {
    local ns=$1; shift
    in_ns "${ns}" python3 -I "${PROBE}" connect "$@" --timeout "${PROBE_TIMEOUT:-1.5}"
}

# link_local NS IFNAME — the fe80:: address of an interface.
link_local() {
    in_ns "$1" ip -6 -o addr show dev "$2" scope link | awk '{print $4}' | cut -d/ -f1
}

# rule_packets CHAIN PATTERN — packet counter of the first rule matching PATTERN.
# Prints a huge negative number if no rule matches, so the calling check fails
# loudly instead of silently comparing against 0.
rule_packets() {
    local n
    n=$(in_ns hf-fw nft list chain inet filter "$1" | grep -F -- "$2" | head -n1 \
        | grep -o 'packets [0-9]*' | awk '{print $2}')
    if [[ -z $n ]]; then
        echo "rule_packets: no rule in chain '$1' matches '$2'" >&2
        echo -999999
    else
        echo "$n"
    fi
}
