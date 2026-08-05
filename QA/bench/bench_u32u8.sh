#!/usr/bin/env bash
#
# D2: paired u32u8 timing on large UTF-32LE input. Kernel time is an upper
# bound on operation time; process and pipeline attribution remain separate.
# Usage:
#   bench_u32u8.sh [--bit shift2|shift4] [--pairs 31] [--w-null-file F]
#   bench_u32u8.sh --null [--bit shift2]
#   bench_u32u8.sh --smoke [--bit shift2]
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BIT=shift2
PAIRS=31
WARMUP=5
SMOKE=0
NULL=0
W_NULL_FILE=""
INPUT=""
REFERENCE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --bit) BIT="$2"; shift ;;
        --pairs) PAIRS="$2"; shift ;;
        --warmup) WARMUP="$2"; shift ;;
        --smoke) SMOKE=1 ;;
        --null) NULL=1 ;;
        --w-null-file) W_NULL_FILE="$2"; shift ;;
        --input) INPUT="$2"; shift ;;
        --reference) REFERENCE="$2"; shift ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done

case "$BIT" in
    shift2|shift4) : ;;
    *) die "u32u8 does not call mvmd_compress or mvmd_expand; --bit must be shift2 or shift4" ;;
esac
FLAG="$(bench_bit_flag "$BIT")"
SUFFIX="$(bench_bit_suffix "$BIT")"
ARM_A=ARM
ARM_EXP="ARM${SUFFIX}"

if [ "$SMOKE" -eq 1 ]; then
    PAIRS=3
    WARMUP=1
    CORPUS="$CORPUS/smoke"
fi
[ -n "$INPUT" ] || INPUT="$CORPUS/t160.u32"
[ -n "$REFERENCE" ] || REFERENCE="$CORPUS/u32u8.reference"
[ -f "$INPUT" ] || die "missing $INPUT (run make_corpus.sh --u32u8, or --smoke for the smoke corpus)"
[ -f "$REFERENCE" ] || die "missing $REFERENCE (run make_corpus.sh --u32u8)"

INPUT_TAG="$(sha256_of "$INPUT" | cut -c1-8)"
FLOOR_LABEL_OP="bench_u32u8.sh:op:${INPUT_TAG}"
FLOOR_LABEL_WALL="bench_u32u8.sh:wall:${INPUT_TAG}"

if [ "$NULL" -eq 1 ]; then LABEL="null_u32u8_${BIT}"; else LABEL="u32u8_${BIT}"; fi
SESSION="$RESULTS/$(utc_stamp)_${LABEL}"
mkdir -p "$SESSION/stderr" "$SESSION/stdout"

PRE_ARGS=("$SESSION")
[ "$SMOKE" -eq 0 ] || PRE_ARGS+=(--smoke)
bash "$BENCH/preflight.sh" "${PRE_ARGS[@]}"
trap 'rmdir "$BUILD/.bench.lock" 2>/dev/null || true; rm -f "$SESSION/stdout/live.u8"' EXIT

# Three kernel names, five counter rows: FieldDeposit64_6 appears three times.
DEPOSIT_ROWS="u8depositMask FieldDeposit64_3 FieldDeposit64_6"
PROOF_KERNEL=FieldDeposit64_3
COMMON=(-EnableCycleCounter -thread-num=1 -trace-object-cache)

sum_deposit_ns() {
    local err="$1" total=0 rows
    for name in $DEPOSIT_ROWS; do
        rows="$(parse_counter_rows "$err" "$name")"
        [ -n "$rows" ] || die "counter row '$name' absent from $err"
        total=$((total + $(printf '%s\n' "$rows" | awk '{s += $2} END {printf "%d", s}')))
    done
    printf '%d\n' "$total"
}

sum_deposit_pct() {
    local err="$1" rows out=0
    for name in $DEPOSIT_ROWS; do
        rows="$(parse_counter_rows "$err" "$name")"
        out="$(awk -v acc="$out" 'BEGIN {s = acc} {s += $3} END {printf "%.4f", s}' <<<"$rows")"
    done
    printf '%s\n' "$out"
}

# probe_objects TAG ARMNAME [flags ...] -> PROBE_OK PROBE_KMD5 PROBE_PMD5 PROBE_PIPE
# Hash every deposit kernel and the pipeline driver used by one arm.
probe_objects() {
    local tag="$1" armname="$2"; shift 2
    local out="$SESSION/stdout/live.u8" err="$SESSION/stderr/probe_$tag"
    PROBE_OK=0; PROBE_KMD5=""; PROBE_PMD5=""; PROBE_PIPE=""
    run_one "$out" "$err" "$BIN/u32u8" "${COMMON[@]}" "$@" "$INPUT"
    [ "$RUN_STATUS" -eq 0 ] || return 0
    assert_trace "$err" "$armname" "$PROOF_KERNEL"
    local prefix obj joined="" pobj
    prefix="$(newest_prefix)"
    PROBE_PIPE="$(pipeline_module_base "$err")"
    [ -n "$PROBE_PIPE" ] || die "no pipeline driver module in the trace for $tag"
    for name in $DEPOSIT_ROWS; do
        obj="$(kernel_object_path "$prefix" "$name" "$armname")"
        [ -f "$obj" ] || die "kernel object absent for $tag: $obj"
        joined="$joined$(md5 -q "$obj")"
    done
    pobj="$(kernel_object_path "$prefix" "$PROBE_PIPE" "$armname")"
    [ -f "$pobj" ] || die "pipeline object absent for $tag: $pobj"
    PROBE_KMD5="$joined"
    PROBE_PMD5="$(md5 -q "$pobj")"
    PROBE_OK=1
}

note "label=$LABEL pairs=$PAIRS warmup=$WARMUP input=$INPUT"

probe_objects arm_a "$ARM_A"
[ "$PROBE_OK" -eq 1 ] || die "arm A failed during the structural probe"
KMD5_A="$PROBE_KMD5"; PMD5_A="$PROBE_PMD5"; PIPE_BASE="$PROBE_PIPE"

probe_objects "arm_$BIT" "$ARM_EXP" "$FLAG"
[ "$PROBE_OK" -eq 1 ] || die "arm B ($FLAG) failed during the structural probe"
KMD5_EXP="$PROBE_KMD5"; PMD5_EXP="$PROBE_PMD5"

[ "$KMD5_A" != "$KMD5_EXP" ] || die "$FLAG changed no byte of any deposit kernel"
if [ "$PMD5_A" = "$PMD5_EXP" ]; then PIPE_SIG="pipeline-identical"; else PIPE_SIG="pipeline-distinct"; fi
EXPECT_SIGNATURE="separate-cache-entries,${PIPE_SIG}"
note "measured arms differ as: $EXPECT_SIGNATURE"

if [ "$NULL" -eq 1 ]; then
    NULL_BIT=""
    for cand in $ALL_BENCH_BITS; do
        [ "$cand" != "$BIT" ] || continue
        cflag="$(bench_bit_flag "$cand")"
        csuf="$(bench_bit_suffix "$cand")"
        probe_objects "null_$cand" "ARM${csuf}" "$cflag"
        [ "$PROBE_OK" -eq 1 ] || { note "null candidate $cand: run failed, skipped"; continue; }
        [ "$PROBE_KMD5" = "$KMD5_A" ] || { note "null candidate $cand: changes a deposit kernel, rejected"; continue; }
        if [ "$PROBE_PMD5" = "$PMD5_A" ]; then csig="pipeline-identical"; else csig="pipeline-distinct"; fi
        if [ "$csig" = "$PIPE_SIG" ]; then
            NULL_BIT="$cand"
            note "null arm B = $cflag (every deposit kernel byte-identical, $csig)"
            break
        fi
        note "null candidate $cand: $csig, does not match $PIPE_SIG, rejected"
    done
    if [ -n "$NULL_BIT" ]; then
        FLAG_B=("$(bench_bit_flag "$NULL_BIT")")
        ARM_B="ARM$(bench_bit_suffix "$NULL_BIT")"
        FLOOR_SIGNATURE="$EXPECT_SIGNATURE"
    else
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

# ---- floors, if a floor file was supplied ----
W_NULL_OP=""; W_NULL_OP_CI=""; W_NULL_OP_LABEL=""; W_NULL_OP_SIG=""
W_NULL_WALL=""; W_NULL_WALL_CI=""; W_NULL_WALL_LABEL=""; W_NULL_WALL_SIG=""
read_floor() {
    local file="$1" key="$2" line
    line="$(python3 - "$file" "$key" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
k = sys.argv[2]
if k not in d:
    sys.exit("floor file has no '%s' entry; it holds %s" % (k, sorted(d)))
e = d[k]
print("%.6f %.6f %s %s" % (e["floor_spread"], e["floor_ci"], e["label"], e["signature"]))
PY
)"
    printf '%s\n' "$line"
}
if [ -n "$W_NULL_FILE" ]; then
    [ -f "$W_NULL_FILE" ] || die "missing floor file $W_NULL_FILE"
    read -r W_NULL_OP W_NULL_OP_CI W_NULL_OP_LABEL W_NULL_OP_SIG <<<"$(read_floor "$W_NULL_FILE" op)"
    read -r W_NULL_WALL W_NULL_WALL_CI W_NULL_WALL_LABEL W_NULL_WALL_SIG <<<"$(read_floor "$W_NULL_FILE" wall)"
    note "op floor $W_NULL_OP from $W_NULL_OP_LABEL"
    note "wall floor $W_NULL_WALL from $W_NULL_WALL_LABEL"
fi

# one_run ARM TAG -> RUN_STATUS RUN_NS SAMPLE_NS SAMPLE_PCT SAMPLE_PIPE_NS
one_run() {
    local arm="$1" tag="$2"
    local out="$SESSION/stdout/live.u8" err="$SESSION/stderr/$tag"
    local flags=()
    [ "$arm" = "B" ] && flags=("${FLAG_B[@]+"${FLAG_B[@]}"}")
    run_one_timed "$out" "$err" "$BIN/u32u8" "${COMMON[@]}" "${flags[@]+"${flags[@]}"}" "$INPUT"
    SAMPLE_NS=""; SAMPLE_PCT=""; SAMPLE_PIPE_NS=""
    [ "$RUN_STATUS" -eq 0 ] || return 0
    local armname="$ARM_A"
    [ "$arm" = "B" ] && armname="$ARM_B"
    assert_trace "$err" "$armname" "$PROOF_KERNEL"
    # Reject successful runs whose output differs from the reference.
    cmp -s "$out" "$REFERENCE" || die "$tag produced output that differs from $REFERENCE"
    SAMPLE_NS="$(sum_deposit_ns "$err")"
    SAMPLE_PCT="$(sum_deposit_pct "$err")"
    SAMPLE_PIPE_NS="$(parse_pipeline_total_ns "$err" "$PIPE_BASE")"
    [ -n "$SAMPLE_PIPE_NS" ] || die "no pipeline total row for $PIPE_BASE in $err"
    return 0
}

note "armA=$ARM_A armB=$ARM_B"
for i in $(seq 1 "$WARMUP"); do
    one_run A "warmup_${i}_A"; [ "$RUN_STATUS" -eq 0 ] || die "warmup arm A exited $RUN_STATUS"
    one_run B "warmup_${i}_B"; [ "$RUN_STATUS" -eq 0 ] || die "warmup arm B exited $RUN_STATUS"
done

PREFIX="$(newest_prefix)"
PIPE_A="$(kernel_object_path "$PREFIX" "$PIPE_BASE" "$ARM_A")"
PIPE_B="$(kernel_object_path "$PREFIX" "$PIPE_BASE" "$ARM_B")"
[ -f "$PIPE_A" ] && [ -f "$PIPE_B" ] || die "pipeline object absent after warmup"
PMD5_RUN_A="$(md5 -q "$PIPE_A")"; PMD5_RUN_B="$(md5 -q "$PIPE_B")"
if [ "$PMD5_RUN_A" = "$PMD5_RUN_B" ]; then RUN_PIPE_SIG="pipeline-identical"; else RUN_PIPE_SIG="pipeline-distinct"; fi

MD5_SUM_A=""; MD5_SUM_B=""
{
    echo "prefix        $PREFIX"
    echo "switch        $([ "$NULL" -eq 1 ] && echo "none (null arm B is $ARM_B)" || echo "$FLAG")"
    echo ""
    echo "Per-kernel proof. vector/scalar is the instruction count inside DoSegment."
    echo "The operation under the switch is a part of each kernel, never the whole of it,"
    echo "so the summed time of these kernels is an UPPER BOUND on the operation's share."
    printf '  %-20s %-10s %-34s %-14s\n' KERNEL ARM MD5 VEC/SCALAR
    for name in $DEPOSIT_ROWS; do
        for arm in A B; do
            armname="$ARM_A"; [ "$arm" = "B" ] && armname="$ARM_B"
            obj="$(kernel_object_path "$PREFIX" "$name" "$armname")"
            [ -f "$obj" ] || die "object absent after warmup: $obj"
            m="$(md5 -q "$obj")"
            printf '  %-20s %-10s %-34s %-14s\n' "$name" "$armname" "$m" "$(count_insns "$obj" "_${name}_DoSegment")"
            if [ "$arm" = A ]; then MD5_SUM_A="$MD5_SUM_A$m"; else MD5_SUM_B="$MD5_SUM_B$m"; fi
        done
    done
    echo ""
    echo "pipeline      $PIPE_BASE"
    echo "  arm A md5   $PMD5_RUN_A"
    echo "  arm B md5   $PMD5_RUN_B"
    echo "  signature   $RUN_PIPE_SIG"
    if [ "$RUN_PIPE_SIG" = "pipeline-distinct" ]; then
        echo "  NOTE: the switch is not scoped to the deposit kernels. The pipeline driver"
        echo "  image differs between the arms and it contributes the PIPE component of every"
        echo "  counter row. The floor for this configuration must be measured with an arm B"
        echo "  that reproduces the same pipeline difference. S7 enforces that."
    fi
} > "$SESSION/path_proof.txt"
cat "$SESSION/path_proof.txt" >&2

if [ "$MD5_MUST_DIFFER" = yes ]; then
    [ "$MD5_SUM_A" != "$MD5_SUM_B" ] || die "arms share every deposit kernel md5; the switch changed no emitted code"
    MD5_DISTINCT=yes
else
    [ "$MD5_SUM_A" = "$MD5_SUM_B" ] || die "null run: arm B changed a deposit kernel, so it is not a null"
    MD5_DISTINCT=yes
    [ "$ARM_A" != "$ARM_B" ] || MD5_DISTINCT=no
fi

CSV_OP="$SESSION/samples.csv"
CSV_WALL="$SESSION/samples_wall.csv"
echo "pair,arm,ns,items,status,pct" > "$CSV_OP"
echo "pair,arm,ns,items,status,pct" > "$CSV_WALL"
PIPE_CSV="$SESSION/pipeline_totals.csv"
echo "pair,arm,deposit_ns,pipeline_ns,wall_ns" > "$PIPE_CSV"

n_attempted=0; n_signal=0

for i in $(seq 1 "$PAIRS"); do
    if [ $((i % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
    st_A=""; st_B=""; op_A=""; op_B=""; wall_A=""; wall_B=""; pct_A=""; pct_B=""; pl_A=""; pl_B=""
    for arm in $ORDER; do
        n_attempted=$((n_attempted + 1))
        one_run "$arm" "pair${i}_${arm}"
        if [ "$arm" = "A" ]; then
            st_A="$RUN_STATUS"; op_A="${SAMPLE_NS:-}"; wall_A="$RUN_NS"; pct_A="${SAMPLE_PCT:-}"; pl_A="${SAMPLE_PIPE_NS:-}"
        else
            st_B="$RUN_STATUS"; op_B="${SAMPLE_NS:-}"; wall_B="$RUN_NS"; pct_B="${SAMPLE_PCT:-}"; pl_B="${SAMPLE_PIPE_NS:-}"
        fi
        case "$(classify_status "$RUN_STATUS")" in
            ok) ;;
            signal) n_signal=$((n_signal + 1)) ;;
            wrong_answer) die "pair $i arm $arm: u32u8 exited 1. Session aborted." ;;
            harness_error) die "pair $i arm $arm: unexpected status $RUN_STATUS" ;;
        esac
    done
    if [ "$st_A" -ne 0 ] || [ "$st_B" -ne 0 ]; then
        note "pair $i discarded: statuses A=$st_A B=$st_B"
        continue
    fi
    printf '%s,A,%s,1,0,%s\n' "$i" "$op_A" "$pct_A" >> "$CSV_OP"
    printf '%s,B,%s,1,0,%s\n' "$i" "$op_B" "$pct_B" >> "$CSV_OP"
    printf '%s,A,%s,1,0,%s\n' "$i" "$wall_A" "$pct_A" >> "$CSV_WALL"
    printf '%s,B,%s,1,0,%s\n' "$i" "$wall_B" "$pct_B" >> "$CSV_WALL"
    printf '%s,A,%s,%s,%s\n' "$i" "$op_A" "$pl_A" "$wall_A" >> "$PIPE_CSV"
    printf '%s,B,%s,%s,%s\n' "$i" "$op_B" "$pl_B" "$wall_B" >> "$PIPE_CSV"
done

if [ "$n_attempted" -gt 0 ]; then
    over="$(awk -v s="$n_signal" -v a="$n_attempted" 'BEGIN { print (s / a > 0.02) ? 1 : 0 }')"
    [ "$over" -eq 0 ] || die "signal death rate $n_signal/$n_attempted exceeds 0.02; session aborted"
fi

SESSION_VOID=no
if ! diff -q <(snapshot_prefixes) "$SESSION/prefixes.before" >/dev/null 2>&1; then
    SESSION_VOID=yes; note "VOID: the cache prefix set changed mid-session"
fi
if [ "$(md5 -q "$PIPE_A")" != "$PMD5_RUN_A" ] || [ "$(md5 -q "$PIPE_B")" != "$PMD5_RUN_B" ]; then
    SESSION_VOID=yes; note "VOID: a pipeline object changed mid-session"
fi

# ---- D2a attribution from the same runs as the measured numerator ----
python3 - "$PIPE_CSV" "$SESSION/attribution.txt" "$SESSION/attribution.json" <<'PY'
import csv, json, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
out, data = [], {}
out.append("D2a attribution, measured over the whole timing loop.")
out.append("")
out.append("The numerator is the summed nanoseconds of the counter rows for the kernels")
out.append("that CONTAIN simd_pext and simd_pdep. It is not the time of those operations.")
out.append("It is an upper bound on their share.")
out.append("")
out.append("  %-6s %14s %14s %14s %12s %12s" % ("arm", "deposit ns", "pipeline ns", "wall ns",
                                                "of PIPELINE", "of PROCESS"))
for arm in ("A", "B"):
    sel = [r for r in rows if r["arm"] == arm]
    if not sel:
        continue
    dep = statistics.median(float(r["deposit_ns"]) for r in sel)
    pipe = statistics.median(float(r["pipeline_ns"]) for r in sel)
    wall = statistics.median(float(r["wall_ns"]) for r in sel)
    a_pipe = dep / pipe if pipe else float("nan")
    a_wall = dep / wall if wall else float("nan")
    out.append("  %-6s %14.0f %14.0f %14.0f %12.4f %12.4f" % (arm, dep, pipe, wall, a_pipe, a_wall))
    data[arm] = {"deposit_ns": dep, "pipeline_ns": pipe, "wall_ns": wall,
                 "attribution_pipeline": a_pipe, "attribution_wall": a_wall,
                 "pipeline_share_of_process": (pipe / wall) if wall else float("nan")}
out.append("")
if "A" in data:
    out.append("  the pipeline is %.4f of the process on arm A, so the two attributions"
               % data["A"]["pipeline_share_of_process"])
    out.append("  differ by that factor. Only the PROCESS share may carry an end-to-end claim.")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
json.dump(data, open(sys.argv[3], "w"), indent=2)
PY
cat "$SESSION/attribution.txt" >&2

ATTR_PIPE="$(python3 -c 'import json,sys; print("%.6f" % json.load(open(sys.argv[1]))["A"]["attribution_pipeline"])' "$SESSION/attribution.json")"
ATTR_WALL="$(python3 -c 'import json,sys; print("%.6f" % json.load(open(sys.argv[1]))["A"]["attribution_wall"])' "$SESSION/attribution.json")"

run_stats() {
    local csv="$1" label="$2" out="$3" scope="$4" quantity="$5" attr_flag="$6" attr="$7"
    local floor="$8" floor_ci="$9" floor_label="${10}" floor_sig="${11}" expect_label="${12}"
    local args
    args=(--label "$label" --kernel "deposit rows: $DEPOSIT_ROWS" --out "$out"
          --scope "$scope" --quantity "$quantity"
          "--switch=$([ "$NULL" -eq 1 ] && echo "none (null arm B is $ARM_B)" || echo "$FLAG")"
          --n-signal "$n_signal" --n-attempted "$n_attempted"
          --path-proof pass --md5-distinct "$MD5_DISTINCT" --session-void "$SESSION_VOID"
          "$attr_flag" "$attr"
          --expect-floor-signature "$EXPECT_SIGNATURE")
    if [ "$NULL" -eq 1 ]; then
        args+=(--is-null --floor-signature "$FLOOR_SIGNATURE")
    else
        args+=(--expect-w-null-label "$expect_label")
        if [ -n "$floor" ]; then
            args+=(--w-null "$floor" --w-null-ci "$floor_ci"
                   --w-null-label "$floor_label" --floor-signature "$floor_sig")
        fi
    fi
    python3 "$BENCH/stats.py" "$csv" "${args[@]}"
}

{
    echo "=== D2b kernel-group level: summed nanoseconds of the kernels that contain the operation ==="
    echo "=== switch toggled: $([ "$NULL" -eq 1 ] && echo "none, this is the noise floor" || echo "$FLAG") ==="
    run_stats "$CSV_OP" "${LABEL}_oplevel" "$SESSION/summary.json" kernel-group \
        "summed ns of u8depositMask and the FieldDeposit64 rows, an UPPER BOUND on simd_pext and simd_pdep" \
        --attribution-pipeline "$ATTR_PIPE" \
        "$W_NULL_OP" "$W_NULL_OP_CI" "$W_NULL_OP_LABEL" "$W_NULL_OP_SIG" "$FLOOR_LABEL_OP"
    echo ""
    echo "=== D2b end to end: wall time of the whole u32u8 process ==="
    echo "=== switch toggled: $([ "$NULL" -eq 1 ] && echo "none, this is the noise floor" || echo "$FLAG") ==="
    run_stats "$CSV_WALL" "${LABEL}_wall" "$SESSION/summary_wall.json" process \
        "wall time of the u32u8 process, start to teardown" \
        --attribution-wall "$ATTR_WALL" \
        "$W_NULL_WALL" "$W_NULL_WALL_CI" "$W_NULL_WALL_LABEL" "$W_NULL_WALL_SIG" "$FLOOR_LABEL_WALL"
} | tee "$SESSION/report.txt"

if [ "$NULL" -eq 1 ]; then
    python3 - "$SESSION/w_null.json" "$FLOOR_SIGNATURE" "$SESSION" \
             "$SESSION/summary.json" op "$FLOOR_LABEL_OP" \
             "$SESSION/summary_wall.json" wall "$FLOOR_LABEL_WALL" <<'PY'
import json, sys
out_path, signature, session = sys.argv[1], sys.argv[2], sys.argv[3]
entries = {}
for i in range(4, len(sys.argv), 3):
    summary, key, label = sys.argv[i], sys.argv[i + 1], sys.argv[i + 2]
    s = json.load(open(summary))
    r = s["paired_ratio_B_over_A"]
    entries[key] = {
        "floor_spread": r["spread_floor"],
        "floor_ci": max(abs(r["ci95_low"] - 1.0), abs(r["ci95_high"] - 1.0)),
        "label": label,
        "signature": signature,
        "driver": "bench_u32u8.sh",
        "quantity": key,
        "n_pairs": s["n_pairs_accepted"],
        "session": session,
    }
    print("%-5s floor_spread %.6f  floor_ci %.6f  %s"
          % (key, entries[key]["floor_spread"], entries[key]["floor_ci"], label))
json.dump(entries, open(out_path, "w"), indent=2)
PY
    note "noise floors written to $SESSION/w_null.json; pass it with --w-null-file"
fi

note "session directory: $SESSION"
note "attempted=$n_attempted signal=$n_signal void=$SESSION_VOID"
