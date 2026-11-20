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

: "${DUCKDB_SRC:=/opt/toolchains/deps/duckdb-d54cbbe3df17e8e5ce68312f483b4155836112aa/src}"
: "${ROARING_PREFIX:=/opt/toolchains/deps/croaring-4.3.11}"
BUILD="$SRC/build/fuzz"          # gitignored (upstream .gitignore: `build`)
HARNESSES=(fuzz_deletion_vector fuzz_sql fuzz_add_data_files fuzz_rest_request fuzz_rest_response)

# 1) DuckDB (pinned dependency, normal Release flags) with the ducklake extension statically linked,
#    exactly as upstream's extension_config.cmake describes. Only the ducklake sources get the
#    sanitizer + coverage + DWARF-3 flags, injected by mayhem/ducklake_fuzz_flags.cmake right after
#    project(ducklake). Every executable/shared object links the sanitizer runtime.
#    DISABLE_EXTENSIONS_FOR_TEST drops tpch (json/icu/parquet/core_functions stay, from DuckDB's base
#    config). OVERRIDE_GIT_DESCRIBE: the pinned DuckDB is a tarball, not a git checkout.
export DUCKLAKE_FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
export DISABLE_EXTENSIONS_FOR_TEST=1
LINK_SAN="$SANITIZER_FLAGS"
cmake -G Ninja -S "$DUCKDB_SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DOVERRIDE_GIT_DESCRIBE=v1.5.0 \
  -DDUCKDB_EXTENSION_CONFIGS="$SRC/extension_config.cmake" \
  -DCMAKE_PROJECT_ducklake_INCLUDE="$SRC/mayhem/ducklake_fuzz_flags.cmake" \
  -DCMAKE_PREFIX_PATH="$ROARING_PREFIX" \
  -DENABLE_SANITIZER=OFF -DENABLE_UBSAN=OFF -DENABLE_JEMALLOC=OFF \
  -DBUILD_UNITTESTS=ON -DBUILD_SHELL=ON \
  -DCMAKE_EXE_LINKER_FLAGS="$LINK_SAN" -DCMAKE_SHARED_LINKER_FLAGS="$LINK_SAN"
cmake --build "$BUILD" -j"$MAYHEM_JOBS" --target duckdb_static ducklake_extension shell unittest

mapfile -t LIBS < <(find "$BUILD" -name '*.a' -not -path '*/CMakeFiles/*' | sort)
INCS=(-I"$DUCKDB_SRC/src/include" -I"$SRC/src/include" -I"$ROARING_PREFIX/include" -I"$DUCKDB_SRC/extension/core_functions/include" -I"$DUCKDB_SRC/extension/json/include" -I"$DUCKDB_SRC/extension/parquet/include" -I"$SRC/mayhem/harnesses")
LDLIBS=(-Wl,--start-group "${LIBS[@]}" -Wl,--end-group "$ROARING_PREFIX/lib/libroaring.a" -lpthread -ldl -lm)

# 2) Harnesses: libFuzzer binary + standalone reproducer each, LSan off in both.
OBJ="$BUILD/mayhem-obj"; mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
for h in "${HARNESSES[@]}"; do
  $CXX -std=c++17 -O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS "${INCS[@]}" \
    -c "$SRC/mayhem/harnesses/$h.cpp" -o "$OBJ/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/$h.o" "$OBJ/lsan_off.o" \
    "${LDLIBS[@]}" -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/$h.o" "$OBJ/standalone_main.o" "$OBJ/lsan_off.o" \
    "${LDLIBS[@]}" -o "/mayhem/$h-standalone"
done

# 3) Functional oracle: DuckDB's sqllogictest runner (`unittest`) and shell from the same tree
#    (ducklake statically linked). mayhem/test.sh runs upstream's test/sql/**/*.test with the runner,
#    plus known-answer SQL through the shell. DuckDB itself carries its normal Release flags; the
#    ducklake code in both is the instrumented build (a second, uninstrumented DuckDB+ducklake tree
#    would double the ~6 min compile).
ln -sf "$BUILD/duckdb" /mayhem/duckdb-ducklake
ln -sf "$BUILD/test/unittest" /mayhem/unittest-ducklake
