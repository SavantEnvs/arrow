#!/usr/bin/env bash
#
# mayhem/test.sh — RUN arrow's own gtest suites for the fuzzed code paths (CSV reader/writer, IPC
# read/write, Parquet encodings, Parquet file/page deserialization), built by mayhem/build.sh.
# Asserted values come from gtest; a binary that exits without printing a gtest summary counts as a
# failure, so a neutered/no-op program cannot pass.
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

BIN="$SRC/cpp/test-build/release"
# This test needs the arrow-testing git submodule (ARROW_TEST_DATA), which is not in the image.
IPC_FILTER='-TestSchemaMetadata.MetadataVersionForwardCompatibility'
SUITES=(
  "arrow-csv-test:*"
  "arrow-ipc-read-write-test:$IPC_FILTER"
  "parquet-encoding-test:*"
  "parquet-file-deserialize-test:*"
)

passed=0; failed=0; skipped=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for s in "${SUITES[@]}"; do
  name="${s%%:*}"; filter="${s#*:}"
  exe="$BIN/$name"
  if [ ! -x "$exe" ]; then
    echo "missing test runner $exe (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1)); continue
  fi
  out="$work/$name.out"
  (cd "$work" && "$exe" --gtest_filter="$filter") > "$out" 2>&1
  rc=$?
  tail -n 6 "$out"
  ran="$(sed -n 's/^\[==========\] \([0-9]*\) tests\? from .* ran\..*/\1/p' "$out" | tail -1)"
  p="$(sed -n 's/^\[  PASSED  \] \([0-9]*\) tests\?\./\1/p' "$out" | tail -1)"
  f="$(sed -n 's/^\[  FAILED  \] \([0-9]*\) tests\?, listed below:/\1/p' "$out" | tail -1)"
  sk="$(sed -n 's/^\[  SKIPPED \] \([0-9]*\) tests\?, listed below:/\1/p' "$out" | tail -1)"
  if [ -z "$ran" ] || [ "$ran" -eq 0 ]; then
    echo "$name: no gtest summary (rc=$rc) — counting as a failure" >&2
    failed=$((failed + 1)); continue
  fi
  passed=$((passed + ${p:-0})); failed=$((failed + ${f:-0})); skipped=$((skipped + ${sk:-0}))
  if [ "$rc" -ne 0 ] && [ "${f:-0}" -eq 0 ]; then failed=$((failed + 1)); fi
done

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
