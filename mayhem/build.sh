#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# libzmq's CMake build is used for both builds. build/ is gitignored upstream, so a `git clean -ffdX`
# removes both build trees and everything below is (re)created from committed content.
# Both trees use the system libsodium (apt libsodium-dev, baked in the Dockerfile): nothing is fetched.

# 1) Sanitized library for fuzzing. -fsanitize=fuzzer-no-link adds the SanCov instrumentation to the
#    library itself (LIB_FUZZING_ENGINE only instruments the harness TU); -O1 as OSS-Fuzz builds it.
FUZZ_FLAGS="-O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake -S . -B build/fuzz -G Ninja -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
    -DBUILD_SHARED=OFF -DBUILD_STATIC=ON -DBUILD_TESTS=OFF -DWITH_DOCS=OFF \
    -DENABLE_CURVE=ON -DWITH_LIBSODIUM=ON -DENABLE_DRAFTS=ON -DENABLE_WS=ON -DENABLE_CPACK=OFF \
    -DLIBZMQ_PEDANTIC=OFF
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target libzmq-static

# 2) The upstream fuzz harnesses (tests/*_fuzzer.cpp, the set OSS-Fuzz builds: builds/fuzz/ci_build.sh +
#    Makefile.am `fuzzer_apps`), each linked twice: libFuzzer, and the run-once standalone reproducer.
#    The harnesses need the testutil helpers + unity, compiled here with the same flags.
OBJ="$SRC/build/fuzz/harness-obj"
mkdir -p "$OBJ"
INCS="-I$SRC/include -I$SRC/build/fuzz -I$SRC/tests -I$SRC/external/unity -DUNITY_USE_COMMAND_LINE_ARGS -DUNITY_EXCLUDE_FLOAT -DZMQ_USE_FUZZING_ENGINE -DZMQ_CUSTOM_PLATFORM_HPP"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $INCS -c "$SRC/external/unity/unity.c" -o "$OBJ/unity.o"
for f in testutil testutil_monitoring testutil_security testutil_unity; do
    $CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $INCS -c "$SRC/tests/$f.cpp" -o "$OBJ/$f.o"
done
# Leak detection off at build time (SPEC §6.2 item 15); ASan and UBSan stay fully active.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

LIBZMQ_A="$(find "$SRC/build/fuzz" -name 'libzmq*.a' -not -path '*/harness-obj/*' | head -n1)"
[ -f "$LIBZMQ_A" ] || { echo "libzmq static archive not found" >&2; exit 1; }
SYSLIBS="$(pkg-config --static --libs libsodium) -lpthread -lrt"

HARNESSES="test_bind_null_fuzzer test_connect_null_fuzzer test_bind_fuzzer test_connect_fuzzer
    test_bind_stream_fuzzer test_connect_stream_fuzzer test_socket_options_fuzzer
    test_bind_curve_fuzzer test_connect_curve_fuzzer test_z85_decode_fuzzer
    test_bind_ws_fuzzer test_connect_ws_fuzzer"
for h in $HARNESSES; do
    $CXX -std=c++11 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $INCS -c "$SRC/tests/$h.cpp" -o "$OBJ/$h.o"
    COMMON="$OBJ/$h.o $OBJ/testutil.o $OBJ/testutil_monitoring.o $OBJ/testutil_security.o $OBJ/testutil_unity.o $OBJ/unity.o $OBJ/lsan_off.o $LIBZMQ_A $SYSLIBS"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $COMMON -o "/mayhem/$h"
    $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/standalone_main.o" $COMMON -o "/mayhem/$h-standalone"
done

# 3) The project's own unit-test suite with NORMAL flags (no sanitizer, no -gdwarf-3, no fuzzer
#    instrumentation), left in build/tests for mayhem/test.sh. Shared AND static: upstream's curve_keygen
#    tool (always built with CURVE) links the shared libzmq, so BUILD_SHARED=OFF cannot build all.
cmake -S . -B build/tests -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DBUILD_SHARED=ON -DBUILD_STATIC=ON -DBUILD_TESTS=ON -DWITH_DOCS=OFF \
    -DENABLE_CURVE=ON -DWITH_LIBSODIUM=ON -DENABLE_DRAFTS=ON -DENABLE_CPACK=OFF
cmake --build build/tests -j"$MAYHEM_JOBS"

# Known-answer probe for mayhem/test.sh (normal flags, dynamically linked against the test build's libzmq).
ZMQ_SHARED="$(find "$SRC/build/tests/lib" -name 'libzmq.so' | head -n1)"
[ -f "$ZMQ_SHARED" ] || { echo "shared libzmq not found in build/tests/lib" >&2; exit 1; }
$CC -O2 $COVERAGE_FLAGS -I"$SRC/include" "$SRC/mayhem/kat/kat_z85.c" "$ZMQ_SHARED" \
    -Wl,-rpath,"$(dirname "$ZMQ_SHARED")" -o "$SRC/build/tests/kat_z85"
