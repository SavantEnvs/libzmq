#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# RUN the upstream unit tests that mayhem/build.sh built (build/tests/bin, normal flags). Each binary is a
# Unity suite that prints "<N> Tests <F> Failures <I> Ignored"; we run them directly and sum those counts.
# A binary that prints no summary (missing, crashed, or neutered into an instant exit(0)) counts as ONE
# failure, so the oracle asserts the suites' own behavioral assertions and cannot be satisfied by a no-op.
BIN="$SRC/build/tests/bin"
TESTS="test_base85 test_msg_init test_msg_flags test_msg_ffn test_pair_inproc test_pair_tcp
  test_reqrep_inproc test_reqrep_tcp test_spec_req test_spec_rep test_spec_router test_spec_dealer
  test_spec_pushpull test_security_null test_security_plain test_sodium test_setsockopt test_ctx_options
  test_hwm test_xpub_topic test_stream test_conflate test_last_endpoint test_iov test_inproc_connect
  test_poller test_timers test_client_server test_radio_dish test_scatter_gather test_ws_transport
  test_metadata test_probe_router test_req_correlate test_atomics test_ancillaries test_proxy
  test_pubsub_topics_count test_term_endpoint test_timeo
  unittest_mtrie unittest_radix_tree unittest_curve_encoding unittest_ypipe unittest_ip_resolver
  unittest_udp_address unittest_poller"

passed=0; failed=0; skipped=0
for t in $TESTS; do
  if [ ! -x "$BIN/$t" ]; then echo "FAIL $t: not built (build.sh bug)"; failed=$((failed+1)); continue; fi
  out="$(cd "$SRC/build/tests" && timeout 300 "$BIN/$t" 2>&1)"; rc=$?
  sum="$(printf '%s\n' "$out" | grep -E '^[0-9]+ Tests [0-9]+ Failures [0-9]+ Ignored' | tail -n1)"
  if [ -z "$sum" ]; then echo "FAIL $t: no Unity summary (rc=$rc)"; failed=$((failed+1)); continue; fi
  read -r n _ f _ i _ <<<"$sum"
  p=$((n - f - i))
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then f=1; p=$((p>0 ? p-1 : 0)); fi
  passed=$((passed+p)); failed=$((failed+f)); skipped=$((skipped+i))
  echo "$t: $sum (rc=$rc)"
done

# Known-answer probe, independent of the Unity binaries: the Z85 test vector from RFC 32 (zmq_z85_encode)
# through a tiny dynamically-linked program against the project's libzmq.
KAT="$SRC/build/tests/kat_z85"
if [ ! -x "$KAT" ]; then echo "FAIL kat_z85: not built (build.sh bug)"; failed=$((failed+1))
else
  got="$("$KAT" 2>&1)"
  if [ "$got" = "HelloWorld" ]; then passed=$((passed+1)); echo "kat_z85: ok"
  else failed=$((failed+1)); echo "FAIL kat_z85: expected 'HelloWorld', got '$got'"; fi
fi

emit_ctrf "unity" "$passed" "$failed" "$skipped"
