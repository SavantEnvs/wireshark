#!/usr/bin/env bash
#
# mayhem/test.sh — RUN Wireshark's own pytest suites against the plain tshark/dftest/... build that
# mayhem/build.sh left in build-test/run. Each test dissects a real capture and compares the output with
# an asserted value or golden baseline, so a neutered binary fails them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

RUN_DIR="$SRC/build-test/run"
for p in tshark dftest editcap capinfos mergecap text2pcap; do
  [ -x "$RUN_DIR/$p" ] || { echo "missing $RUN_DIR/$p — mayhem/build.sh should have built it" >&2; emit_ctrf wireshark-pytest 0 1 0; exit 1; }
done

# Display-filter engine, dissection baselines (DIS, BGP, ...), output formats (JSON/EK/PDML/text) and
# mergecap. Test paths come first: --program-path is registered by test/conftest.py, which pytest only
# loads once it has seen a test path.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
python3 -m pytest -p no:cacheprovider -n "${MAYHEM_JOBS:-$(nproc)}" \
    test/suite_dfilter test/suite_dissection_dis.py test/suite_dissectors \
    test/suite_outputformats.py test/suite_mergecap.py test/suite_text2pcap.py \
    --program-path "$RUN_DIR" 2>&1 | tee "$LOG"

summary="$(grep -E '^=+ .*(passed|failed|error).* in [0-9.]+s' "$LOG" | tail -n 1)"
count() { sed -nE "s/.*[^0-9]([0-9]+) $1.*/\1/p" <<<"$summary" | head -n 1; }
passed="$(count passed)"; failed="$(count failed)"; errors="$(count error)"; skipped="$(count skipped)"
passed="${passed:-0}"; failed=$(( ${failed:-0} + ${errors:-0} )); skipped="${skipped:-0}"
[ -n "$summary" ] || failed=$(( failed + 1 ))
emit_ctrf wireshark-pytest "$passed" "$failed" "$skipped"
