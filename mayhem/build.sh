#!/usr/bin/env bash
#
# mayhem/build.sh — build arrow's six upstream fuzz targets (sanitized, libFuzzer + standalone
# reproducer each) and the unit-test binaries test.sh runs. Runs in the commit image as `mayhem`
# in /mayhem; re-runnable, and air-gapped (apt -dev packages + the tarballs fetch-deps.sh cached).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
CPP="$SRC/cpp"
FUZZ_BUILD="$CPP/fuzz-build"
TEST_BUILD="$CPP/test-build"

# arrow's bundled-xsimd step fails to RE-configure over an existing tree (imported target clash), so
# every run starts from fresh build dirs.
rm -rf "$FUZZ_BUILD" "$TEST_BUILD"

# Dependencies arrow's cmake would download in BUNDLED mode, pre-fetched by mayhem/fetch-deps.sh.
DEPS=/opt/toolchains/arrow-deps
export ARROW_SIMDJSON_URL="file://$(ls "$DEPS"/simdjson-*.tar.gz)"
export ARROW_XSIMD_URL="file://$(ls "$DEPS"/xsimd-*.tar.gz)"

COMMON_CMAKE=(
  -GNinja -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DARROW_DEPENDENCY_SOURCE=SYSTEM -Dsimdjson_SOURCE=BUNDLED -Dxsimd_SOURCE=BUNDLED
  -DARROW_BUILD_SHARED=OFF -DARROW_BUILD_STATIC=ON
  -DARROW_PARQUET=ON -DARROW_CSV=ON -DARROW_FILESYSTEM=OFF -DARROW_JEMALLOC=OFF -DARROW_MIMALLOC=OFF
  -DARROW_WITH_BROTLI=ON -DARROW_WITH_LZ4=ON -DARROW_WITH_ZSTD=ON -DARROW_WITH_SNAPPY=ON
  -DARROW_WITH_ZLIB=ON -DARROW_WITH_BZ2=OFF
  -DARROW_USE_GLOG=OFF -DPARQUET_REQUIRE_ENCRYPTION=ON
  -DARROW_BUILD_BENCHMARKS=OFF -DARROW_BUILD_EXAMPLES=OFF -DARROW_BUILD_UTILITIES=OFF
)

# 1) Sanitized fuzz build. Alignment checks are relaxed exactly as upstream's own UBSan config does
#    (cpp/cmake_modules/san-config.cmake): arrow deliberately does unaligned loads on IPC/Parquet
#    buffers; everything else in ASan+UBSan stays on and halting.
UB_RELAX=""
case "$SANITIZER_FLAGS" in *undefined*) UB_RELAX="-fno-sanitize=alignment" ;; esac
FUZZ_FLAGS="$SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS"

cmake -S "$CPP" -B "$FUZZ_BUILD" "${COMMON_CMAKE[@]}" \
  -DARROW_BUILD_TESTS=OFF -DARROW_FUZZING=ON \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS"

# 2) Fuzz + standalone binaries. Re-link cmake's own link line for each target so every library
#    and flag upstream picked is kept: once into the libFuzzer binary (+ the LSan-off hook),
#    once against the run-once driver.
$CC $FUZZ_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
$CXX $FUZZ_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"

TARGETS=(arrow-ipc-stream-fuzz arrow-ipc-file-fuzz arrow-ipc-tensor-stream-fuzz arrow-csv-fuzz
         parquet-arrow-fuzz parquet-encoding-fuzz)
for t in "${TARGETS[@]}"; do
  link="$(ninja -C "$FUZZ_BUILD" -t commands "release/$t" | tail -1)"
  link="${link#: && }"; link="${link% && :}"
  [[ "$link" == *" -o release/$t "* && "$link" == *" $LIB_FUZZING_ENGINE "* ]] \
    || { echo "unexpected link line for $t: $link" >&2; exit 1; }
  fuzz="${link/ -o release\/$t / -o $SRC/$t }"
  (cd "$FUZZ_BUILD" && eval "$fuzz $FUZZ_BUILD/lsan_off.o")
  standalone="${link/ -o release\/$t / -o $SRC/$t-standalone }"
  standalone="${standalone/ $LIB_FUZZING_ENGINE / $FUZZ_BUILD/standalone_main.o }"
  (cd "$FUZZ_BUILD" && eval "$standalone $FUZZ_BUILD/lsan_off.o")
done

# 3) Upstream unit tests, NORMAL flags, in a separate tree, for test.sh.
cmake -S "$CPP" -B "$TEST_BUILD" "${COMMON_CMAKE[@]}" -DARROW_BUILD_TESTS=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target \
  arrow-csv-test arrow-ipc-read-write-test parquet-encoding-test parquet-file-deserialize-test
