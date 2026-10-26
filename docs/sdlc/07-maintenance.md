# 7. Operations and maintenance

**Phase:** Maintenance

## 7.1 Change process

Every change to the firewall follows the same steps, however small:

1. **Request**: write down what should be allowed or blocked and why
   (a GitHub issue is fine).
2. **Requirements and threat model**: add or update an ID in
   [01-requirements.md](01-requirements.md); if it touches the WAN, update
   [02-threat-model.md](02-threat-model.md).
3. **Design**: update the matrices in [03-design.md](03-design.md).
4. **Implement** on a branch, with the requirement ID in a rule comment.
5. **Test**: add a positive and a negative test; `sudo make lint && sudo tests/run.sh`.
6. **Review** against the checklist in [04-implementation.md](04-implementation.md) §4.3; CI must be green.
7. **Deploy** with `sudo fw-apply` (60-second rollback window), then run the
   post-install checks in [06-deployment.md](06-deployment.md) §6.5.
8. **Record** the change in `CHANGELOG.md` and tag a release.

Emergency change (e.g. you are under attack): steps 4, 7 first, then
complete the rest within a week.

## 7.2 Routine tasks

| When | Task |
|------|------|
| Automatic | Security updates (`unattended-upgrades`). |
| Monthly | Look at drop logs: `sudo journalctl -k --since "1 month ago" \| grep fw-` |
| Monthly | Check SSH throttling counters: `sudo nft list chain inet filter input_lan` |
| Every 6 months | Re-run the outside port scan (§6.5 check 5). Review the device list in each zone. |
| Yearly | Review the threat model and bogon list (IANA changes rarely). Re-read this document. |

## 7.3 Monitoring

Dropped packets are logged (rate-limited) with the prefixes
`fw-input-drop:` and `fw-forward-drop:`. Internet background noise in
`fw-input-drop` is normal. Things worth investigating:

- `fw-forward-drop` with `IN=<iot>` and `OUT=<lan>`: an IoT device is trying
  to reach your computers.
- Many drops from one LAN/guest device to the internet on ports 445, 25: that device may be infected.
- Rising counters on the spoofing rule:
  `sudo nft list chain inet filter prerouting`.

## 7.4 Incident response

If you think a device or the router is compromised:

1. **Contain**: unplug the suspect device or move it to the IoT/guest network.
   If the router itself is suspect: `sudo systemctl stop nftables` puts it into
   lockdown (no forwarding, SSH from LAN only).
2. **Preserve**: `sudo journalctl -k > ~/incident-$(date +%F).log` and
   `sudo nft list ruleset > ~/ruleset-$(date +%F).nft`.
3. **Eradicate**: factory-reset the device. For the router, reinstall the OS
   and this firewall from the repository (do not reuse files from the old system).
4. **Recover**: change Wi-Fi and account passwords.
5. **Learn**: if the firewall should have stopped it, write a requirement and
   test (§7.1).

## 7.5 Recovering from a lockout

- Within the 60-second window: do nothing; `fw-apply` rolls back.
- After a confirmed bad change: from the console, `sudo fw-apply --yes
  /var/lib/home-firewall/backup-<latest>.nft`, or `sudo systemctl stop nftables`
  for the lockdown ruleset (LAN SSH allowed).

## 7.6 Supported versions and end of life

Only the latest release receives fixes. When the router's OS reaches end of
life, upgrade it or replace the router: a firewall cannot protect a kernel
that no longer gets security fixes.
