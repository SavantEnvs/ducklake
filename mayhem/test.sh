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

# Known-answer SQL checks against the DuckDB shell built by mayhem/build.sh (ducklake statically
# linked): each case runs a script on a fresh ducklake catalog in a scratch dir and diffs the CSV
# output with the expected rows.
DUCKDB="$SRC/duckdb-ducklake"
[ -x "$DUCKDB" ] || { echo "missing $DUCKDB — run mayhem/build.sh" >&2; emit_ctrf ducklake-sql 0 1; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ducklake-test-XXXXXX"); trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

# run_case <name> <expected output> <sql>
run_case() {
  local name="$1" expected="$2" sql="$3" dir="$WORK/$1" out
  mkdir -p "$dir"
  out=$(cd "$dir" && printf '%s\n' "LOAD ducklake;" \
        "ATTACH 'ducklake:meta.db' AS l (DATA_PATH 'data', DATA_INLINING_ROW_LIMIT 0);" \
        "USE l;" "$sql" | "$DUCKDB" -csv -noheader 2>&1)
  if [ "$out" == "$expected" ]; then passed=$((passed+1)); echo "PASS $name"
  else failed=$((failed+1)); echo "FAIL $name"; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out") | head -20; fi
}

# run_case_err <name> <expected error substring> <sql>
run_case_err() {
  local name="$1" pattern="$2" sql="$3" dir="$WORK/$1" out
  mkdir -p "$dir"
  out=$(cd "$dir" && printf '%s\n' "LOAD ducklake;" \
        "ATTACH 'ducklake:meta.db' AS l (DATA_PATH 'data', DATA_INLINING_ROW_LIMIT 0);" \
        "USE l;" "$sql" | "$DUCKDB" -csv -noheader 2>&1)
  if grep -qF -- "$pattern" <<<"$out"; then passed=$((passed+1)); echo "PASS $name"
  else failed=$((failed+1)); echo "FAIL $name (no '$pattern' in output)"; printf '%s\n' "$out" | head -20; fi
}

run_case basic_insert_select "3,60" \
  "CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (10),(20),(30); SELECT count(*), sum(i) FROM t;"

run_case deletion_vector "85,4215" \
  "CALL l.set_option('write_deletion_vectors', true);
   CREATE TABLE t AS SELECT range::INTEGER AS i FROM range(100);
   DELETE FROM t WHERE i % 7 = 0;
   SELECT count(*), sum(i) FROM t;"

run_case delete_file_is_puffin "true" \
  "CALL l.set_option('write_deletion_vectors', true);
   CREATE TABLE t AS SELECT range::INTEGER AS i FROM range(10);
   DELETE FROM t WHERE i = 3;
   SELECT delete_file LIKE '%.puffin' FROM ducklake_list_files('l', 't');"

run_case_err corrupt_deletion_vector_trailing "unexpected trailing bytes" \
  "CALL l.set_option('write_deletion_vectors', true);
   CREATE TABLE t AS SELECT range::INTEGER AS i FROM range(10);
   DELETE FROM t WHERE i = 0;
   SET VARIABLE p = (SELECT delete_file FROM ducklake_list_files('l', 't'));
   SET VARIABLE dv = (SELECT content FROM read_blob(getvariable('p')));
   COPY (SELECT getvariable('dv') || '\x00'::BLOB) TO (getvariable('p')) (FORMAT BLOB);
   SELECT sum(i) FROM t;"

run_case_err corrupt_deletion_vector_checksum "does not match computed checksum" \
  "CALL l.set_option('write_deletion_vectors', true);
   CREATE TABLE t AS SELECT range::INTEGER AS i FROM range(10);
   DELETE FROM t WHERE i = 0;
   SET VARIABLE p = (SELECT delete_file FROM ducklake_list_files('l', 't'));
   SET VARIABLE dv = (SELECT content FROM read_blob(getvariable('p')));
   COPY (SELECT getvariable('dv')[1:octet_length(getvariable('dv')) - 4] || '\x00\x00\x00\x00'::BLOB) TO (getvariable('p')) (FORMAT BLOB);
   SELECT sum(i) FROM t;"

run_case time_travel "3|5" \
  "CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (1),(2);
   SET VARIABLE s = (SELECT max(snapshot_id) FROM ducklake_snapshots('l'));
   INSERT INTO t VALUES (3);
   SELECT (SELECT sum(i) FROM t AT (VERSION => getvariable('s')))::VARCHAR || '|' || (SELECT count(*) + 2 FROM t)::VARCHAR;"

run_case update_and_view "a,20
b,2" \
  "CREATE TABLE t (k VARCHAR, v INTEGER); INSERT INTO t VALUES ('a',1),('b',2);
   UPDATE t SET v = 20 WHERE k = 'a'; CREATE VIEW vw AS SELECT * FROM t ORDER BY k; SELECT * FROM vw;"

run_case_err view_on_dropped_table "Error" \
  "CREATE TABLE t (i INTEGER); CREATE VIEW vw AS SELECT * FROM t; DROP TABLE t; SELECT * FROM vw;"

run_case add_data_files "3,6" \
  "CREATE TABLE t (i INTEGER);
   COPY (SELECT * FROM (VALUES (1),(2),(3)) v(i)) TO 'ext.parquet';
   CALL ducklake_add_data_files('l', 't', 'ext.parquet');
   SELECT count(*), sum(i) FROM t;"

run_case schema_evolution "1,NULL,x
2,5,y" \
  "CREATE TABLE t (i INTEGER); INSERT INTO t VALUES (1);
   ALTER TABLE t ADD COLUMN j INTEGER; ALTER TABLE t ADD COLUMN s VARCHAR DEFAULT 'x';
   INSERT INTO t VALUES (2, 5, 'y'); SELECT * FROM t ORDER BY i;"

# Upstream's own suite: every test/sql/**/*.test (the `.test_slow` files are upstream's hidden/slow
# set, excluded as upstream's `make test` does with "~[.]") through DuckDB's sqllogictest runner, one
# file per process, $MAYHEM_JOBS at a time, each with its own temp dir. A file passes only if the
# runner prints Catch's "All tests passed"; one that hits an unavailable `require` / `require-env`
# (postgres, sqlite, httpfs, quack, cloud, icu/tpch — not in this build), or is `mode skip` upstream,
# is counted as skipped.
UNITTEST="$SRC/unittest-ducklake"
[ -x "$UNITTEST" ] || { echo "missing $UNITTEST — run mayhem/build.sh" >&2; emit_ctrf duckdb-sqllogictest 0 1; exit 1; }
# The runner resolves paths from --test-dir; a few tests read DuckDB's own fixtures through the
# `duckdb/` submodule path (duckdb/data/parquet-testing/...), which the image doesn't check out, so
# the runner's root is a scratch dir linking this repo's top-level entries plus duckdb -> the pinned
# DuckDB source (the same tree build.sh compiled).
: "${DUCKDB_SRC:=/opt/toolchains/deps/duckdb-d54cbbe3df17e8e5ce68312f483b4155836112aa/src}"
SLT_ROOT="$WORK/slt/root"; mkdir -p "$SLT_ROOT"
for e in "$SRC"/*; do [ "$(basename "$e")" = duckdb ] || ln -s "$e" "$SLT_ROOT/"; done
ln -s "$DUCKDB_SRC" "$SLT_ROOT/duckdb"
find test/sql -name '*.test' | sort > "$WORK/slt/list"
run_slt() {
  local t="$1" key out rc
  key=$(printf '%s' "$t" | tr '/.' '__')
  out=$(timeout 900 "$UNITTEST" --test-dir "$SLT_ROOT" --emit-on-skip --temp-dir-root "$WORK/slt/tmp_$key" "$t" 2>&1); rc=$?
  rm -rf "$WORK/slt/tmp_$key"
  if [ $rc -eq 0 ] && { grep -q '^All tests were skipped' <<<"$out" ||
       { grep -q '^Skipped tests for the following reasons' <<<"$out" && grep -q '^assertions: - none -' <<<"$out"; }; }; then
    echo "SKIP $t"
  elif [ $rc -eq 0 ] && grep -q '^All tests passed' <<<"$out"; then
    echo "PASS $t"
  else
    echo "FAIL $t (rc=$rc)"; printf '%s\n' "$out" | tail -30 | sed 's/^/    /'
  fi
}
export -f run_slt; export UNITTEST WORK SRC SLT_ROOT
xargs -a "$WORK/slt/list" -P "$MAYHEM_JOBS" -I{} bash -c 'run_slt "$1"' _ {} > "$WORK/slt/out" 2>&1
grep '^FAIL' -A30 "$WORK/slt/out" | head -400
slt_pass=$(grep -c '^PASS ' "$WORK/slt/out"); slt_fail=$(grep -c '^FAIL ' "$WORK/slt/out"); slt_skip=$(grep -c '^SKIP ' "$WORK/slt/out")
echo "sqllogictest: $slt_pass passed, $slt_fail failed, $slt_skip skipped of $(wc -l < "$WORK/slt/list") files"

emit_ctrf duckdb-sqllogictest "$((passed + slt_pass))" "$((failed + slt_fail))" "$slt_skip"
