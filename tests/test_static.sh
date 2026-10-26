#!/usr/bin/env bash
# Static checks on the ruleset, config files and installer.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_root

SRC=${ROOT_DIR}/src
RULESET=${SRC}/nftables.conf
WORK=$(mktemp -d)
trap 'rm -rf -- "${WORK}"' EXIT

# Run nft in a throwaway network namespace so the host is never touched.
nft_ns() { unshare -n nft "$@"; }

# Load the ruleset in a private namespace and dump it as text / JSON.
dump_ruleset() { unshare -n sh -c "nft -I '$1' -f '$2' && nft $3 list ruleset"; }

# -----------------------------------------------------------------------------
section "Syntax and platform"
nft_version=$(nft --version | grep -o '[0-9]\+\.[0-9]\+' | head -n1)
check "NFR-03" "nftables version ${nft_version} >= 1.0" \
    python3 -c "import sys; sys.exit(0 if tuple(map(int,'${nft_version}'.split('.'))) >= (1,0) else 1)"
check "SR-13,NFR-03" "main ruleset is valid with the shipped zones.nft"   nft_ns -I "${SRC}" -c -f "${RULESET}"
check "SR-13,NFR-03" "main ruleset is valid with the lab zones.nft"       nft_ns -I "${TESTS_DIR}/fixtures" -c -f "${RULESET}"
check "SR-13"        "lockdown ruleset is valid"                          nft_ns -I "${SRC}" -c -f "${SRC}/home-firewall/lockdown.nft"

mkdir -p "${WORK}/dup/home-firewall"
sed 's/^define GUEST_IF .*/define GUEST_IF = "eth1"/' "${SRC}/home-firewall/zones.nft" > "${WORK}/dup/home-firewall/zones.nft"
check_not "NFR-01,SR-13" "a zones.nft that reuses one interface for two zones is rejected" \
    nft_ns -I "${WORK}/dup" -c -f "${RULESET}"

lines=$(wc -l < "${RULESET}")
check "NFR-04" "ruleset is reviewable by hand (${lines} lines < 300)" test "${lines}" -lt 300
check_not "NFR-01" "ruleset contains no hard-coded interface names (only \$WAN_IF etc.)" \
    grep -En '(iif|oif)name +"' "${RULESET}"

# -----------------------------------------------------------------------------
section "Loaded ruleset"
TEXT=$(dump_ruleset "${TESTS_DIR}/fixtures" "${RULESET}" "")
JSON=$(dump_ruleset "${TESTS_DIR}/fixtures" "${RULESET}" "-j")
printf '%s' "${JSON}" > "${WORK}/ruleset.json"

policy_of() { # chain
    python3 - "${WORK}/ruleset.json" "$1" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))["nftables"]
for item in data:
    c = item.get("chain")
    if c and c["table"] == "filter" and c["name"] == sys.argv[2]:
        print(c.get("policy", ""))
EOF
}
check_eq "SR-01" "input chain default policy is drop"   drop "$(policy_of input)"
check_eq "SR-01" "forward chain default policy is drop" drop "$(policy_of forward)"

check_not "SR-12" "no port forwards (dnat/redirect) in the shipped ruleset" grep -Eq '\b(dnat|redirect) to' <<<"${TEXT}"
check_not "SR-12" "no conntrack helpers (ALG / NAT slipstreaming surface)"  grep -Eq 'ct helper' <<<"${TEXT}"
check_not "SR-12" "no IPv6 NAT"                                              grep -Eq 'table ip6 nat|masquerade.*ip6' <<<"${TEXT}"

check "SR-10" "every log statement is preceded by a rate limit" python3 - "${WORK}/ruleset.json" <<'EOF'
import json, sys
bad = 0
for item in json.load(open(sys.argv[1]))["nftables"]:
    rule = item.get("rule")
    if not rule:
        continue
    seen_limit = False
    for expr in rule["expr"]:
        if "limit" in expr:
            seen_limit = True
        if "log" in expr and not seen_limit:
            bad += 1
sys.exit(1 if bad else 0)
EOF
check "SR-10" "ping rate limits run before the 'established' accept rule" python3 - "${WORK}/ruleset.json" <<'EOF'
import json, sys
order = []
for item in json.load(open(sys.argv[1]))["nftables"]:
    r = item.get("rule")
    if r and r["chain"] == "input":
        s = json.dumps(r["expr"])
        if '"limit"' in s and "echo-request" in s:
            order.append("limit")
        elif '"established"' in s:
            order.append("est")
sys.exit(0 if order and "est" in order and order.index("est") > max(i for i, x in enumerate(order) if x == "limit") else 1)
EOF

check "FR-06" "router advertisements accepted only on the WAN, from link-local, hop limit 255" \
    grep -Eq 'icmpv6 type nd-router-advert iifname "wan0" ip6 saddr fe80::/10 ip6 hoplimit 255 accept' <<<"${TEXT}"
check "FR-07" "ICMPv6 errors (incl. packet-too-big) are accepted by the router (RFC 4890)" \
    grep -Eq 'icmpv6 type \{ destination-unreachable, packet-too-big, time-exceeded, parameter-problem \} accept' <<<"${TEXT}"
# shellcheck disable=SC2016  # $1/$2 are expanded by the inner bash
check "FR-07" "forwarded ICMP errors (path-MTU discovery) pass as conntrack 'related'" \
    bash -c 'unshare -n sh -c "nft -I \"$1\" -f \"$2\" && nft list chain inet filter forward" | grep -q "ct state established,related accept"' \
    _ "${TESTS_DIR}/fixtures" "${RULESET}"
check "FR-07" "IPv6 neighbor discovery accepted only with hop limit 255" \
    grep -Eq 'icmpv6 type \{ nd-neighbor-solicit, nd-neighbor-advert \} ip6 hoplimit 255 accept' <<<"${TEXT}"
# shellcheck disable=SC2016  # $1 is expanded by the inner bash
check "SR-07" "bogon sets are populated (IPv4 and IPv6)" \
    bash -c 'grep -q "192.168.0.0/16" <<<"$1" && grep -q "fc00::/7" <<<"$1"' _ "${TEXT}"

# -----------------------------------------------------------------------------
section "Fail-closed service integration (SR-13)"
DROPIN=${SRC}/systemd/nftables.service.d/10-home-firewall.conf
check     "SR-13" "service failure triggers the lockdown unit" grep -qx 'OnFailure=home-firewall-lockdown.service' "${DROPIN}"
check     "SR-13" "forwarding is enabled only after the ruleset loads (ExecStartPost)" \
    grep -q '^ExecStartPost=.*net.ipv4.ip_forward=1' "${DROPIN}"
check     "SR-13" "the stock 'flush ruleset' on stop is cleared" grep -qx 'ExecStop=' "${DROPIN}"
check     "SR-13" "stopping the service loads the lockdown ruleset" \
    grep -q '^ExecStop=/usr/sbin/nft -f /etc/home-firewall/lockdown.nft' "${DROPIN}"
check_not "SR-13" "stopping the service never flushes the ruleset" grep -Eq '^ExecStop=.*flush' "${DROPIN}"
check_not "SR-13" "the sysctl file never turns forwarding on by itself" \
    grep -Eq '^[^#]*(ip_forward|forwarding) *= *1' "${SRC}/sysctl.d/90-home-firewall.conf"
# shellcheck disable=SC2016  # $1/$2 are expanded by the inner bash
check     "SR-13" "lockdown forward policy is drop" \
    bash -c 'unshare -n sh -c "nft -I \"$1\" -f \"$2\" && nft list chain inet lockdown forward" | grep -q "policy drop"' \
    _ "${SRC}" "${SRC}/home-firewall/lockdown.nft"

# -----------------------------------------------------------------------------
section "Installer (SR-16)"
DEST=${WORK}/root
mkdir -p "${DEST}"
check "SR-16" "install.sh into a staging root succeeds" env DESTDIR="${DEST}" "${ROOT_DIR}/scripts/install.sh" --no-activate
writable=$(find "${DEST}" -mindepth 1 -perm /022 ! -type l | wc -l)
check_eq "SR-16" "no installed file is writable by group or others" 0 "${writable}"
notroot=$(find "${DEST}/etc/home-firewall" "${DEST}/etc/nftables.conf" "${DEST}/usr/local/sbin/fw-apply" \
          "${DEST}/etc/sysctl.d/90-home-firewall.conf" "${DEST}/etc/systemd/system" ! -user root | wc -l)
check_eq "SR-16" "every installed file is owned by root" 0 "${notroot}"
check "SR-16" "fw-apply is installed executable" test -x "${DEST}/usr/local/sbin/fw-apply"

echo 'define LAN_IF = "my-custom"' >> "${DEST}/etc/home-firewall/zones.nft"
sed -i '/define LAN_IF   = "eth1"/d' "${DEST}/etc/home-firewall/zones.nft"
env DESTDIR="${DEST}" "${ROOT_DIR}/scripts/install.sh" --no-activate >/dev/null 2>&1
check "NFR-01" "re-running the installer keeps the user's zones.nft" grep -q 'my-custom' "${DEST}/etc/home-firewall/zones.nft"

summary "static"
