# 4. Implementation

**Phase:** Implementation

## 4.1 Source layout

| Path | What it is |
|------|------------|
| `src/nftables.conf` | Main ruleset (installed as `/etc/nftables.conf`). |
| `src/home-firewall/zones.nft` | Site settings template (interface names, SSH port). |
| `src/home-firewall/lockdown.nft` | Emergency ruleset (SR-13). |
| `src/sysctl.d/90-home-firewall.conf` | Kernel hardening (SR-15). |
| `src/systemd/` | Fail-closed service integration (SR-13). |
| `scripts/fw-apply` | Validate / apply / auto-rollback tool (SR-13, SR-14). |
| `scripts/install.sh` | Installer (SR-16). |
| `tests/` | Test lab and suites (see [05-verification.md](05-verification.md)). |

## 4.2 Coding standards

**nftables**

- Every rule that implements a requirement carries its ID in a comment (`# SR-08`).
- Interfaces are only ever referenced through the `zones.nft` variables;
  a test fails if a literal interface name appears in the ruleset.
- Every `log` statement is preceded by a `limit` (checked by a test).
- New "allow" rules go in the zone chains or the zone matrix, never before the
  `invalid` / non-SYN drops.
- `drop` towards the internet, `reject` towards internal devices (D-01, D-02).

**Shell**

- `#!/usr/bin/env bash` with `set -Eeuo pipefail`.
- `shellcheck` clean with no global disables; a local disable needs a reason
  in a comment.
- All variables quoted; `--` before file arguments; no `eval`.
- Absolute paths to privileged binaries (`/usr/sbin/nft`), never taken from the
  environment.
- `umask 077` for anything that writes backups or state.
- User input (e.g. `--timeout`) is validated against a strict allow-list
  pattern and range.

**Python (tests only)**

- Standard library only, run with `python3 -I` (isolated mode: no user site
  packages, no current-directory imports).

## 4.3 Secure code review checklist

Every change must be reviewed against this list before merge.

- [ ] Does the change add an `accept`? Which zone and which port? Is it in the
      design matrices, and is there a test that it is allowed *and* that
      neighbouring traffic is still blocked?
- [ ] Does it touch the WAN at all? WAN exposure requires a threat-model update.
- [ ] Did it add a `log` without a `limit`?
- [ ] IPv6 handled exactly like IPv4 (an `ip` rule without an `ip6` twin is a
      red flag)?
- [ ] Rule order: is anything placed before the `invalid` / non-SYN drops?
- [ ] Shell: quoting, `--`, error handling, no new environment-controlled paths.
- [ ] Requirement IDs, design doc and CHANGELOG updated.
- [ ] `sudo make lint test` passes locally and CI is green with IPv6 enabled.

## 4.4 Defects found during development

Recorded here because they show why each check exists.

| # | Found by | Defect | Fix |
|---|----------|--------|-----|
| 1 | SR-10 live test | Ping rate limit never triggered: after the first ping, conntrack treats the stream as one established flow, which was accepted before reaching the limit. | Ping limits moved before `established,related`; a static test now enforces the order. |
| 2 | Security review | Forward chain accepted any ICMPv6 error, so internet hosts could send unsolicited ICMPv6 to home devices. | Rule removed; legitimate errors pass as `related` (D-09). New live test. |
| 3 | Security review | `fw-apply`: a signal arriving just after the new rules loaded, but before the "applied" flag was set, would skip the rollback. | Flag set before loading. |
| 4 | Design review | Installer: if the admin rejected the new rules, `/etc/nftables.conf` still held them, so a reboot would load them. | Previous file restored; service enabled only after confirmation. |
| 5 | Test review | A counter helper returned 0 when no rule matched, so a check could pass or fail for the wrong reason. | The helper now fails loudly. |
