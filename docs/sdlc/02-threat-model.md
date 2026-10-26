# 2. Threat model

**Phase:** Requirements / design
**Method:** STRIDE per trust boundary, with mitigations mapped to requirements.

## 2.1 Assets

| Asset                         | Why it matters                                      |
|-------------------------------|-----------------------------------------------------|
| Household devices and data    | Personal data, credentials, cameras, microphones.   |
| The router itself             | Whoever controls it controls all traffic.           |
| Internet connection           | Abuse can get the household blocklisted or blamed.  |

## 2.2 Trust zones and boundaries

```
             untrusted                  trusted        semi-trusted   untrusted
  Internet ──[B1]── Router ──[B2]── LAN      Router ──[B3]── IOT    Router ──[B4]── GUEST
```

| Zone     | Trust | Notes |
|----------|-------|-------|
| WAN      | None  | Anyone on the internet, plus the ISP network segment. |
| LAN      | High  | Household computers and phones. Can manage the router and IoT. |
| IOT      | Low   | Devices that are rarely patched and may phone home. Internet only. |
| GUEST    | None  | Visitors' devices. Internet only. |
| Router   | Highest | Runs the firewall. |

## 2.3 Threats and mitigations

| #   | Boundary | STRIDE | Threat | Mitigation | Req |
|-----|----------|--------|--------|------------|-----|
| T1  | B1 | S | Attacker scans the public IPv4/IPv6 address for open services. | Default-drop input; no WAN services; IPv4 ping not answered. | SR-01, SR-03 |
| T2  | B1 | E | Unsolicited IPv6 connection to a LAN device with a global address (IPv6 has no NAT "accidental firewall"). | Forward policy drop; only zone pairs in the allow matrix pass; WAN to anything is not in the matrix. | SR-02 |
| T3  | B1 | T | Brute force against router SSH. | SSH not reachable from WAN at all; LAN SSH rate-limited per source. | SR-03, SR-09 |
| T4  | B1 | S | Spoofed packets with private/bogon or internal source addresses arriving from the internet. | Strict reverse-path filter; bogon drop for new WAN connections. | SR-06, SR-07 |
| T5  | B1 | T | Crafted TCP packets (non-SYN "new" connections, invalid state) used to probe or evade. | Drop invalid state and new non-SYN. | SR-08 |
| T6  | B1 | D | ICMP or log flooding to exhaust CPU or disk. | Rate-limited echo and logging; SYN cookies. | SR-10, SR-15 |
| T7  | B1 | E | NAT slipstreaming / ALG abuse opens inbound ports via conntrack helpers. | No helpers loaded; no UPnP; no port forwards. | SR-12 |
| T8  | B1 | T | ICMP redirects or source-routed packets alter the router's routing. | Redirects and source routing disabled. | SR-15 |
| T9  | B3 | E | A compromised IoT device attacks LAN computers (lateral movement). | IOT to LAN/GUEST not in the allow matrix; IoT cannot reach SSH. | SR-05 |
| T10 | B4 | I/E | A guest device snoops on or attacks household devices. | GUEST to LAN/IOT not in the allow matrix; guest cannot reach SSH. | SR-04 |
| T11 | B2-B4 | S | An internal device spoofs another zone's or an internet address (to bypass zone rules or join DDoS reflection). | Strict reverse-path filter. | SR-06 |
| T12 | B2-B4 | R/I | An infected device spreads worms over SMB or sends spam. | Outbound 135/137-139/445 blocked; SMTP from GUEST/IOT blocked. | SR-11 |
| T13 | Router | D/E | Admin typo locks them out, or a broken ruleset leaves the router open. | Validate before apply; auto-rollback; fail closed (forwarding only after load; lockdown on stop or failure). | SR-13, SR-14 |
| T14 | Router | T | Local non-root user edits the firewall config. | Files root-owned, not world-writable; backups mode 0600. | SR-16 |

## 2.4 Residual risks (accepted or handled elsewhere)

A firewall is one layer of defence. Nobody can honestly promise "zero
vulnerabilities". What this project can do is keep the attack surface minimal,
verify every rule automatically, and write down what is left over:

| Risk | Why it remains | Recommended control |
|------|----------------|---------------------|
| R1 Outbound connections are allowed (needed for the internet to work). Malware that is already inside can "phone home". | Blocking egress by default would break normal use. | Keep devices patched; consider DNS filtering (e.g. a Pi-hole on the LAN). |
| R2 Devices on the same zone can talk to each other (e.g. guest to guest over Wi-Fi). | Traffic within one bridge or switch never passes through the firewall. | Turn on "client isolation" on the guest Wi-Fi access point. |
| R3 Vulnerabilities in the router's own services (sshd, DNS, DHCP) or kernel. | The firewall limits *who* can reach them, not whether they are bug-free. | Unattended security updates; key-only SSH auth; see [06-deployment.md](06-deployment.md). |
| R4 Router-originated traffic (output) is not filtered. | The router is the most trusted host; filtering it adds risk of breaking updates and DNS. | Install only needed software on the router. |
| R5 Wi-Fi attacks (weak passphrase, WPS). | Outside the packet filter. | WPA3 (or WPA2-AES), long passphrase, WPS off. |
| R6 Compromise of the administrator's LAN computer gives SSH access. | LAN is trusted by design. | SSH keys with passphrases; optionally restrict SSH to one admin host. |
| R7 If the main ruleset cannot be loaded at boot **and** the lockdown unit also fails, the router's input chain is empty. Forwarding stays off, so internal devices are still not exposed. | Both files are validated before install, so this needs disk corruption. | Console access for recovery; keep backups. |
| R8 IPv6 ping from the internet is answered (rate-limited). | RFC 4890 recommends not filtering echo; it aids diagnosis and IPv6 addresses are not practical to scan. | Accepted. |
