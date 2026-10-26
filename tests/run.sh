#!/usr/bin/env bash
# Run every test suite, then the requirements traceability check.
#   sudo tests/run.sh            (set REQUIRE_IPV6=1 to forbid IPv6 skips)
set -uo pipefail
TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT=${TESTS_DIR}/out
mkdir -p "${OUT}"
export RESULTS_FILE=${OUT}/results.tsv
: > "${RESULTS_FILE}"

rc=0
for suite in test_static.sh test_apply.sh test_integration.sh; do
    bash "${TESTS_DIR}/${suite}" || rc=1
done
echo
python3 -I "${TESTS_DIR}/traceability.py" "${RESULTS_FILE}" "${OUT}/verification-report.md" || rc=1
exit "${rc}"
