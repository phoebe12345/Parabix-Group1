#!/usr/bin/env bash
#
# D3: mvmd_compress and mvmd_expand against mask density, NEON versus generic.
#
# The claim this supports is that the native path is constant cost across density while
# the generic path is data dependent. The density axis is therefore the deliverable, and
# it needs the same protection every other axis in this harness gets.
#
# Two defects in the earlier version made the density axis worthless and both are fixed
# here. First, each density point used to be its own sub-session, run to completion in
# order, minutes apart, and the result was min and max pooled across those sessions. Any
# drift over the sweep landed in the spread. The points are now INTERLEAVED: one
# repetition visits every point before the next repetition starts, so drift is common
# mode across the whole axis. Second, the spread had no floor. A REPEAT CONTROL point now
# re-measures the first density of each width under a second point id, over byte-identical
# operand files. The spread between those two is the resolvability floor of the density
# axis, and a density spread below it is not evidence of anything.
#
# This is NEON versus generic. It says nothing about SVE2: at fw=8 and fw=16 SVE COMPACT
# has no encoding and the SVE2 builder delegates to NEON.
#
# Usage:
#   bench_density.sh --op mvmd_compress [--pairs 31] [--w-null-file F]
#   bench_density.sh --null --op mvmd_compress
#   bench_density.sh --smoke --op mvmd_compress
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

OP=mvmd_compress
PAIRS=31
WARMUP=5
SMOKE=0
NULL=0
W_NULL_FILE=""
FWS="8 16 32 64"
DENSITIES="0 6.25 25 50 75 93.75 100"
FWS_SET=0
DENSITIES_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --op) OP="$2"; shift ;;
        --pairs) PAIRS="$2"; shift ;;
        --warmup) WARMUP="$2"; shift ;;
        --smoke) SMOKE=1 ;;
        --null) NULL=1 ;;
        --w-null-file) W_NULL_FILE="$2"; shift ;;
        --fws) FWS="$2"; FWS_SET=1; shift ;;
        --densities) DENSITIES="$2"; DENSITIES_SET=1; shift ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done

case "$OP" in
    mvmd_compress) BIT=compress ;;
    mvmd_expand)   BIT=expand ;;
    *) die "--op must be mvmd_compress or mvmd_expand" ;;
esac
FLAG="$(bench_bit_flag "$BIT")"
SUFFIX="$(bench_bit_suffix "$BIT")"
ARM_A=ARM
ARM_EXP="ARM${SUFFIX}"

if [ "$SMOKE" -eq 1 ]; then
    PAIRS=3
    WARMUP=1
    [ "$FWS_SET" -eq 1 ] || FWS="8 32"
    [ "$DENSITIES_SET" -eq 1 ] || DENSITIES="0 50 100"
    CORPUS="$CORPUS/smoke"
fi
DENSITY_DIR="$CORPUS/density"
[ -d "$DENSITY_DIR" ] || die "missing $DENSITY_DIR (run make_corpus.sh --density)"

# In null mode arm B is not the generic path, so the table must not call it that.
if [ "$NULL" -eq 1 ]; then
    LABEL="null_density_${OP}"; ARM_B_ROLE=null
else
    LABEL="density_${OP}"; ARM_B_ROLE=generic
fi
SESSION="$RESULTS/$(utc_stamp)_${LABEL}"
mkdir -p "$SESSION/stderr" "$SESSION/stdout"

PRE_ARGS=("$SESSION")
[ "$SMOKE" -eq 0 ] || PRE_ARGS+=(--smoke)
bash "$BENCH/preflight.sh" "${PRE_ARGS[@]}"
trap 'rmdir "$BUILD/.bench.lock" 2>/dev/null || true' EXIT

SKIPPED="$SESSION/skipped.txt"
: > "$SKIPPED"

COMMON=(-EnableCycleCounter -thread-num=1 -trace-object-cache -q)

# The generic control arm has to be able to run before any point at this width is worth
# timing. Generic mvmd_expand dies below fw=64 on this branch, reproduced independently
# with -BlockSize=256 and no bench option. Record the skip rather than abort the sweep.
usable_fws=""
for fw in $FWS; do
    st=0
    "$BIN/idisa_test" -q "$FLAG" "$OP" "$fw" \
        "$REPO/QA/IDISA_test/randhex65536a" "$REPO/QA/IDISA_test/randhex65536b" \
        >/dev/null 2>&1 || st=$?
    if [ "$st" -eq 0 ]; then
        usable_fws="$usable_fws $fw"
    else
        echo "fw=$fw skipped: the generic control arm exited $st, so there is nothing to compare against" >> "$SKIPPED"
        note "fw=$fw skipped: generic control arm exited $st"
    fi
done
[ -n "$usable_fws" ] || die "the generic control arm failed at every requested width; see $SKIPPED"
FWS="$usable_fws"

# ---- build the interleaved point list ----
# Each entry is "id fw k density opa opb role". role is 'density' for a real point and
# 'repeat' for the control that re-measures the first density of the same width.
POINTS="$SESSION/points.txt"
: > "$POINTS"
for fw in $FWS; do
    nfields=$((128 / fw))
    ks="$(awk -v fw="$fw" -v ds="$DENSITIES" 'BEGIN {
        n = 128 / fw; c = split(ds, a, " "); out = "";
        for (i = 1; i <= c; i++) { k = int(a[i] / 100.0 * n + 0.5); seen[k] = 1 }
        for (k = 0; k <= n; k++) if (seen[k]) out = out k " ";
        print out }')"
    first_k=""
    for k in $ks; do
        [ -n "$first_k" ] || first_k="$k"
        d="$(awk -v k="$k" -v n="$nfields" 'BEGIN { printf "%.4f", 100.0 * k / n }')"
        tag="$(printf 'fw%s_k%s' "$fw" "$k")"
        opa="$DENSITY_DIR/${tag}_a"
        opb="$DENSITY_DIR/${tag}_b"
        [ -f "$opa" ] || die "missing $opa (run make_corpus.sh --density)"
        [ -f "$opb" ] || die "missing $opb (run make_corpus.sh --density)"
        printf '%s %s %s %s %s %s density\n' "$tag" "$fw" "$k" "$d" "$opa" "$opb" >> "$POINTS"
    done
    # The repeat control. Same operand files as the first density of this width, under a
    # separate point id, so its spread against that point is the floor of the axis.
    d="$(awk -v k="$first_k" -v n="$nfields" 'BEGIN { printf "%.4f", 100.0 * k / n }')"
    printf '%s %s %s %s %s %s repeat\n' "fw${fw}_k${first_k}_repeat" "$fw" "$first_k" "$d" \
        "$DENSITY_DIR/fw${fw}_k${first_k}_a" "$DENSITY_DIR/fw${fw}_k${first_k}_b" >> "$POINTS"
done
NPOINTS="$(grep -c . "$POINTS")"
note "$NPOINTS points, interleaved, $PAIRS repetitions each"

# ---- structural probe, per width ----
# The bench switches are global to the builder, so a switch can change the pipeline
# driver module as well as the kernel. Prove it per width, and in null mode pick an arm B
# that reproduces the same structure.
probe_objects() {
    local tag="$1" armname="$2" kernel="$3" opa="$4" opb="$5" fw="$6"; shift 6
    local out="$SESSION/stdout/probe_$tag" err="$SESSION/stderr/probe_$tag"
    PROBE_OK=0; PROBE_KMD5=""; PROBE_PMD5=""; PROBE_PIPE=""
    run_one "$out" "$err" "$BIN/idisa_test" "${COMMON[@]}" "$@" "$OP" "$fw" "$opa" "$opb"
    [ "$RUN_STATUS" -eq 0 ] || return 0
    assert_trace "$err" "$armname" "$kernel"
    local prefix kobj pobj
    prefix="$(newest_prefix)"
    PROBE_PIPE="$(pipeline_module_base "$err")"
    [ -n "$PROBE_PIPE" ] || die "no pipeline driver module in the trace for $tag"
    kobj="$(kernel_object_path "$prefix" "$kernel" "$armname")"
    pobj="$(kernel_object_path "$prefix" "$PROBE_PIPE" "$armname")"
    [ -f "$kobj" ] || die "kernel object absent for $tag: $kobj"
    [ -f "$pobj" ] || die "pipeline object absent for $tag: $pobj"
    PROBE_KMD5="$(md5 -q "$kobj")"
    PROBE_PMD5="$(md5 -q "$pobj")"
    PROBE_OK=1
}

SIGFILE="$SESSION/signatures.txt"
: > "$SIGFILE"
NULLBITS="$SESSION/nullbits.txt"
: > "$NULLBITS"
PROOF="$SESSION/path_proof.txt"
: > "$PROOF"

for fw in $FWS; do
    kernel="${OP}${fw}_test"
    first_line="$(awk -v f="$fw" '$2 == f && $7 == "density" { print; exit }' "$POINTS")"
    opa="$(printf '%s' "$first_line" | awk '{print $5}')"
    opb="$(printf '%s' "$first_line" | awk '{print $6}')"

    probe_objects "a_fw$fw" "$ARM_A" "$kernel" "$opa" "$opb" "$fw"
    [ "$PROBE_OK" -eq 1 ] || die "arm A failed the structural probe at fw=$fw"
    kA="$PROBE_KMD5"; pA="$PROBE_PMD5"; pipebase="$PROBE_PIPE"

    probe_objects "b_fw$fw" "$ARM_EXP" "$kernel" "$opa" "$opb" "$fw" "$FLAG"
    [ "$PROBE_OK" -eq 1 ] || die "arm B failed the structural probe at fw=$fw"
    [ "$kA" != "$PROBE_KMD5" ] || die "$FLAG changed no byte of $kernel at fw=$fw"
    if [ "$pA" = "$PROBE_PMD5" ]; then psig="pipeline-identical"; else psig="pipeline-distinct"; fi
    printf '%s separate-cache-entries,%s\n' "$fw" "$psig" >> "$SIGFILE"
    {
        echo "fw=$fw kernel=$kernel pipeline=$pipebase"
        echo "  arm A kernel md5 $kA   pipeline md5 $pA"
        echo "  arm B kernel md5 $PROBE_KMD5   pipeline md5 $PROBE_PMD5"
        echo "  signature separate-cache-entries,$psig"
    } >> "$PROOF"

    if [ "$NULL" -eq 1 ]; then
        chosen=""
        for cand in $ALL_BENCH_BITS; do
            [ "$cand" != "$BIT" ] || continue
            cflag="$(bench_bit_flag "$cand")"
            csuf="$(bench_bit_suffix "$cand")"
            probe_objects "null_${cand}_fw$fw" "ARM${csuf}" "$kernel" "$opa" "$opb" "$fw" "$cflag"
            [ "$PROBE_OK" -eq 1 ] || continue
            [ "$PROBE_KMD5" = "$kA" ] || continue
            if [ "$PROBE_PMD5" = "$pA" ]; then csig="pipeline-identical"; else csig="pipeline-distinct"; fi
            if [ "$csig" = "$psig" ]; then chosen="$cand"; break; fi
        done
        if [ -n "$chosen" ]; then
            printf '%s %s separate-cache-entries,%s\n' "$fw" "$chosen" "$psig" >> "$NULLBITS"
            note "fw=$fw null arm B = $(bench_bit_flag "$chosen")"
        else
            printf '%s none same-command-line,pipeline-identical\n' "$fw" >> "$NULLBITS"
            note "fw=$fw: no bench bit reproduces the measured structure; the floor omits the layout term"
        fi
    fi
done
cat "$PROOF" >&2

# arm_flag_for FW -> echoes the flag list for arm B at this width
arm_b_flag_for() {
    local fw="$1" bitname
    if [ "$NULL" -eq 0 ]; then printf '%s\n' "$FLAG"; return 0; fi
    bitname="$(awk -v f="$fw" '$1 == f { print $2 }' "$NULLBITS")"
    [ "$bitname" != none ] || return 0
    bench_bit_flag "$bitname"
}
arm_b_name_for() {
    local fw="$1" bitname
    if [ "$NULL" -eq 0 ]; then printf '%s\n' "$ARM_EXP"; return 0; fi
    bitname="$(awk -v f="$fw" '$1 == f { print $2 }' "$NULLBITS")"
    if [ "$bitname" = none ]; then printf '%s\n' "$ARM_A"; else printf 'ARM%s\n' "$(bench_bit_suffix "$bitname")"; fi
}

# ---- interleaved sampling ----
for id in $(awk '{print $1}' "$POINTS"); do
    mkdir -p "$SESSION/points/$id"
    echo "pair,arm,ns,items,status,pct" > "$SESSION/points/$id/samples.csv"
done

n_attempted=0; n_signal=0

# one_run ARM TAG KERNEL FW OPA OPB [flags ...]
one_run() {
    local arm="$1" tag="$2" kernel="$3" fw="$4" opa="$5" opb="$6"; shift 6
    local out="$SESSION/stdout/$tag" err="$SESSION/stderr/$tag" armname
    if [ "$arm" = A ]; then armname="$ARM_A"; else armname="$(arm_b_name_for "$fw")"; fi
    run_one "$out" "$err" "$BIN/idisa_test" "${COMMON[@]}" "$@" "$OP" "$fw" "$opa" "$opb"
    SAMPLE_NS=""; SAMPLE_ITEMS=""; SAMPLE_PCT=""
    [ "$RUN_STATUS" -eq 0 ] || return 0
    assert_trace "$err" "$armname" "$kernel"
    local row
    row="$(parse_counter_row "$err" "$kernel")"
    SAMPLE_ITEMS="$(printf '%s' "$row" | awk '{print $1}')"
    SAMPLE_NS="$(printf '%s' "$row" | awk '{print $2}')"
    SAMPLE_PCT="$(printf '%s' "$row" | awk '{print $3}')"
    return 0
}

note "warmup: $WARMUP repetitions over every point"
for rep in $(seq 1 "$WARMUP"); do
    while read -r id fw k d opa opb role; do
        kernel="${OP}${fw}_test"
        bflag="$(arm_b_flag_for "$fw")"
        one_run A "warm_${rep}_${id}_A" "$kernel" "$fw" "$opa" "$opb"
        [ "$RUN_STATUS" -eq 0 ] || die "warmup arm A failed at $id"
        if [ -n "$bflag" ]; then
            one_run B "warm_${rep}_${id}_B" "$kernel" "$fw" "$opa" "$opb" "$bflag"
        else
            one_run B "warm_${rep}_${id}_B" "$kernel" "$fw" "$opa" "$opb"
        fi
        [ "$RUN_STATUS" -eq 0 ] || die "warmup arm B failed at $id"
    done < "$POINTS"
done

note "sampling: $PAIRS repetitions, all $NPOINTS points visited inside each repetition"
for rep in $(seq 1 "$PAIRS"); do
    if [ $((rep % 2)) -eq 1 ]; then ORDER="A B"; else ORDER="B A"; fi
    while read -r id fw k d opa opb role; do
        kernel="${OP}${fw}_test"
        bflag="$(arm_b_flag_for "$fw")"
        st_A=""; st_B=""; ns_A=""; ns_B=""; it_A=""; it_B=""; pc_A=""; pc_B=""
        for arm in $ORDER; do
            n_attempted=$((n_attempted + 1))
            if [ "$arm" = A ]; then
                one_run A "r${rep}_${id}_A" "$kernel" "$fw" "$opa" "$opb"
                st_A="$RUN_STATUS"; ns_A="${SAMPLE_NS:-}"; it_A="${SAMPLE_ITEMS:-}"; pc_A="${SAMPLE_PCT:-}"
            else
                if [ -n "$bflag" ]; then
                    one_run B "r${rep}_${id}_B" "$kernel" "$fw" "$opa" "$opb" "$bflag"
                else
                    one_run B "r${rep}_${id}_B" "$kernel" "$fw" "$opa" "$opb"
                fi
                st_B="$RUN_STATUS"; ns_B="${SAMPLE_NS:-}"; it_B="${SAMPLE_ITEMS:-}"; pc_B="${SAMPLE_PCT:-}"
            fi
            case "$(classify_status "$RUN_STATUS")" in
                ok) ;;
                signal) n_signal=$((n_signal + 1)) ;;
                wrong_answer) die "rep $rep point $id arm $arm: idisa_test reported a wrong answer. Session aborted." ;;
                harness_error) die "rep $rep point $id arm $arm: unexpected status $RUN_STATUS" ;;
            esac
        done
        if [ "$st_A" -ne 0 ] || [ "$st_B" -ne 0 ]; then
            note "rep $rep point $id discarded: A=$st_A B=$st_B"
            continue
        fi
        printf '%s,A,%s,%s,0,%s\n' "$rep" "$ns_A" "$it_A" "$pc_A" >> "$SESSION/points/$id/samples.csv"
        printf '%s,B,%s,%s,0,%s\n' "$rep" "$ns_B" "$it_B" "$pc_B" >> "$SESSION/points/$id/samples.csv"
    done < "$POINTS"
done

if [ "$n_attempted" -gt 0 ]; then
    over="$(awk -v s="$n_signal" -v a="$n_attempted" 'BEGIN { print (s / a > 0.02) ? 1 : 0 }')"
    [ "$over" -eq 0 ] || die "signal death rate $n_signal/$n_attempted exceeds 0.02; session aborted"
fi

SESSION_VOID=no
if ! diff -q <(snapshot_prefixes) "$SESSION/prefixes.before" >/dev/null 2>&1; then
    SESSION_VOID=yes; note "VOID: the cache prefix set changed mid-session"
fi

# ---- per-point statistics ----
SWEEP="$SESSION/sweep.csv"
echo "op,fw,k,density_pct,role,arm,median_ns,iqr_pct,ratio_median,ratio_ci_low,ratio_ci_high,reportable" > "$SWEEP"

read_floor_for_fw() {
    local file="$1" fw="$2"
    python3 - "$file" "counter_fw$fw" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
k = sys.argv[2]
if k not in d:
    sys.exit("floor file has no '%s' entry; it holds %s" % (k, sorted(d)))
e = d[k]
print("%.6f %.6f %s %s" % (e["floor_spread"], e["floor_ci"], e["label"], e["signature"]))
PY
}

while read -r id fw k d opa opb role; do
    point="$SESSION/points/$id"
    kernel="${OP}${fw}_test"
    sig="$(awk -v f="$fw" '$1 == f { print $2 }' "$SIGFILE")"
    input_tag="$(sha256_of "$opa" | cut -c1-8)+$(sha256_of "$opb" | cut -c1-8)"
    # The floor is keyed by width, not by density point. Every point of a width shares
    # one instrument and one kernel; only the operand bytes differ. The report states
    # which point the floor was measured on. See the limitation in README section 9.
    expect_label="bench_density.sh:counter_fw${fw}:${kernel}"
    args=(--label "${OP}${fw}_k${k}_${role}" --kernel "$kernel" --out "$point/summary.json"
          --scope sweep-point
          --quantity "nanoseconds inside ${kernel} DoSegment at density ${d}% (operands ${input_tag})"
          "--switch=$([ "$NULL" -eq 1 ] && echo "none, noise floor" || echo "$FLAG")"
          --n-signal 0 --n-attempted 1
          --path-proof pass --md5-distinct yes --session-void "$SESSION_VOID"
          --expect-floor-signature "$sig")
    if [ "$NULL" -eq 1 ]; then
        nsig="$(awk -v f="$fw" '$1 == f { print $3 }' "$NULLBITS")"
        args+=(--is-null --floor-signature "$nsig")
    else
        args+=(--expect-w-null-label "$expect_label")
        if [ -n "$W_NULL_FILE" ]; then
            read -r fs fc fl fg <<<"$(read_floor_for_fw "$W_NULL_FILE" "$fw")"
            args+=(--w-null "$fs" --w-null-ci "$fc" --w-null-label "$fl" --floor-signature "$fg")
        fi
    fi
    python3 "$BENCH/stats.py" "$point/samples.csv" "${args[@]}" > "$point/report.txt" || true
    python3 - "$point/summary.json" "$OP" "$fw" "$k" "$d" "$role" "$ARM_B_ROLE" >> "$SWEEP" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
op, fw, k, d, role, arm_b_name = sys.argv[2:8]
r = s["paired_ratio_B_over_A"]
for arm, key in (("native", "arm_A_native"), (arm_b_name, "arm_B_control")):
    a = s[key]
    print("%s,%s,%s,%s,%s,%s,%.1f,%.2f,%.5f,%.5f,%.5f,%s" % (
        op, fw, k, d, role, arm, a["median_ns"], a["iqr_pct_of_median"],
        r["median"], r["ci95_low"], r["ci95_high"], s["reportable"]))
PY
done < "$POINTS"

if [ "$NULL" -eq 1 ]; then
    python3 - "$SESSION" "$SESSION/w_null.json" "$POINTS" "$SIGFILE" <<'PY'
import json, os, sys
session, out_path, points_path, sig_path = sys.argv[1:5]
sigs = {}
for line in open(sig_path):
    fw, sig = line.split()
    sigs[fw] = sig
entries = {}
for line in open(points_path):
    pid, fw, k, d, opa, opb, role = line.split()
    if role != "density" or ("counter_fw%s" % fw) in entries:
        continue
    s = json.load(open(os.path.join(session, "points", pid, "summary.json")))
    r = s["paired_ratio_B_over_A"]
    entries["counter_fw%s" % fw] = {
        "floor_spread": r["spread_floor"],
        "floor_ci": max(abs(r["ci95_low"] - 1.0), abs(r["ci95_high"] - 1.0)),
        "label": "bench_density.sh:counter_fw%s:%s" % (fw, s["kernel"]),
        "signature": sigs.get(fw, ""),
        "driver": "bench_density.sh",
        "quantity": "counter_fw%s" % fw,
        "measured_at_point": pid,
        "n_pairs": s["n_pairs_accepted"],
        "session": session,
    }
    print("fw %-3s floor_spread %.6f  floor_ci %.6f  measured at %s"
          % (fw, entries["counter_fw%s" % fw]["floor_spread"],
             entries["counter_fw%s" % fw]["floor_ci"], pid))
json.dump(entries, open(out_path, "w"), indent=2)
PY
    note "noise floors written to $SESSION/w_null.json; pass it with --w-null-file"
fi

note "sweep written to $SWEEP"
if [ -s "$SKIPPED" ]; then
    echo ""
    echo "Widths skipped because the generic control arm could not run:"
    cat "$SKIPPED"
fi

# ---- the density axis, with its own floor ----
python3 - "$SWEEP" "$PAIRS" <<'PY'
import csv, sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
n = sys.argv[2]
density = defaultdict(list)
repeat = defaultdict(dict)
for r in rows:
    key = (int(r["fw"]), r["arm"])
    if r["role"] == "density":
        density[key].append((float(r["density_pct"]), int(r["k"]), float(r["median_ns"])))
    else:
        repeat[key][int(r["k"])] = float(r["median_ns"])

print("")
print("D3 density axis. All points were interleaved inside one session, so drift is")
print("common mode across the axis. N = %s repetitions per point." % n)
print("")
print("  fw   arm       density%      k      median ns")
for key in sorted(density):
    fw, arm = key
    for d, k, ns in sorted(density[key]):
        print("  %-4d %-8s %9.2f %6d %14.1f" % (fw, arm, d, k, ns))
print("")
print("  fw   arm       density spread%   repeat floor%   verdict")
for key in sorted(density):
    fw, arm = key
    vals = [ns for _, _, ns in density[key]]
    lo, hi = min(vals), max(vals)
    spread = 100.0 * (hi - lo) / lo if lo else float("nan")
    first_k, first_ns = sorted(density[key], key=lambda t: t[1])[0][1], None
    for d, k, ns in density[key]:
        if k == first_k:
            first_ns = ns
    rep_ns = repeat[key].get(first_k)
    if rep_ns is None or first_ns is None or not first_ns:
        floor = float("nan")
        verdict = "NO FLOOR: the repeat control point is missing, nothing is claimable"
    else:
        floor = 100.0 * abs(rep_ns - first_ns) / first_ns
        if spread > floor:
            verdict = "resolvable: density spread exceeds the floor"
        else:
            verdict = "NOT RESOLVABLE: inside the floor, do not call this flat or data dependent"
    print("  %-4d %-8s %14.2f %15.2f   %s" % (fw, arm, spread, floor, verdict))
print("")
print("The repeat floor is the spread between two point ids measured over byte-identical")
print("operand files inside the same interleaved session. A density spread below it is")
print("not evidence of density dependence, and a spread below it is not evidence of")
print("flatness either. Only a spread above it says anything.")
PY
note "session directory: $SESSION"
