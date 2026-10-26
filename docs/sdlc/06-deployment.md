# 6. Deployment

**Phase:** Deployment

## 6.1 Before you start

- A Linux box used **only** as your router, with two network ports (or one
  port plus VLANs): Debian 12+, Ubuntu 22.04+ or Raspberry Pi OS.
- A keyboard and screen (or serial console) for the first install, in case
  you lock yourself out.
- Do the first install from a computer on the **LAN** port, not over Wi-Fi
  through a guest network.

> The ruleset starts with `flush ruleset`. Anything else that manages
> nftables/iptables on this box (Docker, firewalld, ufw) will have its rules
> removed. Disable those first: `sudo systemctl disable --now ufw firewalld`.
> Do not run Docker on the router.

## 6.2 Install

```sh
sudo apt install nftables
git clone <this repository> home-firewall && cd home-firewall

# 1. Copy files only, without loading anything yet.
sudo ./scripts/install.sh --no-activate

# 2. Set your interface names (find them with: ip -br link).
sudo nano /etc/home-firewall/zones.nft

# 3. Check the configuration.
sudo fw-apply --check

# 4. Activate. You get 60 seconds to confirm, otherwise everything rolls back.
sudo ./scripts/install.sh
```

During the 60-second window, from another device on the LAN: open a website
and open a **new** SSH session to the router. Only then type `yes`.

## 6.3 IPv6 on the WAN

With forwarding enabled, Linux ignores router advertisements unless told
otherwise. If your ISP provides IPv6 and you do not use systemd-networkd or
NetworkManager to configure the WAN, set:

```sh
echo 'net.ipv6.conf.eth0.accept_ra = 2' | sudo tee /etc/sysctl.d/91-wan-ra.conf   # use your WAN_IF
```

## 6.4 Harden the router itself

The firewall limits *who* can reach the router. These steps reduce what an
attacker can do if they get there (threat model R3, R5, R6):

1. **SSH**: key-only login. In `/etc/ssh/sshd_config`:
   `PasswordAuthentication no`, `PermitRootLogin no`, `KbdInteractiveAuthentication no`.
2. **Automatic security updates**: `sudo apt install unattended-upgrades`.
3. **No UPnP**: do not install `miniupnpd` (SR-12).
4. **Wi-Fi**: WPA3 (or WPA2-AES), a long passphrase, WPS off, client
   isolation on the guest SSID, guest and IoT SSIDs on their own VLANs.
5. **Change every default password** on the modem, access points and IoT devices.
6. **Modem in bridge mode** if your ISP allows it, so this router is the only firewall-facing device.

## 6.5 Post-install checks

Run these once after installing, and after any change.

| # | Check | Expected |
|---|-------|----------|
| 1 | `sudo nft list ruleset \| head` | `table inet filter` is present. |
| 2 | `sysctl net.ipv4.ip_forward` | `1` |
| 3 | From a LAN device: browse the web, IPv4 and IPv6 (e.g. test-ipv6.com). | Works. |
| 4 | From a guest device: try to reach a LAN device or `ssh` the router. | Fails. |
| 5 | From **outside** (phone on mobile data): scan your public IP with an online port scanner. | No open ports. |
| 6 | Reboot the router. | Internet works again within a minute; check 1 and 2 still pass. |
| 7 | `sudo systemctl stop nftables` then `sudo nft list ruleset` | Shows `table inet lockdown`, forwarding is `0`. Then `sudo systemctl start nftables`. |

## 6.6 Adding a port forward (only if you really need it)

Every port forward exposes a device to the whole internet. Prefer a VPN
(e.g. WireGuard) instead. If you must, follow the change process in
[07-maintenance.md](07-maintenance.md) and add **both** parts:

```nft
# In table ip nat — new chain:
chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname $WAN_IF tcp dport 8443 dnat to 192.168.1.50:443
}
```

The forward chain already accepts DNAT'd traffic (`ct status dnat accept`),
so no filter change is needed. Give the target device a fixed address, keep
it patched, and add a test to `tests/test_integration.sh` for the new path.

## 6.7 Uninstall / rollback to before installation

```sh
sudo cp /etc/nftables.conf.pre-home-firewall.<date> /etc/nftables.conf   # if it exists
sudo rm -r /etc/home-firewall /etc/systemd/system/nftables.service.d/10-home-firewall.conf \
           /etc/systemd/system/home-firewall-lockdown.service \
           /etc/sysctl.d/90-home-firewall.conf /usr/local/sbin/fw-apply
sudo systemctl daemon-reload && sudo systemctl restart nftables
```
