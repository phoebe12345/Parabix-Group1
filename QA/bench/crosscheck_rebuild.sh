#!/usr/bin/env bash
#
# R1: rebuild the fw=2 generic path and compare it with the runtime-switch result.
# Both trees use the same LLVM configuration and distinct cache prefixes.
#
# Usage: crosscheck_rebuild.sh --switch-summary PATH/summary.json [--pairs 31]
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SWITCH_SUMMARY=""
PAIRS=31
WARMUP=5
OP=simd_sllv
FW=2
SMOKE=0
XBUILD="$REPO/build-crosscheck"

while [ $# -gt 0 ]; do
    case "$1" in
        --switch-summary) SWITCH_SUMMARY="$2"; shift ;;
        --pairs) PAIRS="$2"; shift ;;
        --warmup) WARMUP="$2"; shift ;;
        --op) OP="$2"; shift ;;
        --smoke) SMOKE=1; PAIRS=3; WARMUP=1 ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done
[ -n "$SWITCH_SUMMARY" ] || die "--switch-summary is required"
[ -f "$SWITCH_SUMMARY" ] || die "missing $SWITCH_SUMMARY"

if [ "$SMOKE" -eq 1 ]; then
    OPA="$REPO/QA/IDISA_test/randhex65536a"
    OPB="$REPO/QA/IDISA_test/randhex65536b"
else
    OPA="$CORPUS/hex64a"
    OPB="$CORPUS/hex64b"
fi
[ -f "$OPA" ] || die "missing $OPA"

# Rebuilding and benchmarking share the same lock.
LOCK="$BUILD/.bench.lock"
mkdir "$LOCK" 2>/dev/null || die "build lock $LOCK exists; a bench session is running"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

KERNEL="${OP}${FW}_test"
SESSION="$RESULTS/$(utc_stamp)_crosscheck_${OP}"
mkdir -p "$SESSION/stderr" "$SESSION/stdout"
note "session $SESSION"

# Copy the working tree so the source edit cannot alter the primary build.
XSRC="$SESSION/src"
mkdir -p "$XSRC"
note "copying the tree to $XSRC"
git -C "$REPO" ls-files -z | tar -C "$REPO" -cf - --null -T - | tar -C "$XSRC" -xf -

# Disable the fw=2 override in the copied tree.
python3 - "$XSRC/lib/idisa/idisa_arm_builder.cpp" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
before = s
s = s.replace(
    "if (!hasFeature(Feature::BENCH_GENERIC_SHIFT2) && getVectorBitWidth(v) == ARM_width && fw == 2) {",
    "if (false) {")
if s == before:
    sys.exit("crosscheck: the fw=2 guards were not found; the source moved, fix this script")
open(p, "w").write(s)
print("crosscheck: fw=2 simd_sllv and simd_srlv overrides disabled at source")
PY

# Reuse the primary tree's CMake settings to prevent toolchain drift.
read_cache_var() {
    local name="$1"
    awk -F= -v n="$name" '$0 ~ ("^" n ":") { sub(/^[^=]*=/, ""); print; exit }' "$BUILD/CMakeCache.txt"
}
[ -f "$BUILD/CMakeCache.txt" ] || die "missing $BUILD/CMakeCache.txt; configure the primary tree first"
CFG_ARGS=()
for v in CMAKE_BUILD_TYPE CMAKE_PREFIX_PATH LLVM_DIR CMAKE_C_COMPILER CMAKE_CXX_COMPILER Z3_DIR; do
    val="$(read_cache_var "$v" || true)"
    [ -n "$val" ] || continue
    CFG_ARGS+=("-D${v}=${val}")
    note "inherited $v=$val"
done
[ "${#CFG_ARGS[@]}" -gt 0 ] || die "read no cache entries out of $BUILD/CMakeCache.txt"

note "configuring $XBUILD"
cmake -S "$XSRC" -B "$XBUILD" "${CFG_ARGS[@]}" >"$SESSION/cmake.log" 2>&1 \
    || { tail -40 "$SESSION/cmake.log" >&2; die "cmake configure failed"; }

# Read the LLVM version from the llvm-config beside each resolved LLVM_DIR.
llvm_version_of() {
    local dir cfg
    dir="$(awk -F= '/^LLVM_DIR:/ { sub(/^[^=]*=/, ""); print; exit }' "$1/CMakeCache.txt")"
    [ -n "$dir" ] || return 1
    cfg="${dir%/lib/cmake/llvm}/bin/llvm-config"
    [ -x "$cfg" ] || return 1
    printf '%s %s\n' "$("$cfg" --version)" "$dir"
}
V_MAIN="$(llvm_version_of "$BUILD" || true)"
V_X="$(llvm_version_of "$XBUILD" || true)"
note "LLVM in the primary tree: ${V_MAIN:-unknown}"
note "LLVM in the crosscheck tree: ${V_X:-unknown}"
[ -n "$V_MAIN" ] && [ -n "$V_X" ] || die "could not resolve llvm-config from LLVM_DIR in both trees"
[ "$V_MAIN" = "$V_X" ] \
    || die "LLVM differs between the trees ($V_MAIN vs $V_X); the comparison would charge a compiler change to the source edit"

note "building idisa_test in $XBUILD"
cmake --build "$XBUILD" -j8 --target idisa_test >"$SESSION/build.log" 2>&1 \
    || { tail -40 "$SESSION/build.log" >&2; die "build failed"; }

XBIN="$XBUILD/bin/idisa_test"
[ -x "$XBIN" ] || die "missing $XBIN"

COMMON=(-EnableCycleCounter -thread-num=1 -trace-object-cache -q)
CSV="$SESSION/samples.csv"
echo "pair,arm,ns,items,status,pct" > "$CSV"

sample() {
    local bin="$1" tag="$2"
    local out="$SESSION/stdout/$tag" err="$SESSION/stderr/$tag"
    run_one "$out" "$err" "$bin" "${COMMON[@]}" "$OP" "$FW" "$OPA" "$OPB"
    SAMPLE_NS=""; SAMPLE_ITEMS=""; SAMPLE_PCT=""
    [ "$RUN_STATUS" -eq 0 ] || return 0
    # The trace distinguishes the ARM builder from the scalar fallback.
    assert_trace "$err" ARM "$KERNEL"
    local row
    row="$(parse_counter_row "$err" "$KERNEL")"
    SAMPLE_ITEMS="$(printf '%s' "$row" | awk '{print $1}')"
    SAMPLE_NS="$(printf '%s' "$row" | awk '{print $2}')"
    SAMPLE_PCT="$(printf '%s' "$row" | awk '{print $3}')"
    return 0
}

# Resolve each binary's cache prefix from entries touched after the marker.
MARKER="$SESSION/.marker"
: > "$MARKER"
sleep 1
sample "$BIN/idisa_test" prefix_probe_A
[ "$RUN_STATUS" -eq 0 ] || die "primary binary exited $RUN_STATUS during the prefix probe"
PREFIX_A="$(resolve_prefix_by_touch "$MARKER" "$KERNEL" ARM)" \
    || die "could not resolve the cache prefix used by $BIN/idisa_test"

: > "$MARKER"
sleep 1
sample "$XBIN" prefix_probe_B
[ "$RUN_STATUS" -eq 0 ] || die "crosscheck binary exited $RUN_STATUS during the prefix probe"
PREFIX_B="$(resolve_prefix_by_touch "$MARKER" "$KERNEL" ARM)" \
    || die "could not resolve the cache prefix used by $XBIN"

[ "$PREFIX_A" != "$PREFIX_B" ] \
    || die "both binaries use cache prefix $PREFIX_A, so they read each other's kernels and there is no second arm"

OBJ_A="$(kernel_object_path "$PREFIX_A" "$KERNEL" ARM)"
OBJ_B="$(kernel_object_path "$PREFIX_B" "$KERNEL" ARM)"
MD5_A="$(md5 -q "$OBJ_A")"; MD5_B="$(md5 -q "$OBJ_B")"
EOR_A="$(count_mnemonic "$OBJ_A" "_${KERNEL}_DoSegment" eor.16b)"
EOR_B="$(count_mnemonic "$OBJ_B" "_${KERNEL}_DoSegment" eor.16b)"
VEC_A="$(count_vector_insns "$OBJ_A" "_${KERNEL}_DoSegment")"
VEC_B="$(count_vector_insns "$OBJ_B" "_${KERNEL}_DoSegment")"

PATH_PROOF=pass
MD5_DISTINCT=yes
[ "$MD5_A" != "$MD5_B" ] || { MD5_DISTINCT=no; PATH_PROOF=fail; note "the two binaries produced the identical kernel object"; }
# The rebuilt path must contain the generic eor.16b discriminator.
[ "$EOR_A" -eq 0 ] || { PATH_PROOF=fail; note "the primary binary emitted $EOR_A eor.16b; it is not on the native path"; }
[ "$EOR_B" -gt 0 ] || { PATH_PROOF=fail; note "the rebuilt binary emitted no eor.16b; the source edit did not take"; }

{
    echo "primary  prefix $PREFIX_A"
    echo "  object $OBJ_A"
    echo "  md5 $MD5_A  vector insns $VEC_A  eor.16b $EOR_A"
    echo "rebuilt  prefix $PREFIX_B"
    echo "  object $OBJ_B"
    echo "  md5 $MD5_B  vector insns $VEC_B  eor.16b $EOR_B"
    echo "llvm $V_MAIN in both trees"
    echo "path_proof $PATH_PROOF  md5_distinct $MD5_DISTINCT"
} > "$SESSION/path_proof.txt"
cat "$SESSION/path_proof.txt" >&2

PREFIXES_BEFORE="$SESSION/prefixes.before"
snapshot_prefixes > "$PREFIXES_BEFORE"

for i in $(seq 1 "$WARMUP"); do
    sample "$BIN/idisa_test" "warmup_${i}_A"; [ "$RUN_STATUS" -eq 0 ] || die "warmup A exited $RUN_STATUS"
    sample "$XBIN"           "warmup_${i}_B"; [ "$RUN_STATUS" -eq 0 ] || die "warmup B exited $RUN_STATUS"
done

n_attempted=0; n_signal=0
for i in $(seq 1 "$PAIRS"); do
    if [ $((i % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
    st_A=""; st_B=""; ns_A=""; ns_B=""; it_A=""; it_B=""; pc_A=""; pc_B=""
    for arm in $ORDER; do
        n_attempted=$((n_attempted + 1))
        if [ "$arm" = "A" ]; then
            sample "$BIN/idisa_test" "pair${i}_A"
            st_A="$RUN_STATUS"; ns_A="${SAMPLE_NS:-}"; it_A="${SAMPLE_ITEMS:-}"; pc_A="${SAMPLE_PCT:-}"
        else
            sample "$XBIN" "pair${i}_B"
            st_B="$RUN_STATUS"; ns_B="${SAMPLE_NS:-}"; it_B="${SAMPLE_ITEMS:-}"; pc_B="${SAMPLE_PCT:-}"
        fi
        case "$(classify_status "$RUN_STATUS")" in
            ok) ;;
            signal) n_signal=$((n_signal + 1)) ;;
            wrong_answer) die "pair $i arm $arm: idisa_test reported a wrong answer. Session aborted." ;;
            harness_error) die "pair $i arm $arm: unexpected status $RUN_STATUS" ;;
        esac
    done
    if [ "$st_A" -ne 0 ] || [ "$st_B" -ne 0 ]; then
        note "pair $i discarded: A=$st_A B=$st_B"
        continue
    fi
    printf '%s,A,%s,%s,0,%s\n' "$i" "$ns_A" "$it_A" "$pc_A" >> "$CSV"
    printf '%s,B,%s,%s,0,%s\n' "$i" "$ns_B" "$it_B" "$pc_B" >> "$CSV"
done

if [ "$n_attempted" -gt 0 ]; then
    over="$(awk -v s="$n_signal" -v a="$n_attempted" 'BEGIN { print (s / a > 0.02) ? 1 : 0 }')"
    [ "$over" -eq 0 ] || die "signal death rate $n_signal/$n_attempted exceeds 0.02; session aborted"
fi

SESSION_VOID=no
if ! diff -q <(snapshot_prefixes) "$PREFIXES_BEFORE" >/dev/null 2>&1; then
    SESSION_VOID=yes; note "VOID: the cache prefix set changed mid-session"
fi
if [ "$(md5 -q "$OBJ_A")" != "$MD5_A" ] || [ "$(md5 -q "$OBJ_B")" != "$MD5_B" ]; then
    SESSION_VOID=yes; note "VOID: a timed kernel object changed mid-session"
fi

python3 "$BENCH/stats.py" "$CSV" --label "crosscheck_rebuild_${OP}${FW}" --kernel "$KERNEL" \
    --out "$SESSION/summary.json" --scope kernel \
    --quantity "nanoseconds inside ${KERNEL} DoSegment, arms are two separately built binaries" \
    --switch "source edit: the fw=2 override deleted in the second tree" \
    --n-signal "$n_signal" --n-attempted "$n_attempted" \
    --path-proof "$PATH_PROOF" --md5-distinct "$MD5_DISTINCT" --session-void "$SESSION_VOID" \
    --expect-floor-signature two-separately-built-binaries \
    --floor-signature two-separately-built-binaries \
    | tee "$SESSION/report.txt"
# The rebuild has no independent floor, so compare bootstrap intervals only.
python3 - "$SWITCH_SUMMARY" "$SESSION/summary.json" "$PATH_PROOF" "$MD5_DISTINCT" "$SESSION_VOID" <<'PY'
import json, sys
sw = json.load(open(sys.argv[1]))["paired_ratio_B_over_A"]
rb = json.load(open(sys.argv[2]))["paired_ratio_B_over_A"]
path_proof, md5_distinct, void = sys.argv[3], sys.argv[4], sys.argv[5]
print("")
print("R1 cross-check")
print("  runtime-switch ratio : %.5f  CI [%.5f, %.5f]" % (sw["median"], sw["ci95_low"], sw["ci95_high"]))
print("  rebuild ratio        : %.5f  CI [%.5f, %.5f]" % (rb["median"], rb["ci95_low"], rb["ci95_high"]))
print("  path proof           : %s" % path_proof)
print("  kernels distinct     : %s" % md5_distinct)
print("  session void         : %s" % void)
if path_proof != "pass" or md5_distinct != "yes" or void != "no":
    print("  INVALID. The cross-check proved nothing; it says nothing about D1 either way.")
    sys.exit(1)
overlap = not (sw["ci95_high"] < rb["ci95_low"] or rb["ci95_high"] < sw["ci95_low"])
if overlap:
    print("  AGREE: the two 95%% intervals overlap. D1 stands.")
else:
    print("  DISAGREE: the two 95%% intervals are disjoint. D1 is VOID.")
    sys.exit(1)
PY
note "session directory: $SESSION"
