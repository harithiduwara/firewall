# 1. Requirements

**Phase:** Requirements analysis
**Status:** Approved for v1.0.0

## 1.1 Problem statement

A household needs a firewall on its internet router that protects every device
in the home: computers, phones, guests' devices and "smart"/IoT devices that
cannot be trusted or patched reliably. Consumer router firmware is often
closed, slow to receive updates, and ships with risky defaults (UPnP, open
IPv6, remote admin). This project is a small, reviewable, testable firewall for
a Linux-based home router.

## 1.2 Scope

In scope:

- Packet filtering and NAT on a Linux router with one internet (WAN) uplink.
- Three internal zones: **LAN** (trusted), **GUEST** (visitors) and **IOT**
  (smart devices).
- IPv4 and IPv6 (dual stack).
- Safe deployment, rollback, and automated verification.

Out of scope (handled by other controls, see [threat model](02-threat-model.md)):

- Wi-Fi security (WPA3/WPA2 configuration, AP client isolation).
- DNS filtering, IDS/IPS, VPN server.
- Hardening of the router's own services (SSH daemon config, DNS/DHCP server).
- Multi-WAN and policy routing.

## 1.3 Stakeholders

| Stakeholder       | Interest                                                   |
|-------------------|------------------------------------------------------------|
| Household members | Internet just works; privacy; no compromise of their data. |
| Administrator     | Easy, safe changes; can recover from mistakes.             |
| Guests            | Internet access only.                                      |

## 1.4 Functional requirements

| ID    | Requirement |
|-------|-------------|
| FR-01 | LAN devices can open connections to the internet over IPv4 (via NAT) and IPv6 (routed). |
| FR-02 | GUEST devices can open connections to the internet. |
| FR-03 | IOT devices can open connections to the internet. LAN devices can open connections to IOT devices (e.g. to control a TV or printer). |
| FR-04 | Devices in every internal zone can use the router's DNS (TCP/UDP 53), DHCPv4 (UDP 67) and DHCPv6 (UDP 547) services. |
| FR-05 | The administrator can reach the router over SSH from the LAN zone. |
| FR-06 | The router can obtain its WAN address via DHCPv4, DHCPv6 and IPv6 router advertisements. |
| FR-07 | IPv6 neighbor discovery, router discovery, MLD and path-MTU discovery work in every zone (RFC 4890). |
| FR-08 | Internal devices can ping the router. |

## 1.5 Security requirements

| ID    | Requirement |
|-------|-------------|
| SR-01 | Default deny: traffic to the router (input) and through the router (forward) is dropped unless a rule allows it. |
| SR-02 | No unsolicited connection from the internet reaches any internal device, over IPv4 **or IPv6**. |
| SR-03 | No router service (SSH, DNS, DHCP, any other port) is reachable from the internet. IPv4 ping from the internet is not answered. |
| SR-04 | GUEST devices cannot reach LAN or IOT devices, and cannot reach router management (SSH). |
| SR-05 | IOT devices cannot open connections to LAN or GUEST devices, and cannot reach router management (SSH). |
| SR-06 | Anti-spoofing: packets whose source address is not routable back through the interface they arrived on are dropped (strict reverse-path filtering, BCP 38/84). |
| SR-07 | New connections from the WAN with bogon (reserved, private, documentation) source addresses are dropped. |
| SR-08 | Packets in an invalid connection-tracking state, and new TCP connections that do not start with a SYN, are dropped. |
| SR-09 | SSH connection attempts are rate-limited per source address to slow brute-force attacks. |
| SR-10 | ICMP echo is rate-limited, and logging of dropped packets is rate-limited so an attacker cannot flood the logs or disk. |
| SR-11 | Outbound Windows RPC/NetBIOS/SMB (TCP/UDP 135, 137-139, 445) to the internet is blocked for every zone; outbound SMTP (TCP 25) is blocked for GUEST and IOT (limits damage from infected devices). |
| SR-12 | No port forwards, no UPnP/NAT-PMP, and no conntrack helpers are enabled by default (prevents NAT slipstreaming and silent exposure). |
| SR-13 | Fail closed: an invalid ruleset is never loaded; packet forwarding is enabled only after the firewall has loaded; stopping or failing the firewall service results in a lockdown ruleset, not an open router. |
| SR-14 | Safe change: rule changes are validated before they are applied, and are automatically rolled back unless the administrator confirms within a time limit. |
| SR-15 | Kernel network stack hardening: ICMP redirects and source routing are disabled, SYN cookies and martian logging are enabled. |
| SR-16 | Installed configuration files are owned by root and not writable by other users; backups are readable by root only. |

## 1.6 Non-functional requirements

| ID     | Requirement |
|--------|-------------|
| NFR-01 | Site-specific settings (interface names, SSH port) live in one small file; the ruleset itself needs no edits for a normal install. |
| NFR-02 | Every FR/SR above is verified by an automated test that runs in CI on every change. |
| NFR-03 | Runs on Debian 12+, Ubuntu 22.04+ and Raspberry Pi OS (nftables >= 1.0, Linux >= 5.10). |
| NFR-04 | The ruleset is small enough to review by hand (target: under 300 lines). |

## 1.7 Acceptance criteria

v1.0.0 is accepted when:

1. All automated tests pass in CI (lint, static checks, live packet tests, apply/rollback tests).
2. The traceability matrix in [05-verification.md](05-verification.md) has a passing test for every requirement.
3. A security review of the change has been completed and its findings resolved.
