#!/usr/bin/env python3
"""Requirements traceability check (NFR-02).

Reads every requirement ID from docs/sdlc/01-requirements.md and the test
results written by the suites, then fails unless every requirement has at
least one PASS and no FAIL. A requirement covered only by SKIPs fails too.
Writes a Markdown report.

  traceability.py RESULTS_TSV REPORT_MD
"""
import collections
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
req_doc = (root / "docs/sdlc/01-requirements.md").read_text()
reqs = {}
for m in re.finditer(r"^\| ((?:FR|SR|NFR)-\d+)\s*\| (.+?) \|$", req_doc, re.M):
    reqs[m.group(1)] = m.group(2)

results = collections.defaultdict(lambda: collections.Counter())
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    status, tags, _desc = line.split("\t", 2)
    for tag in tags.split(","):
        results[tag.strip()][status] += 1

# NFR-02 is "every requirement is verified by an automated test" — that is
# exactly what this script checks, so it is satisfied when the others are.
problems = []
rows = []
for rid in reqs:
    c = results.get(rid, collections.Counter())
    if rid == "NFR-02":
        continue
    if c["FAIL"]:
        verdict = "FAIL"
    elif c["PASS"]:
        verdict = "verified"
    else:
        verdict = "NOT VERIFIED"
    if verdict != "verified":
        problems.append(rid)
    rows.append((rid, c["PASS"], c["FAIL"], c["SKIP"], verdict))
unknown = sorted(set(results) - set(reqs))
nfr02 = "verified" if not problems and not unknown else "FAIL"
rows.append(("NFR-02", len(reqs) - 1 - len(problems), len(problems), 0, nfr02))

out = ["# Verification report", "",
       "| Requirement | Pass | Fail | Skip | Result |", "|---|---|---|---|---|"]
out += [f"| {r} | {p} | {f} | {s} | {v} |" for r, p, f, s, v in rows]
if unknown:
    out += ["", "Tests reference unknown requirement IDs: " + ", ".join(unknown)]
pathlib.Path(sys.argv[2]).write_text("\n".join(out) + "\n")
print("\n".join(out))

if problems or unknown:
    print(f"\nTRACEABILITY FAILED: {', '.join(problems + unknown)}", file=sys.stderr)
    sys.exit(1)
print(f"\nAll {len(reqs)} requirements verified.")
