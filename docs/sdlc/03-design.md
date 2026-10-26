# 3. Design

**Phase:** Design

## 3.1 Platform

- **Linux nftables** (the successor to iptables). One `inet` table filters
  IPv4 and IPv6 with the same rules, so IPv6 cannot be forgotten.
- Target hardware: any small Linux box with two or more network ports (or one
  port plus VLANs), e.g. a mini PC or Raspberry Pi with a USB NIC, running
  Debian 12+, Ubuntu 22.04+ or Raspberry Pi OS.
- Loaded at boot by the distribution's `nftables.service`.

## 3.2 Network layout (example)

```
                      ┌──────────────── Router ────────────────┐
  Internet ── WAN_IF ─┤ table inet filter  +  table ip nat      ├─ LAN_IF   ── 192.168.1.0/24   (trusted)
  (ISP modem)         │ prerouting → input / forward → output  ├─ GUEST_IF ── 192.168.20.0/24  (guests)
                      │                                        ├─ IOT_IF   ── 192.168.30.0/24  (smart devices)
                      └────────────────────────────────────────┘
```

Zones are defined **by interface**, not by IP range. Combined with strict
reverse-path filtering, a device cannot claim to be in another zone by
changing its IP address. Subnets are therefore not part of the firewall
config at all, which removes a whole class of configuration mistakes.

Guest and IoT are usually VLANs on the LAN port (e.g. `eth1.20`, `eth1.30`)
mapped to separate Wi-Fi SSIDs on the access point. If you do not have a
guest or IoT network, leave the placeholder names in `zones.nft`: rules for
an interface that does not exist never match.

## 3.3 Zone policy matrix (forward chain)

New connections. Replies to allowed connections are always allowed
(stateful firewall). Anything not marked "allow" is dropped.

| From \ To | WAN      | LAN  | GUEST | IOT   |
|-----------|----------|------|-------|-------|
| **LAN**   | allow¹   | n/a  | drop  | allow |
| **GUEST** | allow¹²  | drop | n/a   | drop  |
| **IOT**   | allow¹²  | drop | drop  | n/a   |
| **WAN**   | n/a      | drop | drop  | drop  |

¹ Except TCP/UDP 135, 137-139, 445 (Windows RPC/SMB), which are rejected (SR-11).
² Except TCP 25 (SMTP), which is rejected (SR-11).

## 3.4 Router services matrix (input chain)

| Service             | Port            | LAN | GUEST | IOT | WAN |
|---------------------|-----------------|-----|-------|-----|-----|
| DNS                 | TCP/UDP 53      | yes | yes   | yes | no  |
| DHCPv4 server       | UDP 67          | yes | yes   | yes | no  |
| DHCPv6 server       | UDP 547 (link-local src) | yes | yes | yes | no |
| SSH (rate-limited)  | TCP `SSH_PORT`  | yes | no    | no  | no  |
| Ping (ICMP echo)    | ICMP/ICMPv6     | yes | yes   | yes | IPv6 only, rate-limited |
| DHCPv4 client reply | UDP 67 → 68     | –   | –     | –   | yes |
| DHCPv6 client reply | UDP 547 → 546 (link-local src) | – | – | – | yes |
| Router advertisement| ICMPv6 134 (link-local src, hop limit 255) | no | no | no | yes |

## 3.5 Packet path and rule order

```
prerouting (priority mangle)
  1. allow DHCP DISCOVER (src 0.0.0.0) and IPv6 DAD (src ::) — they have no route back yet
  2. strict reverse-path check          → drop spoofed            (SR-06)
  3. WAN + new + bogon source           → drop                    (SR-07)

input (policy drop)                          forward (policy drop)
  1. ping flood limits → drop                  1. established,related → accept (incl. ICMP errors
  2. established,related → accept                 for real connections, e.g. packet-too-big)
  3. invalid → drop                            2. invalid → drop
  4. loopback → accept                         3. new TCP without SYN → drop
  5. new TCP without SYN → drop                4. to WAN → egress hygiene (reject 135-139/445, SMTP)
  6. ICMP / ICMPv6 rules                       5. zone matrix (vmap on iifname . oifname)
  7. per-zone services (vmap on iifname)       6. DNAT'd traffic → accept (only if you add port forwards)
  8. rate-limited log, then drop               7. rate-limited log, then drop
postrouting (nat): IPv4 out WAN → masquerade
```

Ping limits sit *before* `established,related` because conntrack treats a
stream of pings as one established flow; a limit placed later never sees a
flood (found by the SR-10 test during development).

Putting `established,related` early is both a performance choice (most
packets match it) and a safety choice: it is the only way a WAN packet gets
to an internal device.

## 3.6 Fail-closed lifecycle (SR-13)

| Event | Result |
|-------|--------|
| Boot | `nftables.service` loads the ruleset *before* the network comes up. Only after it succeeds does the drop-in turn on IPv4/IPv6 forwarding. The sysctl file never enables forwarding. |
| Ruleset fails to load at boot | `OnFailure=` starts `home-firewall-lockdown.service`, which loads `lockdown.nft` (drop everything except loopback, replies, ND and LAN SSH). Forwarding stays off. |
| `systemctl stop nftables` | The drop-in replaces the stock "flush ruleset" with the lockdown ruleset and turns forwarding off. |
| `fw-apply` with a broken file | `nft -c` rejects it; nothing changes. |
| `fw-apply` and no confirmation | The previous ruleset is restored after the timeout (default 60 s). |

## 3.7 Configuration

| File (installed path) | Purpose | Edit? |
|-----------------------|---------|-------|
| `/etc/home-firewall/zones.nft` | Interface names, SSH port | **Yes** — the only site-specific file. Kept on upgrade. |
| `/etc/nftables.conf` | Main ruleset | Only through the change process. |
| `/etc/home-firewall/lockdown.nft` | Emergency ruleset | No. |
| `/etc/sysctl.d/90-home-firewall.conf` | Kernel hardening | No. |
| `/etc/systemd/system/nftables.service.d/10-home-firewall.conf` | Fail-closed service behaviour | No. |
| `/etc/systemd/system/home-firewall-lockdown.service` | Lockdown on failure | No. |
| `/usr/local/sbin/fw-apply` | Validate, apply, auto-rollback | No. |

## 3.8 Design decisions

| ID   | Decision | Rationale |
|------|----------|-----------|
| D-01 | `drop` (not `reject`) for traffic from the WAN. | Gives scanners no information and costs no outbound bandwidth. |
| D-02 | `reject` for egress hygiene blocks from internal zones. | Internal apps fail fast instead of hanging on a timeout. |
| D-03 | Match interfaces by name (`iifname`) not index (`iif`). | Rules load even if a VLAN/PPPoE interface appears later; hot-plug safe. |
| D-04 | Bogon filter applies only to **new** connections. | Works behind an ISP modem with a private address (double NAT) or CGNAT, because replies are matched earlier as `established`. |
| D-05 | Output chain is `accept`. | See residual risk R4. |
| D-06 | No port forwards shipped. A documented pattern exists in [06-deployment.md](06-deployment.md). | SR-12; every exposure must be a deliberate, reviewed change. |
| D-07 | IPv4 ping from the WAN is dropped; IPv6 ping is rate-limited and accepted. | See residual risk R8. |
| D-08 | `flush ruleset` at the top of the ruleset. | Loading is atomic and repeatable; nothing stale survives. Assumes a dedicated router (see deployment notes about Docker). |
| D-09 | The forward chain has no blanket "accept ICMPv6 errors" rule. | Errors that belong to a real connection are accepted as conntrack `related`, which is all path-MTU discovery needs (RFC 4890's goal). Unsolicited ICMPv6 from the internet never reaches home devices. Found in security review. |
