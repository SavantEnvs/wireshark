#!/usr/bin/env bash
#
# mayhem/build.sh — build Wireshark's fuzzshark harnesses (fuzz/fuzzshark.c, the same targets OSS-Fuzz
# builds via tools/oss-fuzzshark/build.sh) with the sanitized project, plus a plain tshark/dftest build
# for the functional oracle (mayhem/test.sh).
#
# Runs inside the commit image as `mayhem` in /mayhem. Re-runnable and offline: every dependency is an
# apt -dev package installed by mayhem/Dockerfile; cmake/ninja only touch build-fuzz/ and build-test/
# (both gitignored by upstream's /*build*/ rule).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Feature set matches OSS-Fuzz's build (no pcap/gnutls/plugins/GUI); everything else is auto-detected
# from the apt packages the Dockerfile installs.
# The compiler comes from the exported CC/CXX, never -DCMAKE_C_COMPILER: a re-run that names the compiler
# differently from the cached (ccache-masquerade) path makes CMake wipe its cache and fall back to defaults.
COMMON_DEFS=(-GNinja
             -DENABLE_PLUGINS=OFF -DENABLE_PCAP=OFF -DENABLE_GNUTLS=OFF -DBUILD_wireshark=OFF
             -DENABLE_WERROR=OFF)

# 1) Sanitized project + fuzzers. ENABLE_FUZZER adds -fsanitize=fuzzer-no-link to every compile (coverage
#    in the libraries) and links fuzzshark_* with -fsanitize=fuzzer; they land in build-fuzz/run/.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1"
cmake -S "$SRC" -B "$SRC/build-fuzz" "${COMMON_DEFS[@]}" \
      -DENABLE_FUZZER=ON -DBUILD_fuzzshark=ON \
      -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS"
ninja -C "$SRC/build-fuzz" -j"$MAYHEM_JOBS" all-fuzzers

# 2) Per-harness binaries. CMake already linked each fuzzshark_* once; take its exact link command from
#    ninja and relink it (a) with the LeakSanitizer-off hook and (b) against the run-once driver.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

cd "$SRC/build-fuzz"
for f in run/fuzzshark_*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  name="${f##*/}"
  link="$(ninja -t commands "run/$name" | tail -n 1)"
  [[ "$link" == *"-o run/$name"* ]] || { echo "unexpected link line for $name: $link" >&2; exit 1; }
  # libFuzzer binary (+ lsan hook)
  bash -c "${link//-o run\/$name/-o $SRC/$name /tmp/lsan_off.o -Wl,-rpath,$SRC/build-fuzz/run}"
  # standalone reproducer: same link, run-once main instead of the libFuzzer runtime
  standalone="$(printf '%s' "$link" | sed -E 's/-fsanitize=fuzzer( |$)/\1/g')"
  bash -c "${standalone//-o run\/$name/-o $SRC/$name-standalone /tmp/standalone_main.o /tmp/lsan_off.o -Wl,-rpath,$SRC/build-fuzz/run}"
done
cd "$SRC"

# 3) Plain (unsanitized) build of the programs the functional suite drives.
cmake -S "$SRC" -B "$SRC/build-test" "${COMMON_DEFS[@]}" \
      -DBUILD_fuzzshark=OFF -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS_RELEASE="-O1 $COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS_RELEASE="-O1 $COVERAGE_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS"
ninja -C "$SRC/build-test" -j"$MAYHEM_JOBS" tshark dftest editcap capinfos mergecap text2pcap copy_data_files
