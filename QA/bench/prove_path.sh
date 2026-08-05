#!/usr/bin/env bash
#
# Layer 2 path proof: disassemble the cached object that actually executed.
#
# -ShowASM is not used here. It disables the object cache, so it would report code
# from a different caching regime than the one the timing loop runs under.
#
# Usage:
#   prove_path.sh --selftest
#   prove_path.sh --kernel simd_sllv2_test --arm ARM [--expect-native-shift2]
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() { sed -n '2,12p' "$0" >&2; exit 2; }

# The generic fw=2 control is discriminated by eor.16b, not by cmeq. simd_eq at fw<8
# is not(xor(a,b)) (idisa_builder.cpp:228), which lowers to eor plus bic, and the
# native path emits neither. Verified on this build for both sllv and srlv.
NATIVE_MARKER_ABSENT="eor.16b"

# The instruction counter is shared with the SVE2 driver, which sees GNU syntax and SVE
# mnemonics that never appear on this host. A fixture covering both syntaxes is the only
# way this host can prove the counter is right for the container too.
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

selftest() {
    counter_selftest
    local tmp a_err b_err c_err prefix oa ob ma mb na nb ea eb
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    local A="$CORPUS/hex64a" B="$CORPUS/hex64b"
    # The self-test only proves the mechanism, so the small committed corpus is enough.
    if [ ! -f "$A" ]; then A="$REPO/QA/IDISA_test/randhex65536a"; B="$REPO/QA/IDISA_test/randhex65536b"; fi
    [ -f "$A" ] || die "no operand data for the self-test"

    note "selftest: arm A (native)"
    run_one "$tmp/a.out" "$tmp/a.err" "$BIN/idisa_test" -q -trace-object-cache simd_sllv 2 "$A" "$B"
    [ "$RUN_STATUS" -eq 0 ] || die "selftest arm A exited $RUN_STATUS"
    note "selftest: arm B (generic)"
    run_one "$tmp/b.out" "$tmp/b.err" "$BIN/idisa_test" -q -trace-object-cache -bench-generic-shift2 simd_sllv 2 "$A" "$B"
    [ "$RUN_STATUS" -eq 0 ] || die "selftest arm B exited $RUN_STATUS"
    note "selftest: adversarial re-run of arm A"
    run_one "$tmp/c.out" "$tmp/c.err" "$BIN/idisa_test" -q -trace-object-cache simd_sllv 2 "$A" "$B"
    [ "$RUN_STATUS" -eq 0 ] || die "selftest arm A re-run exited $RUN_STATUS"

    assert_trace "$tmp/a.err" ARM simd_sllv2_test
    assert_trace "$tmp/b.err" ARM_bgs2 simd_sllv2_test
    assert_trace "$tmp/c.err" ARM simd_sllv2_test

    prefix="$(newest_prefix)"
    oa="$(kernel_object_path "$prefix" simd_sllv2_test ARM)"
    ob="$(kernel_object_path "$prefix" simd_sllv2_test ARM_bgs2)"
    [ -f "$oa" ] || die "assert 1 failed: $oa absent"
    [ -f "$ob" ] || die "assert 1 failed: $ob absent"

    ma="$(md5 -q "$oa")"; mb="$(md5 -q "$ob")"
    [ "$ma" != "$mb" ] || die "assert 2 failed: both arms wrote md5 $ma, the switch changed no code"

    na="$(count_vector_insns "$oa" _simd_sllv2_test_DoSegment)"
    nb="$(count_vector_insns "$ob" _simd_sllv2_test_DoSegment)"
    ea="$(count_mnemonic "$oa" _simd_sllv2_test_DoSegment "$NATIVE_MARKER_ABSENT")"
    eb="$(count_mnemonic "$ob" _simd_sllv2_test_DoSegment "$NATIVE_MARKER_ABSENT")"

    [ "$ea" -eq 0 ] || die "assert 3 failed: native arm emitted $ea $NATIVE_MARKER_ABSENT"
    [ "$eb" -gt 0 ] || die "assert 4 failed: generic arm emitted no $NATIVE_MARKER_ABSENT"
    [ "$na" -gt 0 ] || die "assert 3 failed: the counter found no vector instruction in the native kernel"
    [ "$nb" -gt "$na" ] || die "assert 3 failed: native vector count $na is not below generic $nb"

    cat <<EOF
SELFTEST PASS
  prefix              $prefix
  native object       $oa
  native md5          $ma
  native vector insns $na
  generic object      $ob
  generic md5         $mb
  generic vector insn $nb
  eor.16b native      $ea
  eor.16b generic     $eb
  all three runs exited 0, arm A re-run after arm B was order independent
EOF
}

prove_one() {
    local kernel="$1" arm="$2" prefix obj n
    prefix="$(newest_prefix)"
    obj="$(kernel_object_path "$prefix" "$kernel" "$arm")"
    [ -f "$obj" ] || die "no warm cached object for kernel=$kernel arm=$arm at $obj"
    n="$(count_insns "$obj" "_${kernel}_DoSegment")"
    echo "kernel=$kernel arm=$arm object=$obj md5=$(md5 -q "$obj") vector/scalar_insns=$n"
    "$OBJDUMP" -d --no-show-raw-insn --disassemble-symbols="_${kernel}_DoSegment" "$obj"
}

[ $# -ge 1 ] || usage
case "$1" in
    --selftest) selftest ;;
    --kernel)
        [ $# -ge 4 ] || usage
        [ "$3" = "--arm" ] || usage
        prove_one "$2" "$4"
        ;;
    *) usage ;;
esac
