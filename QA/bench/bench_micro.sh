#!/usr/bin/env bash
#
# D1: paired, interleaved A/B on one idisa_test counter row.
#
# Arm A is the native path. Arm B adds one -bench-generic-* switch, which folds into
# the builder unique name, so the two arms read separate object cache entries and
# cannot serve each other stale kernels. The cache stays on and warm in both arms;
# the per-kernel counter brackets DoSegment and never sees JIT time.
#
# The switches are global to the builder, so a switch can also change the PIPELINE
# DRIVER module. That module brackets llvm.readcyclecounter and contributes to the row
# this script reports. The session therefore proves the pipeline object as well as the
# kernel object, records whether the two arms' pipeline objects differ, and refuses to
# accept a noise floor whose arms do not differ in the same structural way.
#
# --null measures the noise floor. Arm B is a bench bit that leaves the timed kernel
# byte-identical and reproduces the measured configuration's pipeline signature, so the
# floor contains the cost of the arms being two separately compiled objects and, where
# the measurement has one, the pipeline-image term. The bit is discovered, not assumed.
#
# Usage:
#   bench_micro.sh --op simd_sllv --fw 2 --bit shift2 [--pairs 31] [--w-null-file F]
#   bench_micro.sh --null --op simd_sllv --fw 2 --bit shift2
#   bench_micro.sh --smoke --op simd_sllv --fw 2 --bit shift2
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OP=simd_sllv
FW=2
BIT=shift2
NULL=0
PAIRS=31
WARMUP=5
SMOKE=0
SESSION=""
OPA=""
OPB=""
W_NULL_FILE=""
W_NULL_KEY=counter
DO_PREFLIGHT=1
LABEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --op) OP="$2"; shift ;;
        --fw) FW="$2"; shift ;;
        --bit) BIT="$2"; shift ;;
        --null) NULL=1 ;;
        --pairs) PAIRS="$2"; shift ;;
        --warmup) WARMUP="$2"; shift ;;
        --smoke) SMOKE=1 ;;
        --session) SESSION="$2"; shift ;;
        --operand-a) OPA="$2"; shift ;;
        --operand-b) OPB="$2"; shift ;;
        --w-null-file) W_NULL_FILE="$2"; shift ;;
        --w-null-key) W_NULL_KEY="$2"; shift ;;
        --label) LABEL="$2"; shift ;;
        --no-preflight) DO_PREFLIGHT=0 ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done

if [ "$SMOKE" -eq 1 ]; then
    PAIRS=3
    WARMUP=1
    [ -n "$OPA" ] || OPA="$REPO/QA/IDISA_test/randhex65536a"
    [ -n "$OPB" ] || OPB="$REPO/QA/IDISA_test/randhex65536b"
fi
[ -n "$OPA" ] || OPA="$CORPUS/hex64a"
[ -n "$OPB" ] || OPB="$CORPUS/hex64b"
[ -f "$OPA" ] || die "missing operand file $OPA (run make_corpus.sh)"
[ -f "$OPB" ] || die "missing operand file $OPB (run make_corpus.sh)"

FLAG="$(bench_bit_flag "$BIT")"
SUFFIX="$(bench_bit_suffix "$BIT")"
ARM_A=ARM
ARM_EXP="ARM${SUFFIX}"
KERNEL="${OP}${FW}_test"

INPUT_TAG="$(sha256_of "$OPA" | cut -c1-8)+$(sha256_of "$OPB" | cut -c1-8)"
FLOOR_LABEL="bench_micro.sh:${W_NULL_KEY}:${KERNEL}:${INPUT_TAG}"

if [ "$NULL" -eq 1 ]; then
    [ -n "$LABEL" ] || LABEL="null_${OP}${FW}_${BIT}"
else
    [ -n "$LABEL" ] || LABEL="${OP}${FW}_${BIT}"
fi

if [ -z "$SESSION" ]; then
    SESSION="$RESULTS/$(utc_stamp)_${LABEL}"
fi
mkdir -p "$SESSION/stderr" "$SESSION/stdout"

if [ "$DO_PREFLIGHT" -eq 1 ]; then
    PRE_ARGS=("$SESSION")
    [ "$SMOKE" -eq 0 ] || PRE_ARGS+=(--smoke)
    bash "$BENCH/preflight.sh" "${PRE_ARGS[@]}"
    trap 'rmdir "$BUILD/.bench.lock" 2>/dev/null || true' EXIT
fi

COMMON=(-EnableCycleCounter -thread-num=1 -trace-object-cache -q)

# probe_objects TAG ARMNAME [flags ...]
# Warms one arm and reads back the md5 of the timed kernel object and of the pipeline
# driver object that arm used. Sets PROBE_OK PROBE_KMD5 PROBE_PMD5 PROBE_PIPE.
probe_objects() {
    local tag="$1" armname="$2"; shift 2
    local out="$SESSION/stdout/probe_$tag" err="$SESSION/stderr/probe_$tag"
    PROBE_OK=0; PROBE_KMD5=""; PROBE_PMD5=""; PROBE_PIPE=""
    run_one "$out" "$err" "$BIN/idisa_test" "${COMMON[@]}" "$@" "$OP" "$FW" "$OPA" "$OPB"
    [ "$RUN_STATUS" -eq 0 ] || return 0
    assert_trace "$err" "$armname" "$KERNEL"
    local prefix kobj pobj
    prefix="$(newest_prefix)"
    PROBE_PIPE="$(pipeline_module_base "$err")"
    [ -n "$PROBE_PIPE" ] || die "no pipeline driver module in the trace for $tag"
    kobj="$(kernel_object_path "$prefix" "$KERNEL" "$armname")"
    pobj="$(kernel_object_path "$prefix" "$PROBE_PIPE" "$armname")"
    [ -f "$kobj" ] || die "kernel object absent for $tag: $kobj"
    [ -f "$pobj" ] || die "pipeline object absent for $tag: $pobj"
    PROBE_KMD5="$(md5 -q "$kobj")"
    PROBE_PMD5="$(md5 -q "$pobj")"
    PROBE_OK=1
}

note "label=$LABEL kernel=$KERNEL pairs=$PAIRS warmup=$WARMUP"
note "operands: $OPA $OPB"

probe_objects arm_a "$ARM_A"
[ "$PROBE_OK" -eq 1 ] || die "arm A failed during the structural probe"
KMD5_A="$PROBE_KMD5"; PMD5_A="$PROBE_PMD5"; PIPE_BASE="$PROBE_PIPE"

probe_objects "arm_$BIT" "$ARM_EXP" "$FLAG"
[ "$PROBE_OK" -eq 1 ] || die "arm B ($FLAG) failed during the structural probe"
KMD5_EXP="$PROBE_KMD5"; PMD5_EXP="$PROBE_PMD5"

[ "$KMD5_A" != "$KMD5_EXP" ] \
    || die "$FLAG changed no byte of $KERNEL; there is nothing to measure"

if [ "$PMD5_A" = "$PMD5_EXP" ]; then
    PIPE_SIG="pipeline-identical"
else
    PIPE_SIG="pipeline-distinct"
fi
EXPECT_SIGNATURE="separate-cache-entries,${PIPE_SIG}"
note "measured arms differ as: $EXPECT_SIGNATURE"

# ---- arm B selection ----
if [ "$NULL" -eq 1 ]; then
    # A null arm must leave the timed kernel byte-identical and must reproduce the
    # measured configuration's pipeline signature. Otherwise the floor either omits the
    # pipeline-image term the measurement contains, or contains one the measurement does
    # not, and in both directions it is the wrong floor.
    NULL_BIT=""
    for cand in $ALL_BENCH_BITS; do
        [ "$cand" != "$BIT" ] || continue
        cflag="$(bench_bit_flag "$cand")"
        csuf="$(bench_bit_suffix "$cand")"
        probe_objects "null_$cand" "ARM${csuf}" "$cflag"
        [ "$PROBE_OK" -eq 1 ] || { note "null candidate $cand: run failed, skipped"; continue; }
        [ "$PROBE_KMD5" = "$KMD5_A" ] || { note "null candidate $cand: changes $KERNEL, rejected"; continue; }
        if [ "$PROBE_PMD5" = "$PMD5_A" ]; then csig="pipeline-identical"; else csig="pipeline-distinct"; fi
        if [ "$csig" = "$PIPE_SIG" ]; then
            NULL_BIT="$cand"
            note "null arm B = $cflag (kernel byte-identical, $csig)"
            break
        fi
        note "null candidate $cand: $csig, does not match $PIPE_SIG, rejected"
    done
    if [ -n "$NULL_BIT" ]; then
        FLAG_B=("$(bench_bit_flag "$NULL_BIT")")
        ARM_B="ARM$(bench_bit_suffix "$NULL_BIT")"
        FLOOR_SIGNATURE="$EXPECT_SIGNATURE"
    else
        # No bit reproduces the structure. Fall back to the identical command line, and
        # record that the floor is missing the layout term so S7 fails downstream.
        FLAG_B=()
        ARM_B="$ARM_A"
        FLOOR_SIGNATURE="same-command-line,pipeline-identical"
        note "no bench bit reproduces the measured structure; the floor omits the layout term"
    fi
    MD5_MUST_DIFFER=no
else
    FLAG_B=("$FLAG")
    ARM_B="$ARM_EXP"
    FLOOR_SIGNATURE=""
    MD5_MUST_DIFFER=yes
fi

note "armA=$ARM_A armB=$ARM_B"

# ---- floor, if one was supplied ----
W_NULL=""; W_NULL_CI=""; W_NULL_LABEL=""; W_NULL_SIG=""
if [ -n "$W_NULL_FILE" ]; then
    [ -f "$W_NULL_FILE" ] || die "missing floor file $W_NULL_FILE"
    FLOOR_LINE="$(python3 - "$W_NULL_FILE" "$W_NULL_KEY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
k = sys.argv[2]
if k not in d:
    sys.exit("floor file has no '%s' entry; it holds %s" % (k, sorted(d)))
e = d[k]
print("%.6f %.6f %s %s" % (e["floor_spread"], e["floor_ci"], e["label"], e["signature"]))
PY
)"
    read -r W_NULL W_NULL_CI W_NULL_LABEL W_NULL_SIG <<<"$FLOOR_LINE"
    note "floor $W_NULL from $W_NULL_LABEL ($W_NULL_SIG)"
fi

# one_run ARM_LABEL TAG -> sets SAMPLE_NS SAMPLE_ITEMS SAMPLE_PCT RUN_STATUS
one_run() {
    local arm="$1" tag="$2"
    local out="$SESSION/stdout/$tag" err="$SESSION/stderr/$tag"
    local flags=()
    [ "$arm" = "B" ] && flags=("${FLAG_B[@]+"${FLAG_B[@]}"}")
    run_one "$out" "$err" "$BIN/idisa_test" "${COMMON[@]}" "${flags[@]+"${flags[@]}"}" "$OP" "$FW" "$OPA" "$OPB"
    SAMPLE_NS=""; SAMPLE_ITEMS=""; SAMPLE_PCT=""
    [ "$RUN_STATUS" -eq 0 ] || return 0
    local armname="$ARM_A"
    [ "$arm" = "B" ] && armname="$ARM_B"
    assert_trace "$err" "$armname" "$KERNEL"
    local row
    row="$(parse_counter_row "$err" "$KERNEL")"
    SAMPLE_ITEMS="$(printf '%s' "$row" | awk '{print $1}')"
    SAMPLE_NS="$(printf '%s' "$row" | awk '{print $2}')"
    SAMPLE_PCT="$(printf '%s' "$row" | awk '{print $3}')"
    return 0
}

# Warmup fills each arm's own cache namespace. Discarded, never recorded.
for i in $(seq 1 "$WARMUP"); do
    one_run A "warmup_${i}_A"
    [ "$RUN_STATUS" -eq 0 ] || die "warmup arm A exited $RUN_STATUS"
    one_run B "warmup_${i}_B"
    [ "$RUN_STATUS" -eq 0 ] || die "warmup arm B exited $RUN_STATUS"
done

PREFIX="$(newest_prefix)"
OBJ_A="$(kernel_object_path "$PREFIX" "$KERNEL" "$ARM_A")"
OBJ_B="$(kernel_object_path "$PREFIX" "$KERNEL" "$ARM_B")"
PIPE_A="$(kernel_object_path "$PREFIX" "$PIPE_BASE" "$ARM_A")"
PIPE_B="$(kernel_object_path "$PREFIX" "$PIPE_BASE" "$ARM_B")"
for f in "$OBJ_A" "$OBJ_B" "$PIPE_A" "$PIPE_B"; do
    [ -f "$f" ] || die "object absent after warmup: $f"
done
MD5_A="$(md5 -q "$OBJ_A")"
MD5_B="$(md5 -q "$OBJ_B")"
PMD5_RUN_A="$(md5 -q "$PIPE_A")"
PMD5_RUN_B="$(md5 -q "$PIPE_B")"

if [ "$MD5_MUST_DIFFER" = yes ]; then
    [ "$MD5_A" != "$MD5_B" ] \
        || die "arms share md5 $MD5_A; the switch changed no emitted code, so there is nothing to measure"
    MD5_DISTINCT=yes
else
    [ "$MD5_A" = "$MD5_B" ] || die "null run: arm B changed the timed kernel, so it is not a null"
    MD5_DISTINCT=yes
    [ "$ARM_A" != "$ARM_B" ] || MD5_DISTINCT=no
fi

if [ "$PMD5_RUN_A" = "$PMD5_RUN_B" ]; then RUN_PIPE_SIG="pipeline-identical"; else RUN_PIPE_SIG="pipeline-distinct"; fi

# Layer 2 path proof on the warm objects that the timing loop will read. The pipeline
# driver object is proved here too, because a difference there is charged to the
# operation by every counter row in the table.
{
    echo "prefix        $PREFIX"
    echo "kernel        $KERNEL"
    echo "arm A         $OBJ_A"
    echo "  md5         $MD5_A"
    echo "  vector/scalar insns $(count_insns "$OBJ_A" "_${KERNEL}_DoSegment")"
    echo "  eor.16b     $(count_mnemonic "$OBJ_A" "_${KERNEL}_DoSegment" eor.16b)"
    echo "arm B         $OBJ_B"
    echo "  md5         $MD5_B"
    echo "  vector/scalar insns $(count_insns "$OBJ_B" "_${KERNEL}_DoSegment")"
    echo "  eor.16b     $(count_mnemonic "$OBJ_B" "_${KERNEL}_DoSegment" eor.16b)"
    echo "pipeline      $PIPE_BASE"
    echo "  arm A md5   $PMD5_RUN_A"
    echo "  arm B md5   $PMD5_RUN_B"
    echo "  signature   $RUN_PIPE_SIG"
    if [ "$RUN_PIPE_SIG" = "pipeline-distinct" ]; then
        echo "  NOTE: the switch is not scoped to the kernel. The pipeline driver image"
        echo "  differs between the arms, so part of any measured difference belongs to it."
        echo "  The noise floor for this configuration must be measured with an arm B that"
        echo "  reproduces this same pipeline difference. S7 enforces that."
    fi
} > "$SESSION/path_proof.txt"
cat "$SESSION/path_proof.txt" >&2

CSV="$SESSION/samples.csv"
echo "pair,arm,ns,items,status,pct" > "$CSV"

n_attempted=0
n_signal=0
n_items_mismatch=0
ref_items_A=""
ref_items_B=""

record() {
    printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$CSV"
}

# bash 3.2 on macOS has no associative arrays, so the two arms use scalar variables.
for i in $(seq 1 "$PAIRS"); do
    # Alternate within the pair so intra-pair order effects cancel.
    if [ $((i % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
    st_A=""; st_B=""; ns_A=""; ns_B=""; items_A=""; items_B=""; pct_A=""; pct_B=""
    for arm in $ORDER; do
        n_attempted=$((n_attempted + 1))
        one_run "$arm" "pair${i}_${arm}"
        if [ "$arm" = "A" ]; then
            st_A="$RUN_STATUS"; ns_A="${SAMPLE_NS:-}"; items_A="${SAMPLE_ITEMS:-}"; pct_A="${SAMPLE_PCT:-}"
        else
            st_B="$RUN_STATUS"; ns_B="${SAMPLE_NS:-}"; items_B="${SAMPLE_ITEMS:-}"; pct_B="${SAMPLE_PCT:-}"
        fi
        case "$(classify_status "$RUN_STATUS")" in
            ok) ;;
            signal) n_signal=$((n_signal + 1)) ;;
            wrong_answer) die "pair $i arm $arm: idisa_test reported a wrong answer (status 1). Session aborted." ;;
            harness_error) die "pair $i arm $arm: unexpected status $RUN_STATUS" ;;
        esac
    done

    if [ "$st_A" -ne 0 ] || [ "$st_B" -ne 0 ]; then
        note "pair $i discarded: statuses A=$st_A B=$st_B"
        continue
    fi
    [ -n "$ref_items_A" ] || ref_items_A="$items_A"
    [ -n "$ref_items_B" ] || ref_items_B="$items_B"
    if [ "$items_A" != "$ref_items_A" ] || [ "$items_B" != "$ref_items_B" ]; then
        n_items_mismatch=$((n_items_mismatch + 1))
        note "pair $i discarded: ITEMS mismatch A=$items_A B=$items_B"
        continue
    fi
    record "$i" A "$ns_A" "$items_A" 0 "$pct_A"
    record "$i" B "$ns_B" "$items_B" 0 "$pct_B"
done

if [ "$n_attempted" -gt 0 ]; then
    over="$(awk -v s="$n_signal" -v a="$n_attempted" 'BEGIN { print (s / a > 0.02) ? 1 : 0 }')"
    [ "$over" -eq 0 ] || die "signal death rate $n_signal/$n_attempted exceeds 0.02; session aborted"
fi

# Section 3 step 9: a build during the session rotates CACHE_PREFIX and voids everything.
SESSION_VOID=no
if ! diff -q <(snapshot_prefixes) "$SESSION/prefixes.before" >/dev/null 2>&1; then
    SESSION_VOID=yes
    note "VOID: the cache prefix set changed mid-session"
fi
if [ "$(md5 -q "$OBJ_A")" != "$MD5_A" ] || [ "$(md5 -q "$OBJ_B")" != "$MD5_B" ] \
   || [ "$(md5 -q "$PIPE_A")" != "$PMD5_RUN_A" ] || [ "$(md5 -q "$PIPE_B")" != "$PMD5_RUN_B" ]; then
    SESSION_VOID=yes
    note "VOID: a timed object changed mid-session"
fi

STATS_ARGS=(--label "$LABEL" --kernel "$KERNEL" --out "$SESSION/summary.json"
            --scope kernel
            --quantity "nanoseconds inside ${KERNEL} DoSegment, one counter row"
            "--switch=$([ "$NULL" -eq 1 ] && echo "none (null: ${ARM_B})" || echo "$FLAG")"
            --n-signal "$n_signal" --n-attempted "$n_attempted"
            --path-proof pass --md5-distinct "$MD5_DISTINCT" --session-void "$SESSION_VOID"
            --expect-floor-signature "$EXPECT_SIGNATURE")
if [ "$NULL" -eq 1 ]; then
    STATS_ARGS+=(--is-null --floor-signature "$FLOOR_SIGNATURE")
else
    STATS_ARGS+=(--expect-w-null-label "$FLOOR_LABEL")
    if [ -n "$W_NULL" ]; then
        STATS_ARGS+=(--w-null "$W_NULL" --w-null-ci "$W_NULL_CI"
                     --w-null-label "$W_NULL_LABEL" --floor-signature "$W_NULL_SIG")
    fi
fi

python3 "$BENCH/stats.py" "$CSV" "${STATS_ARGS[@]}" | tee "$SESSION/report.txt"

if [ "$NULL" -eq 1 ]; then
    python3 - "$SESSION/summary.json" "$SESSION/w_null.json" "$W_NULL_KEY" \
             "$FLOOR_LABEL" "$FLOOR_SIGNATURE" bench_micro.sh "$SESSION" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
r = s["paired_ratio_B_over_A"]
entry = {
    "floor_spread": r["spread_floor"],
    "floor_ci": max(abs(r["ci95_low"] - 1.0), abs(r["ci95_high"] - 1.0)),
    "label": sys.argv[4],
    "signature": sys.argv[5],
    "driver": sys.argv[6],
    "quantity": sys.argv[3],
    "n_pairs": s["n_pairs_accepted"],
    "session": sys.argv[7],
}
json.dump({sys.argv[3]: entry}, open(sys.argv[2], "w"), indent=2)
print("floor_spread = %.6f  (p10..p90 of the null's paired ratios, does not shrink with N)"
      % entry["floor_spread"])
print("floor_ci     = %.6f  (bootstrap CI half-width, shrinks with N, not used as a gate)"
      % entry["floor_ci"])
print("label        = %s" % entry["label"])
print("signature    = %s" % entry["signature"])
PY
    note "noise floor written to $SESSION/w_null.json; pass it with --w-null-file"
fi

note "session directory: $SESSION"
note "attempted=$n_attempted signal=$n_signal items_mismatch=$n_items_mismatch void=$SESSION_VOID"
