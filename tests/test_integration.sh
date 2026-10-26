#!/usr/bin/env bash
# Live packet tests: build the virtual home network, load the real ruleset,
# and check every zone-to-zone path over IPv4 and IPv6.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lab.sh
source "${TESTS_DIR}/lab.sh"
require_root

trap lab_down EXIT
lab_up
load_ruleset "${ROOT_DIR}/src/nftables.conf" || { echo "ruleset failed to load" >&2; exit 1; }

INET4=11.0.0.2   INET6=2a00:1::2
FW_WAN4=11.0.0.1 FW_WAN6=2a00:1::1
FW_LAN4=192.168.1.1 FW_LAN6=2a00:2:0:1::1
LAN4=192.168.1.10 LAN6=2a00:2:0:1::10
GUEST4=192.168.20.10 GUEST6=2a00:2:0:20::10
IOT4=192.168.30.10 IOT6=2a00:2:0:30::10

nat_seen() { [[ $(probe "$@") == "$FW_WAN4" ]]; }
v6_seen()  { local want=$1; shift; [[ $(probe "$@") == "$want" ]]; }

# -----------------------------------------------------------------------------
section "LAN (trusted)"
check "FR-01"       "LAN -> internet TCP, IPv4, source NATed to router WAN address" nat_seen hf-lan tcp "$INET4" 80
v6 check "FR-01,FR-07" "LAN -> internet TCP, IPv6, routed without NAT"            v6_seen "$LAN6" hf-lan tcp "$INET6" 80
check "FR-03"       "LAN -> IoT device, IPv4"                                  probe hf-lan tcp "$IOT4" 8080
v6 check "FR-03"       "LAN -> IoT device, IPv6"                                  probe hf-lan tcp "$IOT6" 8080
check_not "SR-01"   "LAN -> guest device blocked, IPv4"                        probe hf-lan tcp "$GUEST4" 8080
v6 check_not "SR-01"   "LAN -> guest device blocked, IPv6"                        probe hf-lan tcp "$GUEST6" 8080
check "FR-05"       "LAN -> router SSH, IPv4"                                  probe hf-lan tcp "$FW_LAN4" 22
v6 check "FR-05"       "LAN -> router SSH, IPv6"                                  probe hf-lan tcp "$FW_LAN6" 22
check "FR-04"       "LAN -> router DNS over UDP"                               probe hf-lan udp "$FW_LAN4" 53
v6 check "FR-04"       "LAN -> router DNS over TCP, IPv6"                         probe hf-lan tcp "$FW_LAN6" 53
check "FR-04"       "LAN -> router DHCPv4 (udp 68 -> 67)"                      probe hf-lan udp "$FW_LAN4" 67 --sport 68
LL_FW_LAN=""; ((HAVE_IPV6)) && LL_FW_LAN=$(link_local hf-fw lan0)
v6 check "FR-04,FR-07" "LAN -> router DHCPv6 (link-local, udp 546 -> 547)"       probe hf-lan udp "${LL_FW_LAN}%eth0" 547 --sport 546
check_not "SR-01"   "LAN -> unlisted router port (tcp 8080) blocked"          probe hf-lan tcp "$FW_LAN4" 8080
check "FR-08"       "LAN -> ping router, IPv4"                                 in_ns hf-lan ping -c1 -W1 "$FW_LAN4"
v6 check "FR-08,FR-07" "LAN -> ping router, IPv6"                                 in_ns hf-lan ping -c1 -W1 "$FW_LAN6"

section "Egress hygiene"
check_not "SR-11"   "LAN -> internet SMB (tcp 445) blocked"                    probe hf-lan tcp "$INET4" 445
v6 check_not "SR-11"   "LAN -> internet SMB (tcp 445) blocked, IPv6"              probe hf-lan tcp "$INET6" 445
check_not "SR-11"   "LAN -> internet NetBIOS (udp 137) blocked"                probe hf-lan udp "$INET4" 137
check "SR-11"       "LAN -> internet SMTP (tcp 25) still allowed"              probe hf-lan tcp "$INET4" 25
check_not "SR-11"   "Guest -> internet SMTP (tcp 25) blocked"                  probe hf-guest tcp "$INET4" 25
v6 check_not "SR-11"   "IoT -> internet SMTP (tcp 25) blocked, IPv6"              probe hf-iot tcp "$INET6" 25

# -----------------------------------------------------------------------------
section "Guest"
check "FR-02"       "Guest -> internet, IPv4"                                  nat_seen hf-guest tcp "$INET4" 80
v6 check "FR-02"       "Guest -> internet, IPv6"                                  probe hf-guest tcp "$INET6" 80
check "FR-04"       "Guest -> router DNS"                                      probe hf-guest udp 192.168.20.1 53
check_not "SR-04"   "Guest -> LAN device blocked, IPv4"                        probe hf-guest tcp "$LAN4" 8080
v6 check_not "SR-04"   "Guest -> LAN device blocked, IPv6"                        probe hf-guest tcp "$LAN6" 8080
check_not "SR-04"   "Guest -> IoT device blocked, IPv4"                        probe hf-guest tcp "$IOT4" 8080
v6 check_not "SR-04"   "Guest -> IoT device blocked, IPv6"                        probe hf-guest tcp "$IOT6" 8080
check_not "SR-04"   "Guest -> router SSH blocked (guest gateway address)"      probe hf-guest tcp 192.168.20.1 22
check_not "SR-04"   "Guest -> router SSH blocked (router's LAN address)"       probe hf-guest tcp "$FW_LAN4" 22
v6 check_not "SR-04"   "Guest -> router SSH blocked, IPv6"                        probe hf-guest tcp 2a00:2:0:20::1 22
check "FR-08"       "Guest -> ping router"                                     in_ns hf-guest ping -c1 -W1 192.168.20.1

# -----------------------------------------------------------------------------
section "IoT"
check "FR-03"       "IoT -> internet, IPv4"                                    nat_seen hf-iot tcp "$INET4" 80
v6 check "FR-03"       "IoT -> internet, IPv6"                                    probe hf-iot tcp "$INET6" 80
check "FR-04"       "IoT -> router DNS over TCP"                               probe hf-iot tcp 192.168.30.1 53
check_not "SR-05"   "IoT -> LAN device blocked, IPv4"                          probe hf-iot tcp "$LAN4" 8080
v6 check_not "SR-05"   "IoT -> LAN device blocked, IPv6"                          probe hf-iot tcp "$LAN6" 8080
check_not "SR-05"   "IoT -> guest device blocked, IPv4"                        probe hf-iot tcp "$GUEST4" 8080
v6 check_not "SR-05"   "IoT -> guest device blocked, IPv6"                        probe hf-iot tcp "$GUEST6" 8080
check_not "SR-05"   "IoT -> router SSH blocked"                                probe hf-iot tcp 192.168.30.1 22
v6 check_not "SR-05"   "IoT -> router SSH blocked, IPv6"                          probe hf-iot tcp 2a00:2:0:30::1 22

# -----------------------------------------------------------------------------
section "Internet (attacker)"
check_not "SR-02"   "Internet -> LAN device blocked, IPv4 (direct route)"      probe hf-inet tcp "$LAN4" 8080
v6 check_not "SR-02"   "Internet -> LAN device blocked, IPv6"                     probe hf-inet tcp "$LAN6" 8080
v6 check_not "SR-02"   "Internet -> guest device blocked, IPv6"                   probe hf-inet tcp "$GUEST6" 8080
v6 check_not "SR-02"   "Internet -> IoT device blocked, IPv6"                     probe hf-inet tcp "$IOT6" 8080
check_not "SR-03"   "Internet -> router SSH blocked, IPv4"                     probe hf-inet tcp "$FW_WAN4" 22
v6 check_not "SR-03"   "Internet -> router SSH blocked, IPv6"                     probe hf-inet tcp "$FW_WAN6" 22
check_not "SR-03"   "Internet -> router SSH via router's LAN address blocked"  probe hf-inet tcp "$FW_LAN4" 22
check_not "SR-03"   "Internet -> router DNS blocked (UDP)"                     probe hf-inet udp "$FW_WAN4" 53
v6 check_not "SR-03"   "Internet -> router DNS blocked (TCP, IPv6)"               probe hf-inet tcp "$FW_WAN6" 53
check_not "SR-03"   "Internet -> router DHCP server blocked"                   probe hf-inet udp "$FW_WAN4" 67 --sport 68
check_not "SR-03,SR-12" "Internet -> router tcp 8080 blocked (no port forwards)" probe hf-inet tcp "$FW_WAN4" 8080
check_not "SR-03"   "Internet -> ping router IPv4 not answered"                in_ns hf-inet ping -c1 -W1 "$FW_WAN4"
v6 check "FR-07"       "Internet -> ping router IPv6 answered (RFC 4890, D-07)"   in_ns hf-inet ping -c1 -W1 "$FW_WAN6"
check "FR-06"       "ISP -> router DHCPv4 reply (udp 67 -> 68) accepted"       probe hf-inet udp "$FW_WAN4" 68 --sport 67
LL_FW_WAN=""; ((HAVE_IPV6)) && LL_FW_WAN=$(link_local hf-fw wan0)
v6 check "FR-06"       "ISP -> router DHCPv6 reply (link-local, 547 -> 546) accepted" probe hf-inet udp "${LL_FW_WAN}%eth0" 546 --sport 547
v6 check_not "SR-03"   "Internet -> router DHCPv6 client port from a global address blocked" probe hf-inet udp "$FW_WAN6" 546 --sport 547

# icmp6_reaches_lan FROM_NS — does an unsolicited ICMPv6 error from FROM_NS
# reach the LAN device?
icmp6_reaches_lan() {
    local out
    out=$(mktemp)
    in_ns hf-lan python3 -I "$PROBE" icmp6listen 2 > "$out" &
    local pid=$!
    for _ in $(seq 20); do grep -q ready "$out" && break; sleep 0.05; done
    in_ns "$1" python3 -I "$PROBE" icmp6send "$LAN6"
    wait "$pid"; local rc=$?
    rm -f -- "$out"
    return "$rc"
}
v6 check     "SR-02" "control: an ICMPv6 error from the router itself reaches a LAN device" icmp6_reaches_lan hf-fw
v6 check_not "SR-02" "unsolicited ICMPv6 error from the internet is not forwarded to a LAN device (D-09)" icmp6_reaches_lan hf-inet

# -----------------------------------------------------------------------------
section "Anti-spoofing and bogons"
before=$(rule_packets prerouting "fib saddr . iif oif missing")
in_ns hf-lan ip addr add 192.168.20.99/32 dev eth0
in_ns hf-lan ip addr add 11.0.0.99/32 dev eth0
((HAVE_IPV6)) && in_ns hf-lan ip addr add 2a00:2:0:20::99/128 dev eth0 nodad
check_not "SR-06"   "LAN device spoofing a guest address is dropped"           probe hf-lan tcp "$INET4" 80 --src 192.168.20.99
check_not "SR-06"   "LAN device spoofing an internet address is dropped"       probe hf-lan tcp "$INET4" 80 --src 11.0.0.99
v6 check_not "SR-06"   "LAN device spoofing a guest IPv6 address is dropped"      probe hf-lan tcp "$INET6" 80 --src 2a00:2:0:20::99
after=$(rule_packets prerouting "fib saddr . iif oif missing")
check "SR-06"       "reverse-path filter counted the spoofed packets ($before -> $after)" test "$after" -gt "$before"
check "SR-06"       "LAN device using its real address still works"           probe hf-lan tcp "$INET4" 80 --src "$LAN4"

in_ns hf-inet ip addr add 10.9.9.9/32 dev eth0
in_ns hf-fw ip route add 10.9.9.9/32 via "$INET4"
before=$(rule_packets prerouting "@bogons_v4")
check_not "SR-07"   "Internet host with bogon source 10.9.9.9 -> router blocked" probe hf-inet tcp "$FW_WAN4" 22 --src 10.9.9.9
after=$(rule_packets prerouting "@bogons_v4")
check "SR-07"       "bogon filter counted the packet ($before -> $after)"     test "$after" -gt "$before"
check "SR-07"       "router -> server at a private address works (double NAT, D-04)" probe hf-fw tcp 10.9.9.9 80

# -----------------------------------------------------------------------------
section "Malformed and invalid traffic"
before=$(( $(rule_packets input "tcp flags != syn / fin,syn,rst,ack") + $(rule_packets input "ct state invalid") ))
for flags in A FA R; do
    in_ns hf-lan python3 -I "$PROBE" rawtcp "$LAN4" "$FW_LAN4" 22 "$flags"
done
sleep 0.5
after=$(( $(rule_packets input "tcp flags != syn / fin,syn,rst,ack") + $(rule_packets input "ct state invalid") ))
check_eq "SR-08"    "3 TCP packets without SYN (ACK, FIN+ACK, RST) to an open port dropped" 3 "$((after - before))"

before=$(( $(rule_packets forward "tcp flags != syn / fin,syn,rst,ack") + $(rule_packets forward "ct state invalid") ))
in_ns hf-lan python3 -I "$PROBE" rawtcp "$LAN4" "$INET4" 80 A
sleep 0.5
after=$(( $(rule_packets forward "tcp flags != syn / fin,syn,rst,ack") + $(rule_packets forward "ct state invalid") ))
check_eq "SR-08"    "TCP ACK without a connection is not forwarded"           1 "$((after - before))"

# -----------------------------------------------------------------------------
section "Rate limits"
replies=$(in_ns hf-lan ping -q -n -i 0.002 -c 300 -W 1 "$FW_LAN4" 2>/dev/null | awk '/received/ {print $4}')
check "SR-10"       "ping flood is rate-limited (${replies:-0}/300 answered, expect < 150)" test "${replies:-0}" -lt 150
check "SR-10"       "ping flood still gets some answers (${replies:-0} > 0)"  test "${replies:-0}" -gt 0

ok=0
for _ in $(seq 12); do probe hf-lan tcp "$FW_LAN4" 22 --timeout 0.5 >/dev/null && ok=$((ok + 1)); done
check "SR-09"       "SSH brute force throttled: ${ok}/12 rapid attempts got through (expect 6-7)" test "$ok" -ge 6 -a "$ok" -le 7
v6 check "SR-09"       "SSH limit is per source: same host over IPv6 still gets in" probe hf-lan tcp "$FW_LAN6" 22
in_ns hf-fw nft flush set inet filter ssh_meter_v4

# -----------------------------------------------------------------------------
section "Lockdown ruleset (SR-13)"
load_ruleset "${ROOT_DIR}/src/home-firewall/lockdown.nft"
check "SR-13"       "lockdown: LAN -> router SSH still works (admin can recover)" probe hf-lan tcp "$FW_LAN4" 22
check_not "SR-13"   "lockdown: LAN -> internet is not forwarded"              probe hf-lan tcp "$INET4" 80
check_not "SR-13"   "lockdown: internet -> router SSH blocked"                probe hf-inet tcp "$FW_WAN4" 22
check_not "SR-13"   "lockdown: guest -> router DNS blocked"                   probe hf-guest udp 192.168.20.1 53

# -----------------------------------------------------------------------------
section "Kernel hardening (SR-15)"
# -e: skip keys this kernel lacks (IPv6 keys are then reported as SKIP below).
in_ns hf-fw sysctl -q -e -p "${ROOT_DIR}/src/sysctl.d/90-home-firewall.conf"
while IFS='=' read -r key value; do
    key=${key// /}; value=${value// /}
    [[ -z $key || $key == \#* ]] && continue
    if [[ $key == net.ipv6.* ]]; then
        v6 check_eq "SR-15" "sysctl ${key} = ${value}" "$value" "$(in_ns hf-fw sysctl -n "$key" 2>/dev/null)"
    else
        check_eq "SR-15" "sysctl ${key} = ${value}" "$value" "$(in_ns hf-fw sysctl -n "$key")"
    fi
done < "${ROOT_DIR}/src/sysctl.d/90-home-firewall.conf"

summary "integration"
