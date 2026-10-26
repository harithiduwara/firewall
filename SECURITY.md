# Security policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Use GitHub's
private vulnerability reporting ("Security" tab → "Report a vulnerability")
and include:

- what traffic gets through (or is wrongly blocked), with source and destination zone;
- the nftables version (`nft --version`) and kernel (`uname -r`);
- your `zones.nft` (no other personal data needed).

You should get an answer within 7 days. Fixes follow the change process in
[docs/sdlc/07-maintenance.md](docs/sdlc/07-maintenance.md), including a new
regression test.

## Supported versions

Only the latest release is supported.
