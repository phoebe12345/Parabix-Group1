#!/bin/bash
#
# Build Parabix in the container and exercise the ARM builders: once on NEON
# natively, once on SVE2 under emulation.
#
# Feature detection reads /proc/cpuinfo, which under user-mode QEMU reports the
# host CPU and not the emulated one. SVE2 is therefore invisible to detection
# here, so both the builder and the JIT feature list are set explicitly.
#
# Usage (from the repository root):
#   docker build -t parabix-sve2 QA/sve2
#   docker run --rm -v "$PWD:/src" parabix-sve2 ./QA/sve2/run_sve2.sh
#
set -euo pipefail

SRC=${SRC:-/src}
BUILD=${BUILD:-$SRC/build-linux}
JOBS=${JOBS:-$(nproc)}

QEMU_CPU=${QEMU_CPU:-max}
SVE2_MATTR=${SVE2_MATTR:-+sve2,+sve2-bitperm}

cd "$SRC"

echo "=== configure ==="
cmake -S . -B "$BUILD" \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm

echo "=== build idisa_test ==="
cmake --build "$BUILD" -j "$JOBS" --target idisa_test

IDISA="$BUILD/bin/idisa_test"
test -x "$IDISA" || { echo "idisa_test was not built"; exit 1; }

cd "$SRC/QA/IDISA_test"
if [ ! -f mask_sweep_a ] || [ ! -f mask_sweep_b ]; then
    echo "=== generating all-masks test data ==="
    python3 gen_mask_sweep.py
fi

# PARABIX_EXTRA_MATTR changes the emitted code but is absent from the cache key, so
# every run here disables the cache instead. Wiping the directory was the old fix; it
# kills any concurrent writer and forces a janitor fork onto the next run.
NOCACHE=-enable-object-cache=0

failures=0

# run_sweep <label> <ops> <data_a> <data_b> [env prefix ...]
run_sweep() {
    local label="$1"; shift
    local ops="$1"; shift
    local da="$1"; shift
    local db="$1"; shift
    echo
    echo "=== $label ==="
    for op in $ops; do
        for fw in 8 16 32 64; do
            # COMPACT has no encoding below 32-bit elements, so these two rows
            # run the NEON fallback. Saying PASS without saying that overstates
            # what the SVE2 sweep covers.
            local note=""
            case "$label:$op:$fw" in
                SVE2*:mvmd_compress:8|SVE2*:mvmd_compress:16)
                    note="  (NEON fallback, no SVE2 COMPACT at this width)" ;;
            esac
            if "$@" "$IDISA" $NOCACHE -q "$op" "$fw" "$da" "$db"; then
                echo "PASS  $label  $op fw=$fw$note"
            else
                echo "FAIL  $label  $op fw=$fw"
                failures=$((failures + 1))
            fi
        done
    done
}

SVE2_ENV=(env PARABIX_FORCE_BUILDER=ARM_SVE2 PARABIX_EXTRA_MATTR="$SVE2_MATTR"
          qemu-aarch64 -cpu "$QEMU_CPU")

# Native NEON. Detection works here, so nothing is forced.
run_sweep "NEON (native)" "mvmd_compress mvmd_expand" mask_sweep_a mask_sweep_b env
run_sweep "NEON (native)" "simd_pext simd_pdep" randhex65536a randhex65536b env

# SVE2 under emulation. Both overrides are required: the first selects the SVE2
# builder, the second tells the JIT the target may emit SVE2 instructions.
run_sweep "SVE2 (qemu -cpu $QEMU_CPU)" "mvmd_compress mvmd_expand" \
    mask_sweep_a mask_sweep_b "${SVE2_ENV[@]}"
run_sweep "SVE2 (qemu -cpu $QEMU_CPU)" "simd_pext simd_pdep" \
    randhex65536a randhex65536b "${SVE2_ENV[@]}"

# A passing SVE2 run is not on its own evidence that any SVE2 instruction ran:
# the builder name and the cache file name are set by selection, not by codegen.
# cortex-a72 implements no SVE at all, so the same binary must die on an illegal
# instruction. If it passes, BEXT never reached the CPU and the rows above are
# measuring the generic fallback.
echo
echo "=== negative control: same code on cortex-a72, which has no SVE ==="
set +e
env PARABIX_FORCE_BUILDER=ARM_SVE2 PARABIX_EXTRA_MATTR="$SVE2_MATTR" \
    qemu-aarch64 -cpu cortex-a72 "$IDISA" $NOCACHE -q simd_pext 32 \
    randhex65536a randhex65536b >/dev/null 2>&1
control_status=$?
set -e
if [ "$control_status" -eq 0 ]; then
    echo "UNEXPECTED PASS: no SVE instruction reached the CPU, so the SVE2 rows above prove nothing"
    failures=$((failures + 1))
else
    echo "EXPECTED FAILURE (status $control_status): a non-SVE CPU rejected the emitted code"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$failures FAILED"
fi
exit "$failures"
