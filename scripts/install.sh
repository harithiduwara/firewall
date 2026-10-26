#!/usr/bin/env bash
# =============================================================================
# install.sh — install Home Firewall on a Debian/Ubuntu/Raspberry Pi OS router.
#
# Usage: sudo ./scripts/install.sh [--no-activate]
#
#   --no-activate   Copy files only; do not enable the service or load rules.
#
# Environment:
#   DESTDIR   Install into a staging root instead of / (used by the tests).
#
# Safe to run again for upgrades: an existing zones.nft is never overwritten.
# =============================================================================
set -Eeuo pipefail
umask 022

ACTIVATE=1
case ${1:-} in
    "")            ;;
    --no-activate) ACTIVATE=0 ;;
    *) echo "usage: $0 [--no-activate]" >&2; exit 2 ;;
esac

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DESTDIR=${DESTDIR:-}
NFT=/usr/sbin/nft

log() { printf 'install: %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[[ ${EUID} -eq 0 ]] || die "must be run as root (sudo)"
[[ -x ${NFT} ]]     || die "nftables is not installed: sudo apt install nftables"
if [[ -n ${DESTDIR} ]]; then
    ((ACTIVATE == 0)) || die "DESTDIR requires --no-activate"
    [[ -d ${DESTDIR} ]] || die "DESTDIR '${DESTDIR}' does not exist"
fi

ETC=${DESTDIR}/etc
ZONES=${ETC}/home-firewall/zones.nft

# SR-16: root-owned, not writable by anyone else.
inst() { install -o root -g root -m "$1" -D -- "$2" "$3"; }

# --- Validate before touching anything (SR-13) --------------------------------
# Validate against the zones file that will actually be used.
stage=$(mktemp -d)
trap 'rm -rf -- "${stage}"' EXIT
mkdir -p -- "${stage}/home-firewall"
if [[ -f ${ZONES} ]]; then
    cp -- "${ZONES}" "${stage}/home-firewall/zones.nft"
else
    cp -- "${SRC}/src/home-firewall/zones.nft" "${stage}/home-firewall/zones.nft"
fi
for f in "${SRC}/src/nftables.conf" "${SRC}/src/home-firewall/lockdown.nft"; do
    "${NFT}" -I "${stage}" -c -f "${f}" || die "validation of ${f} failed — nothing installed"
done
log "rulesets validated"

# --- Install ------------------------------------------------------------------
backup=""
if [[ -f ${ETC}/nftables.conf ]] && ! cmp -s -- "${ETC}/nftables.conf" "${SRC}/src/nftables.conf"; then
    backup=${ETC}/nftables.conf.pre-home-firewall.$(date +%Y%m%d-%H%M%S)
    cp -p -- "${ETC}/nftables.conf" "${backup}"
    log "existing /etc/nftables.conf saved as ${backup#"${DESTDIR}"}"
fi

inst 0644 "${SRC}/src/nftables.conf"                    "${ETC}/nftables.conf"
inst 0644 "${SRC}/src/home-firewall/lockdown.nft"       "${ETC}/home-firewall/lockdown.nft"
if [[ -f ${ZONES} ]]; then
    log "keeping your existing ${ZONES#"${DESTDIR}"}"
else
    inst 0644 "${SRC}/src/home-firewall/zones.nft"      "${ZONES}"
fi
chmod 0755 -- "${ETC}/home-firewall"
inst 0644 "${SRC}/src/sysctl.d/90-home-firewall.conf"   "${ETC}/sysctl.d/90-home-firewall.conf"
inst 0644 "${SRC}/src/systemd/nftables.service.d/10-home-firewall.conf" \
          "${ETC}/systemd/system/nftables.service.d/10-home-firewall.conf"
inst 0644 "${SRC}/src/systemd/home-firewall-lockdown.service" \
          "${ETC}/systemd/system/home-firewall-lockdown.service"
inst 0755 "${SRC}/scripts/fw-apply"                     "${DESTDIR}/usr/local/sbin/fw-apply"
log "files installed"

if ((ACTIVATE == 0)); then
    log "done (not activated). Edit ${ZONES#"${DESTDIR}"}, then run: sudo $0"
    exit 0
fi

# --- Activate -----------------------------------------------------------------
sysctl -q --load=/etc/sysctl.d/90-home-firewall.conf
systemctl daemon-reload

log "loading the firewall with a 60-second safety rollback"
if ! /usr/local/sbin/fw-apply /etc/nftables.conf; then
    # The live rules were rolled back; make sure a reboot does not load the
    # rejected ruleset either.
    if [[ -n ${backup} ]]; then
        cp -p -- "${backup}" /etc/nftables.conf
        log "restored your previous /etc/nftables.conf"
    else
        rm -f -- /etc/nftables.conf
    fi
    die "not confirmed — firewall NOT enabled. Check ${ZONES} and run again."
fi

# Only now: load at every boot, and start routing (SR-13).
systemctl enable nftables.service
sysctl -q -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
log "done. Home Firewall is active and will load at every boot."
