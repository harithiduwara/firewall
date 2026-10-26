# shellcheck shell=bash
# Shared helpers for the test suites. Every check is tagged with the
# requirement IDs it verifies; tests/traceability.py uses those tags.

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034
ROOT_DIR=$(cd -- "${TESTS_DIR}/.." && pwd)
# shellcheck disable=SC2034
PROBE="${TESTS_DIR}/probe.py"
RESULTS_FILE=${RESULTS_FILE:-/dev/null}

PASS=0
FAIL=0
SKIP=0

# IPv6 tests run only when the kernel supports IPv6. CI sets REQUIRE_IPV6=1 so
# a missing IPv6 stack there is a hard failure, never a silent skip.
if [[ -e /proc/net/if_inet6 ]]; then HAVE_IPV6=1; else HAVE_IPV6=0; fi
if [[ ${REQUIRE_IPV6:-0} == 1 && ${HAVE_IPV6} == 0 ]]; then
    echo "REQUIRE_IPV6=1 but this kernel has no IPv6 support" >&2
    exit 1
fi

_record() { # status reqs description
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${RESULTS_FILE}"
}

pass() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m [%s] %s\n' "$1" "$2"; _record PASS "$1" "$2"; }
fail() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m [%s] %s\n' "$1" "$2"; _record FAIL "$1" "$2"; }

# check REQS "description" command...   — passes if the command succeeds
check() {
    local reqs=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then pass "${reqs}" "${desc}"; else fail "${reqs}" "${desc}"; fi
}

# check_not REQS "description" command... — passes if the command fails
check_not() {
    local reqs=$1 desc=$2; shift 2
    if "$@" >/dev/null 2>&1; then fail "${reqs}" "${desc}"; else pass "${reqs}" "${desc}"; fi
}

# check_eq REQS "description" expected actual
check_eq() {
    if [[ $3 == "$4" ]]; then pass "$1" "$2"; else fail "$1" "$2 (expected '$3', got '$4')"; fi
}

skip() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m [%s] %s\n' "$1" "$2"; _record SKIP "$1" "$2"; }

# v6 check|check_not|check_eq ... — run an IPv6 check, or SKIP without IPv6.
v6() {
    if ((HAVE_IPV6)); then "$@"; else skip "$2" "$3 (no IPv6 in this kernel)"; fi
}

section() { printf '\n== %s ==\n' "$*"; }

summary() {
    printf '\n%s: %d passed, %d failed, %d skipped\n' "$1" "${PASS}" "${FAIL}" "${SKIP}"
    ((FAIL == 0))
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "These tests need root (they create network namespaces). Run: sudo $0" >&2
        exit 2
    fi
}
