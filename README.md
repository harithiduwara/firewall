# Home Firewall

A small, tested firewall for a Linux home router, built with nftables and
developed through a full software development life cycle (SDLC):
requirements → threat model → design → implementation → verification →
deployment → maintenance.

## What it does

| Zone | Can reach | Cannot reach |
|------|-----------|--------------|
| **LAN** (your computers and phones) | Internet, IoT devices, router (DNS, DHCP, SSH) | Guest devices |
| **Guest** (visitors) | Internet, router DNS/DHCP | LAN, IoT, router SSH |
| **IoT** (smart TV, cameras, plugs) | Internet, router DNS/DHCP | LAN, guest, router SSH |
| **Internet** | Nothing it did not ask for | Every device and every router service |

Also:

- IPv4 **and** IPv6 handled by the same rules (IPv6 is where many home routers leak).
- Anti-spoofing (strict reverse-path filter), bogon filtering, drops malformed TCP.
- SSH brute-force throttling, ping-flood and log-flood limits.
- Blocks outbound SMB/NetBIOS for everyone and outbound SMTP for guest/IoT.
- No port forwards, no UPnP, no conntrack helpers.
- **Fail closed**: an invalid ruleset is never loaded, routing starts only after
  the firewall is up, and stopping or failing the firewall locks the router
  down instead of opening it.
- **Safe changes**: `fw-apply` validates, applies, and rolls back automatically
  unless you confirm within 60 seconds.

## Quick start

```sh
sudo apt install nftables
sudo ./scripts/install.sh --no-activate
sudo nano /etc/home-firewall/zones.nft     # set your interface names
sudo ./scripts/install.sh                  # 60 s to confirm, else rollback
```

Read [docs/sdlc/06-deployment.md](docs/sdlc/06-deployment.md) before
installing: it covers IPv6 on the WAN, router hardening and post-install checks.

## Testing

```sh
sudo apt install nftables iproute2 iputils-ping shellcheck python3
sudo make lint
sudo tests/run.sh
```

The tests build a virtual home network (internet, router, LAN, guest, IoT)
out of Linux network namespaces, load the real ruleset, and send real
packets along every path over IPv4 and IPv6. A traceability check fails the
run unless every requirement has a passing test. CI runs all of it on every
push, with IPv6 required.

## Documents

| Phase | Document |
|-------|----------|
| Requirements | [01-requirements.md](docs/sdlc/01-requirements.md) |
| Threat model | [02-threat-model.md](docs/sdlc/02-threat-model.md) |
| Design | [03-design.md](docs/sdlc/03-design.md) |
| Implementation | [04-implementation.md](docs/sdlc/04-implementation.md) |
| Verification | [05-verification.md](docs/sdlc/05-verification.md) |
| Deployment | [06-deployment.md](docs/sdlc/06-deployment.md) |
| Maintenance | [07-maintenance.md](docs/sdlc/07-maintenance.md) |

## Limits

No firewall can guarantee zero vulnerabilities. This one keeps the attack
surface minimal and verifies every rule automatically. What is left over is
listed in the [residual risks](docs/sdlc/02-threat-model.md#24-residual-risks-accepted-or-handled-elsewhere),
with what to do about each: keep devices patched, use strong Wi-Fi security,
and use SSH keys.
