# 5. Verification

**Phase:** Testing

## 5.1 Strategy

| Level | Suite | What it proves |
|-------|-------|----------------|
| Lint | `make lint` | Rulesets parse (`nft -c`), shell is `shellcheck` clean, Python compiles. |
| Static | `tests/test_static.sh` | Properties of the *loaded* ruleset: default-drop policies, no DNAT/helpers, every log rate-limited, rule order, systemd fail-closed config, installer file ownership and modes. |
| Tool | `tests/test_apply.sh` | `fw-apply` refuses invalid rules, rolls back on no answer / wrong answer / timeout / being killed, keeps rules on "yes", restores dynamic state, protects and prunes backups. |
| Live packets | `tests/test_integration.sh` | Builds a virtual home (internet, router, LAN, guest, IoT) from Linux network namespaces, loads the **real ruleset**, and sends real TCP, UDP, ICMP and crafted packets along every zone pair, over IPv4 and IPv6. Also tests spoofing, bogons, malformed TCP, rate limits, the lockdown ruleset and sysctls. |
| Traceability | `tests/traceability.py` | Every requirement ID in [01-requirements.md](01-requirements.md) has at least one passing test and no failures. A requirement with only skipped tests fails. |

Every test tags the requirement IDs it verifies. Negative tests ("X is
blocked") are always paired with a positive control ("Y still works") so that
a broken lab cannot make the firewall look good.

## 5.2 How to run

```sh
sudo apt install nftables iproute2 iputils-ping shellcheck python3
sudo make lint
sudo tests/run.sh                  # results in tests/out/
sudo REQUIRE_IPV6=1 tests/run.sh   # what CI runs: IPv6 skips are errors
```

The tests only ever touch throwaway network namespaces (`hf-*`); they do not
change the host's firewall.

## 5.3 Lab topology

```
hf-inet  11.0.0.2 / 2a00:1::2          (internet + attacker on the ISP segment)
   │ wan0 11.0.0.1 / 2a00:1::1
hf-fw    (router, real ruleset)
   ├ lan0   192.168.1.1  / 2a00:2:0:1::1   ── hf-lan   .10
   ├ guest0 192.168.20.1 / 2a00:2:0:20::1  ── hf-guest .10
   └ iot0   192.168.30.1 / 2a00:2:0:30::1  ── hf-iot   .10
```

The "internet" uses non-bogon ranges so the bogon filter does not distort
ordinary results. The internet host also has a direct route to the home
ranges, simulating an attacker on the same ISP segment.

## 5.4 Traceability matrix

| Req | Verified by (examples) |
|-----|------------------------|
| FR-01 | LAN → internet over IPv4 is NATed to the WAN address; over IPv6 the real source address is kept. |
| FR-02 | Guest → internet, IPv4 and IPv6. |
| FR-03 | IoT → internet; LAN → IoT device, IPv4 and IPv6. |
| FR-04 | DNS (UDP+TCP), DHCPv4 (68→67), DHCPv6 (link-local 546→547) from each internal zone. |
| FR-05 | LAN → router SSH, IPv4 and IPv6. |
| FR-06 | DHCPv4 reply 67→68 and DHCPv6 reply (link-local) from the ISP accepted; RA rule restricted to WAN, link-local, hop limit 255. |
| FR-07 | IPv6 connectivity (needs ND), IPv6 ping from WAN, ICMPv6 error rules, ND hop-limit rule. |
| FR-08 | Ping router from LAN and guest. |
| SR-01 | Input/forward policies are drop; unlisted router port blocked from LAN; LAN → guest blocked. |
| SR-02 | Internet → LAN/guest/IoT devices blocked (IPv4 direct route, IPv6); unsolicited ICMPv6 not forwarded. |
| SR-03 | Internet → router SSH/DNS/DHCP/any port blocked; IPv4 ping not answered; DHCPv6 client port not reachable from global addresses. |
| SR-04 | Guest → LAN, IoT, router SSH (via guest, LAN and IPv6 addresses) blocked. |
| SR-05 | IoT → LAN, guest, router SSH blocked. |
| SR-06 | LAN device spoofing guest, internet and guest-IPv6 addresses is dropped and counted; real address still works. |
| SR-07 | New connection from a bogon source dropped and counted; router → private-address server works (double NAT). |
| SR-08 | Crafted ACK, FIN+ACK, RST to an open port dropped; stray ACK not forwarded. |
| SR-09 | 12 rapid SSH attempts: 6–7 succeed; per-source (IPv6 from same host unaffected). |
| SR-10 | Ping flood: fewer than half answered, but not zero; every log rate-limited; limit placed before `established`. |
| SR-11 | SMB/NetBIOS to internet rejected; SMTP from guest/IoT rejected; SMTP from LAN allowed. |
| SR-12 | No DNAT/redirect, no conntrack helpers, no IPv6 NAT; internet → router port 8080 blocked. |
| SR-13 | `nft -c` validation; broken ruleset refused with old rules intact; lockdown ruleset behaviour; systemd drop-in and sysctl content. |
| SR-14 | Rollback on closed stdin, wrong answer, timeout, SIGTERM; "yes" keeps; rollback restores dynamic state; bad `--timeout` refused. |
| SR-15 | Each sysctl in the hardening file applied and read back. |
| SR-16 | Installed files root-owned and not group/world-writable; backups 0600 in a 0700 directory; pruning. |
| NFR-01 | No literal interface names in the ruleset; duplicate interface config rejected; reinstall keeps `zones.nft`. |
| NFR-02 | `traceability.py` itself. |
| NFR-03 | nftables ≥ 1.0; CI on Ubuntu 24.04. |
| NFR-04 | Ruleset under 300 lines. |

The full per-test list is in `tests/out/verification-report.md` after a run,
and is uploaded as a CI artifact.

## 5.5 Results for v1.0.0

| Environment | Static | Apply | Live packets | Traceability |
|-------------|--------|-------|--------------|--------------|
| Development sandbox (kernel without IPv6) | 31/31 | 26/26 | 64/64 passed, 33 IPv6 checks skipped | 28/28 verified |
| CI, Ubuntu 24.04 (IPv6 required), [run 1](https://github.com/harithiduwara/firewall/actions/runs/40403023789) | 31/31 | 26/26 | 97/97 passed, 0 skipped | 28/28 verified |

## 5.6 Not covered by automated tests

| Item | Why | How it is covered instead |
|------|-----|---------------------------|
| Real boot sequence (systemd ordering, `OnFailure=`) | Needs a full VM. | Static checks on the unit files; manual check in [06-deployment.md](06-deployment.md) §6.5. |
| Real ISP DHCP/RA | Needs a real uplink. | Rules tested with simulated packets; manual check after install. |
| Performance at gigabit rates | Out of scope for a home link. | `established,related` is the first rule in forward, so most packets match one rule. |
