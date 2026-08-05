#!/usr/bin/env bash
#
# D4: static SVE2 instruction counts per kernel under qemu-user.
# Emulated wall time and CNTVCT_EL0 values are not recorded.
#
# Run inside the QA/sve2 container:
#   docker build -t parabix-sve2 QA/sve2
#   docker run --rm -v "$PWD:/src" parabix-sve2 ./QA/bench/sve2_icount.sh
#
# -ShowASM bypasses the cache. classify_insns.awk provides the shared instruction
# classification used by both native and emulated runs.
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SRC="${SRC:-$REPO}"
BUILD="${BUILD:-$SRC/build-linux}"
BIN="$BUILD/bin"
QEMU_CPU="${QEMU_CPU:-max}"
SVE2_MATTR="${SVE2_MATTR:-+sve2,+sve2-bitperm}"
DATA_A="${DATA_A:-$SRC/QA/IDISA_test/randhex65536a}"
DATA_B="${DATA_B:-$SRC/QA/IDISA_test/randhex65536b}"

command -v qemu-aarch64 >/dev/null 2>&1 || die "qemu-aarch64 not found; run this inside the QA/sve2 container"
[ -x "$BIN/idisa_test" ] || die "missing $BIN/idisa_test; run QA/sve2/run_sve2.sh first to build the Linux tree"

SESSION="$RESULTS/$(utc_stamp)_sve2_icount"
mkdir -p "$SESSION/asm"
note "session $SESSION"

# Slice one kernel out of a -ShowASM dump, from its DoSegment label to its Finalize label.
slice_kernel() {
    local asm="$1" kernel="$2"
    awk -v k="$kernel" '
        $0 ~ ("^_?" k "_DoSegment:") { on = 1 }
        on { print }
        on && $0 ~ ("^_?" k "_Finalize:") { exit }
    ' "$asm"
}

# Validate the instruction classifier against a fixed assembly sample.
counter_selftest() {
    local tmp got want
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
_k_DoSegment:
	.cfi_startproc
	ptrue	p0.b
	whilelo	p1.d, x8, x9
	ld1d	{ z0.d }, p0/z, [x0]
	bext	z1.d, z0.d, z2.d
	and	v2.16b, v3.16b, v4.16b
	and.16b	v5, v6, v7
	ldr	q5, [x13], #16
	add	x8, x8, #1
	lsl	x9, x9, #4
	sub	x10, x10, x11
	mov	w12, #0
	subs	x14, x14, #1
	b.ne	.LBB0_1
	ret
_k_Finalize:
EOF
    got="$(awk -f "$CLASSIFY" "$tmp")"
    rm -f "$tmp"
    want="7 7"
    [ "$got" = "$want" ] || die "counter self-test failed: classify_insns.awk gave '$got', expected '$want'"
    note "counter self-test passed: 7 vector, 7 scalar over both syntaxes and SVE"
}
counter_selftest

# run_arm LABEL KERNEL OP FW --env ENV... -- --flags FLAG...
# Keep environment arguments separate from binary options.
run_arm() {
    local label="$1" kernel="$2" op="$3" fw="$4"; shift 4
    local envp=() flags=() mode=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --env) mode=env ;;
            --flags) mode=flags ;;
            *) case "$mode" in
                   env) envp+=("$1") ;;
                   flags) flags+=("$1") ;;
                   *) die "run_arm: argument '$1' before --env or --flags" ;;
               esac ;;
        esac
        shift
    done
    local asm="$SESSION/asm/${label}.s"
    local out="$SESSION/${label}.out" err="$SESSION/${label}.err"
    run_one "$out" "$err" "${envp[@]}" "$BIN/idisa_test" -enable-object-cache=0 -ShowASM="$asm" \
            "${flags[@]+"${flags[@]}"}" -q "$op" "$fw" "$DATA_A" "$DATA_B"
    if [ "$RUN_STATUS" -ne 0 ]; then
        note "MISSING $label: exited $RUN_STATUS (see $err)"
        return 0
    fi
    [ -f "$asm" ] || { note "MISSING $label: no assembly written"; return 0; }
    local slice counts vec scal bext bdep compact tbl
    slice="$SESSION/asm/${label}.${kernel}.s"
    slice_kernel "$asm" "$kernel" > "$slice"
    if [ ! -s "$slice" ]; then
        note "MISSING $label: kernel $kernel absent from the dump"
        return 0
    fi
    counts="$(awk -f "$CLASSIFY" "$slice")"
    vec="$(printf '%s' "$counts" | awk '{print $1}')"
    scal="$(printf '%s' "$counts" | awk '{print $2}')"
    bext="$(grep -cE '\bbext[[:space:]]+z' "$slice" || true)"
    bdep="$(grep -cE '\bbdep[[:space:]]+z' "$slice" || true)"
    compact="$(grep -cE '\bcompact[[:space:]]+z' "$slice" || true)"
    tbl="$(grep -cE '\btbl\b' "$slice" || true)"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$label" "$op" "$fw" "$vec" "$scal" "$bext" "$bdep" "$compact" "$tbl" >> "$COUNTS"
    note "$label: vector=$vec scalar=$scal bext=$bext bdep=$bdep compact=$compact tbl=$tbl"
}

COUNTS="$SESSION/icounts.csv"
echo "arm,op,fw,vector_insns,scalar_insns,bext,bdep,compact,tbl" > "$COUNTS"
EXPECTED="$SESSION/expected_arms.txt"
: > "$EXPECTED"
# Known unsupported control arms.
KNOWN_ABSENT="$SESSION/known_absent.txt"
{
    echo "generic_expand_fw8 generic IDISA_Builder::mvmd_expand crashes below fw=64"
    echo "generic_expand_fw16 generic IDISA_Builder::mvmd_expand crashes below fw=64"
    echo "generic_expand_fw32 generic IDISA_Builder::mvmd_expand crashes below fw=64"
} > "$KNOWN_ABSENT"

SVE2_ENV=(env PARABIX_FORCE_BUILDER=ARM_SVE2 PARABIX_EXTRA_MATTR="$SVE2_MATTR" qemu-aarch64 -cpu "$QEMU_CPU")
NEON_ENV=(env PARABIX_FORCE_BUILDER=ARM qemu-aarch64 -cpu "$QEMU_CPU")

emit() { echo "$1" >> "$EXPECTED"; }

for fw in 8 16 32 64; do
    for pair in "pext:simd_pext" "pdep:simd_pdep"; do
        short="${pair%%:*}"; op="${pair##*:}"
        kern="${op}${fw}_test"
        emit "sve2_${short}_fw${fw}"; emit "generic_${short}_fw${fw}"; emit "neon_${short}_fw${fw}"
        run_arm "sve2_${short}_fw${fw}"    "$kern" "$op" "$fw" --env "${SVE2_ENV[@]}"
        # Compare SVE2 BitPerm with the generic bit-serial path.
        run_arm "generic_${short}_fw${fw}" "$kern" "$op" "$fw" --env "${SVE2_ENV[@]}" \
                --flags -bench-generic-bitperm
        run_arm "neon_${short}_fw${fw}"    "$kern" "$op" "$fw" --env "${NEON_ENV[@]}"
    done
    for pair in "compress:mvmd_compress" "expand:mvmd_expand"; do
        short="${pair%%:*}"; op="${pair##*:}"
        kern="${op}${fw}_test"
        emit "sve2_${short}_fw${fw}"; emit "generic_${short}_fw${fw}"; emit "neon_${short}_fw${fw}"
        run_arm "sve2_${short}_fw${fw}"    "$kern" "$op" "$fw" --env "${SVE2_ENV[@]}"
        run_arm "generic_${short}_fw${fw}" "$kern" "$op" "$fw" --env "${SVE2_ENV[@]}" \
                --flags "$(bench_bit_flag "$short")"
        run_arm "neon_${short}_fw${fw}"    "$kern" "$op" "$fw" --env "${NEON_ENV[@]}"
    done
done

echo ""
echo "SVE2 static instruction counts. These are counts, not times."
echo "No speed, speedup or cycle figure can be derived from this table."
echo "vector_insns is classified by operand register class, not by mnemonic."
column -s, -t < "$COUNTS"

# Require every supported arm to appear in the output table.
UNEXPLAINED="$(python3 - "$COUNTS" "$EXPECTED" "$KNOWN_ABSENT" <<'PY'
import csv, sys
have = {r["arm"] for r in csv.DictReader(open(sys.argv[1]))}
want = [l.strip() for l in open(sys.argv[2]) if l.strip()]
known = {}
for line in open(sys.argv[3]):
    parts = line.split(None, 1)
    if parts:
        known[parts[0]] = parts[1].strip() if len(parts) > 1 else ""
absent = [a for a in want if a not in have]
explained = [(a, known[a]) for a in absent if a in known]
unexplained = [a for a in absent if a not in known]
if explained:
    print("EXPLAINED", file=sys.stderr)
    for a, why in explained:
        print("  %-24s %s" % (a, why), file=sys.stderr)
print(" ".join(unexplained))
PY
)"
if [ -n "$UNEXPLAINED" ]; then
    echo ""
    echo "These arms produced no row and no cause is recorded for them. The table above"
    echo "therefore does not answer what its heading claims."
    printf '  %s\n' $UNEXPLAINED
    die "unexplained missing arms in $COUNTS: $UNEXPLAINED"
fi

note "session directory: $SESSION"

# Dynamic counts require an explicitly configured TCG plugin.
if [ -n "${QEMU_INSN_PLUGIN:-}" ] && [ -f "$QEMU_INSN_PLUGIN" ]; then
    note "TCG plugin $QEMU_INSN_PLUGIN present; dynamic counts are possible but are not implemented here"
else
    note "no TCG instruction-count plugin configured; static counts only"
fi
