# Changelog

All notable changes are recorded here. Versions follow semantic versioning:
a change that alters what traffic is allowed is at least a minor version.

## [1.0.0] - 2026-10-26

### Added
- nftables ruleset with LAN, guest and IoT zones, IPv4 + IPv6 (FR-01..FR-08, SR-01..SR-12).
- Lockdown ruleset and systemd integration for fail-closed behaviour (SR-13).
- `fw-apply`: validate, apply, automatic rollback (SR-13, SR-14).
- Kernel hardening sysctls (SR-15) and installer with safe file permissions (SR-16).
- Network-namespace test lab, static and tool tests, requirements traceability check, CI.
- SDLC documentation: requirements, threat model, design, implementation,
  verification, deployment, maintenance.
