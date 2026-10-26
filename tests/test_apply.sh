#!/usr/bin/env bash
# Tests for fw-apply: validation, backup, confirmation and automatic rollback.
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_root

NS=hf-apply
WORK=$(mktemp -d)
STATE=${WORK}/state
cleanup() { ip netns del "${NS}" 2>/dev/null; rm -rf -- "${WORK}"; }
trap cleanup EXIT
ip netns del "${NS}" 2>/dev/null
ip netns add "${NS}"

FW_APPLY=${ROOT_DIR}/scripts/fw-apply
RULESET=${ROOT_DIR}/src/nftables.conf

apply() { ip netns exec "${NS}" env FW_INCLUDE_DIR="${TESTS_DIR}/fixtures" FW_STATE_DIR="${STATE}" "${FW_APPLY}" "$@"; }
has_table() { ip netns exec "${NS}" nft list tables | grep -qx "table $1"; }
set_marker() { ip netns exec "${NS}" nft -f - <<<'flush ruleset
table inet marker { chain c { type filter hook input priority 0; policy accept; }; }'; }

printf 'table inet broken {\n  chain c { this is not nftables }\n}\n' > "${WORK}/broken.nft"

# -----------------------------------------------------------------------------
section "Validation (SR-13)"
set_marker
check     "SR-13" "--check accepts the real ruleset"                   apply --check "${RULESET}"
check     "SR-13" "--check changes nothing"                            has_table "inet marker"
check_not "SR-13" "a ruleset with a syntax error is refused"           apply --yes "${WORK}/broken.nft"
check     "SR-13" "after a refused ruleset the old rules are still active" has_table "inet marker"
check_not "SR-13" "a missing ruleset file is refused"                  apply --yes "${WORK}/nope.nft"
check_not "SR-14" "an out-of-range --timeout is refused"              apply --timeout 1 "${RULESET}"
check_not "SR-14" "a non-numeric --timeout is refused"                apply --timeout 'x;id' "${RULESET}"

# -----------------------------------------------------------------------------
section "Automatic rollback (SR-14)"
set_marker
check_not "SR-14" "no confirmation (stdin closed) -> fw-apply reports failure" apply "${RULESET}" </dev/null
check     "SR-14" "...and the previous ruleset is back"                has_table "inet marker"
check_not "SR-14" "...and the new ruleset is gone"                     has_table "inet filter"

set_marker
start=${SECONDS}
check_not "SR-14" "silence for the whole timeout -> rollback"          bash -c '"$@" < <(sleep 30)' _ \
    ip netns exec "${NS}" env FW_INCLUDE_DIR="${TESTS_DIR}/fixtures" FW_STATE_DIR="${STATE}" "${FW_APPLY}" --timeout 5 "${RULESET}"
took=$((SECONDS - start))
check     "SR-14" "rollback happened after the timeout (${took}s, expect 5-15s)" test "${took}" -ge 5 -a "${took}" -le 15
check     "SR-14" "...and the previous ruleset is back"                has_table "inet marker"

set_marker
check_not "SR-14" "a wrong answer ('y') -> rollback"                   bash -c 'echo y | "$@"' _ \
    ip netns exec "${NS}" env FW_INCLUDE_DIR="${TESTS_DIR}/fixtures" FW_STATE_DIR="${STATE}" "${FW_APPLY}" "${RULESET}"
check     "SR-14" "...and the previous ruleset is back"                has_table "inet marker"

set_marker
( sleep 2; pkill -TERM -f "^bash ${FW_APPLY} --timeout 30" ) &
check_not "SR-14" "fw-apply killed during the confirmation window -> rollback" bash -c '"$@" < <(sleep 60)' _ \
    ip netns exec "${NS}" env FW_INCLUDE_DIR="${TESTS_DIR}/fixtures" FW_STATE_DIR="${STATE}" "${FW_APPLY}" --timeout 30 "${RULESET}"
wait
check     "SR-14" "...and the previous ruleset is back"                has_table "inet marker"

# -----------------------------------------------------------------------------
section "Confirmed apply"
set_marker
check     "SR-14" "typing 'yes' keeps the new ruleset"                 bash -c 'echo yes | "$@"' _ \
    ip netns exec "${NS}" env FW_INCLUDE_DIR="${TESTS_DIR}/fixtures" FW_STATE_DIR="${STATE}" "${FW_APPLY}" "${RULESET}"
check     "SR-14" "...the firewall is active"                          has_table "inet filter"
check_not "SR-14" "...the old ruleset is gone"                         has_table "inet marker"

# The live firewall now holds dynamic state (SSH meter entries). A rollback
# must be able to restore it exactly.
ip netns exec "${NS}" nft add element inet filter ssh_meter_v4 '{ 192.168.1.50 }'
check_not "SR-14" "rejecting a change while the firewall holds dynamic state -> rollback" \
    apply "${ROOT_DIR}/src/home-firewall/lockdown.nft" </dev/null
check     "SR-14" "...the full firewall (not lockdown) is restored"    has_table "inet filter"
check_not "SR-14" "...and lockdown is not left behind"                 has_table "inet lockdown"

# -----------------------------------------------------------------------------
section "Backups (SR-16)"
check_eq "SR-16" "state directory is mode 0700"  700 "$(stat -c %a "${STATE}")"
modes=$(find "${STATE}" -name 'backup-*.nft' -printf '%m\n' | sort -u | tr '\n' ' ')
check_eq "SR-16" "backups are mode 0600"         "600 " "${modes}"
for _ in $(seq 12); do apply --yes "${RULESET}" >/dev/null 2>&1; sleep 0.01; done
count=$(find "${STATE}" -name 'backup-*.nft' | wc -l)
check "SR-16" "old backups are pruned (${count} kept, max 10)" test "${count}" -le 10

summary "apply"
