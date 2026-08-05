#include <idisa/idisa_arm_sve2_builder.h>

#include <llvm/ADT/SmallVector.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/Intrinsics.h>
#include <llvm/IR/IntrinsicsAArch64.h>
#include <llvm/IR/Module.h>

using namespace llvm;

namespace IDISA {

IDISA_ARM_SVE2_Builder::IDISA_ARM_SVE2_Builder(LLVMContext & C, const FeatureSet & featureSet, unsigned bitBlockWidth, unsigned laneWidth)
: IDISA_Builder(C, featureSet, ARM_width, bitBlockWidth, laneWidth)
, IDISA_ARM_Builder(C, featureSet, bitBlockWidth, laneWidth) {

}

// Distinct name so JIT-compiled functions from the SVE2 and plain-NEON
// builders never collide, and so it's obvious from generated function names
// (and from object cache entries) which path actually got used.
std::string IDISA_ARM_SVE2_Builder::getBuilderUniqueName() {
    return (mBitBlockWidth != 128 ? "ARM_SVE2_" + std::to_string(mBitBlockWidth) : "ARM_SVE2") + benchSuffix();
}

// mvmd_compress: SVE2 implementation.
//
// IMPORTANT, confirmed against real ARM architecture references: SVE2's
// COMPACT instruction only exists in hardware for 32-bit and 64-bit
// elements. There is no encoding for byte or halfword granularity at all -
// this is a genuine hardware gap, not a software limitation. An earlier
// version of this function called COMPACT at byte granularity
// unconditionally, for every field width, which was architecturally
// invalid across the board; this version calls it at the field's actual
// width for fw=32/64 (where it's valid), and falls back to the
// already-hardware-verified NEON implementation for fw=8/16 (where no
// version of COMPACT can work at all). SVE2 CPUs always implement NEON as
// well, so this fallback is a safe, valid code path, not a workaround.
Value * IDISA_ARM_SVE2_Builder::mvmd_compress(unsigned fw, Value * a, Value * select_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_COMPRESS) && mBitBlockWidth == 128 && (fw == 32 || fw == 64)) {
        const unsigned fieldCount = 128 / fw; // 4 or 2
        Type * elemTy = getIntNTy(fw);
        auto * fixedVecTy = FixedVectorType::get(elemTy, fieldCount);
        auto * fixedPredTy = FixedVectorType::get(getInt1Ty(), fieldCount);
        auto * scalableVecTy = ScalableVectorType::get(elemTy, fieldCount);
        auto * scalablePredTy = ScalableVectorType::get(getInt1Ty(), fieldCount);

        // Build a fixed <fieldCount x i1> predicate, one lane per field.
        // Every lane tests its own bit of a broadcast copy of the mask, so no
        // lane waits on another. The earlier version assembled the vector one
        // lane at a time with InsertElement, which built a dependency chain as
        // long as the field count and lowered to a run of scalar sbfx, ubfx,
        // cset and mov-to-lane instructions. This is the same parallel bit
        // test that IDISA_ARM_Builder::expandFieldMaskToBytes already uses.
        Value * splat = simd_fill(fw, CreateZExtOrTrunc(select_mask, elemTy));
        SmallVector<Constant *, 16> selBits(fieldCount);
        for (unsigned i = 0; i < fieldCount; i++) {
            selBits[i] = ConstantInt::get(elemTy, 1ULL << i);
        }
        Value * selVec = ConstantVector::get(selBits);
        Value * predBits = CreateICmpNE(fwCast(fw, simd_and(splat, selVec)),
                                        ConstantAggregateZero::get(fixedVecTy));

        // Bridge the fixed-width predicate and data into SVE's scalable
        // types, at the field's real element width this time (not bytes).
        //
        // The predicate base must be all-zero. COMPACT packs every active
        // element down to the low lanes, so an active lane above the fixed
        // part would displace a real result. The data base is poison instead:
        // COMPACT never reads an inactive lane, so zeroing the data above the
        // fixed part is work with no effect, and a zero base costs a real SEL.
        Function * insertPred = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalablePredTy, fixedPredTy});
        Value * scalablePredBase = ConstantAggregateZero::get(scalablePredTy);
        Value * scalablePred = CreateCall(insertPred->getFunctionType(), insertPred,
                                           {scalablePredBase, predBits, getInt64(0)});

        Value * fixedData = fwCast(fw, a);
        Function * insertData = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalableVecTy, fixedVecTy});
        Value * scalableDataBase = PoisonValue::get(scalableVecTy);
        Value * scalableData = CreateCall(insertData->getFunctionType(), insertData,
                                           {scalableDataBase, fixedData, getInt64(0)});

        // The actual hardware instruction, now at a valid element width.
        Function * compact = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_compact,
                                                         {scalableVecTy});
        Value * scalableResult = CreateCall(compact->getFunctionType(), compact,
                                             {scalablePred, scalableData});

        Function * extractResult = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_extract,
                                                               {fixedVecTy, scalableVecTy});
        Value * fixedResult = CreateCall(extractResult->getFunctionType(), extractResult,
                                          {scalableResult, getInt64(0)});
        return fwCast(fw, fixedResult);
    }
    // fw == 8 or fw == 16: no hardware encoding for COMPACT exists at
    // this granularity, at all - see note above the function. Fall back
    // to the NEON implementation, already verified correct on real
    // hardware.
    return IDISA_ARM_Builder::mvmd_compress(fw, a, select_mask);
}

// mvmd_expand: SVE2 implementation.
//
// Unlike COMPACT, SVE's table-lookup/gather instruction (TBL) is not
// restricted to 32/64-bit elements - it operates at any element width,
// including bytes, the same as NEON's TBL1. So this design, unlike
// mvmd_compress above, is not affected by the same hardware gap.
//
// The rank computation below (steps building isSelected and rank) is
// identical, fixed-width logic to the already hardware-verified NEON
// mvmd_expand in idisa_arm_builder.cpp - nothing in it is NEON- or
// SVE-specific, so it carries over the same confidence that code earned
// through real testing. Only the final gather step is genuinely new,
// using SVE's own table-lookup instruction (aarch64_sve_tbl, the scalable
// equivalent of NEON's TBL1) instead of going through mvmd_shuffle.
//
// Deliberately NOT relying on an out-of-range sentinel to produce zero
// from the gather this time: unselected lanes get an arbitrary in-range
// index and are masked out explicitly afterward instead. That's a direct
// lesson from the NEON version, where relying on exactly that assumption
// (mvmd_shuffle silently reduces every index mod 16 before gathering)
// caused a real, hard-to-find bug. Building the same assumption into a
// second, untested implementation would be repeating a known mistake.
//
// Executed under emulation on 2026-08-04, all 16-bit masks at fw 8/16/32/64,
// at a 128-bit block width only. Untested above 128 bits.
Value * IDISA_ARM_SVE2_Builder::mvmd_expand(unsigned fw, Value * a, Value * select_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_EXPAND) && mBitBlockWidth == 128 && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        const unsigned fieldCount = 16;
        Type * i8Ty = getInt8Ty();
        auto * fixed16xi8Ty = FixedVectorType::get(i8Ty, fieldCount);
        auto * scalable16xi8Ty = ScalableVectorType::get(i8Ty, 16);

        // fw==8 uses select_mask directly; fw==16/32/64 expand the
        // field-level mask to byte granularity first, same as
        // mvmd_compress above and NEON's own widening.
        Value * maskBits = (fw == 8) ? CreateZExtOrTrunc(select_mask, getInt16Ty())
                                      : expandFieldMaskToBytes(select_mask, fw);
        Value * isSelected = byteMaskToLaneMask(maskBits);

        // Exclusive prefix sum: rank[j] = number of selected positions
        // strictly before lane j. hsimd_partial_sum is inherited from the
        // generic IDISA_Builder base (the ARM builder doesn't override it),
        // so this is the exact same call NEON's mvmd_expand makes.
        Value * ones = CreateZExt(isSelected, fixed16xi8Ty);
        Value * inclusiveRank = hsimd_partial_sum(8, ones);
        Value * rank = simd_sub(8, inclusiveRank, ones);

        // Unselected lanes get an arbitrary in-range index (0) rather than
        // an out-of-range sentinel - see the function comment above for
        // why we don't lean on the gather's out-of-range behaviour here.
        Value * gatherIdx = CreateSelect(isSelected, rank, ConstantAggregateZero::get(fixed16xi8Ty));

        // Bridge data and index into SVE's scalable types, same pattern as
        // mvmd_compress, then gather with SVE's native table-lookup
        // instruction.
        // Both bases are poison, not zero. TBL is elementwise on the index:
        // result lane i reads index lane i, and every index lane below 16 holds
        // a value below 16, so it can only read a table lane the insert defined.
        // Nothing above lane 15 is extracted. A zero base makes the lanes above
        // the fixed part defined, which costs a real SEL for each operand and
        // changes no extracted lane.
        Function * insertData = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalable16xi8Ty, fixed16xi8Ty});
        Value * fixedData = fwCast(8, a);
        Value * scalableDataBase = PoisonValue::get(scalable16xi8Ty);
        Value * scalableData = CreateCall(insertData->getFunctionType(), insertData,
                                           {scalableDataBase, fixedData, getInt64(0)});

        Value * scalableIdxBase = PoisonValue::get(scalable16xi8Ty);
        Value * scalableIdx = CreateCall(insertData->getFunctionType(), insertData,
                                          {scalableIdxBase, gatherIdx, getInt64(0)});

        Function * tbl = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_tbl,
                                                     {scalable16xi8Ty});
        Value * scalableResult = CreateCall(tbl->getFunctionType(), tbl,
                                             {scalableData, scalableIdx});

        Function * extractResult = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_extract,
                                                               {fixed16xi8Ty, scalable16xi8Ty});
        Value * fixedResult = CreateCall(extractResult->getFunctionType(), extractResult,
                                          {scalableResult, getInt64(0)});
        Value * gathered = fwCast(8, fixedResult);

        // Explicit final mask - the safety net this function is built
        // around, rather than an afterthought.
        Value * zeroMask = CreateSExt(isSelected, fixed16xi8Ty);
        return simd_and(gathered, zeroMask);
    }
    return IDISA_ARM_Builder::mvmd_expand(fw, a, select_mask);
}

// Shared bridge for BEXT and BDEP, which differ only in the intrinsic they
// call: widen the fixed 128-bit operands into scalable vectors, apply the
// instruction elementwise, then narrow the result back. Same insert/extract
// pattern as mvmd_compress above.
Value * IDISA_ARM_SVE2_Builder::sveBitPerm(Intrinsic::ID id, unsigned fw, Value * a, Value * mask) {
    const unsigned fieldCount = 128 / fw;
    Type * elemTy = getIntNTy(fw);
    auto * fixedVecTy = FixedVectorType::get(elemTy, fieldCount);
    auto * scalableVecTy = ScalableVectorType::get(elemTy, fieldCount);

    // The base is poison, not zero. BEXT and BDEP are unpredicated and
    // elementwise: result lane i depends on lane i of the two sources and on
    // nothing else, and only the lanes the insert defined are extracted. A
    // zero base makes the lanes above the fixed part defined, which costs a
    // real SEL for each operand and changes no extracted lane.
    Function * insert = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                    {scalableVecTy, fixedVecTy});
    Value * base = PoisonValue::get(scalableVecTy);
    Value * scalableData = CreateCall(insert->getFunctionType(), insert,
                                       {base, fwCast(fw, a), getInt64(0)});
    Value * scalableMask = CreateCall(insert->getFunctionType(), insert,
                                       {base, fwCast(fw, mask), getInt64(0)});

    Function * op = Intrinsic::getDeclaration(getModule(), id, {scalableVecTy});
    Value * scalableResult = CreateCall(op->getFunctionType(), op, {scalableData, scalableMask});

    Function * extractResult = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_extract,
                                                           {fixedVecTy, scalableVecTy});
    Value * fixedResult = CreateCall(extractResult->getFunctionType(), extractResult,
                                      {scalableResult, getInt64(0)});
    return fwCast(fw, fixedResult);
}

// BEXT gathers the bits selected by the mask into the low bits of each element,
// which is what the generic simd_pext computes with a doubling loop of shifts
// and masks, log2(fw) stages deep.
//
// FEAT_SVE_BitPerm is optional on SVE2, so this is gated on its own feature bit
// and not on ARM_SVE2. Field width is limited to the four sizes the instruction
// encodes; callers do reach this with fw=128.
std::vector<Value *> IDISA_ARM_SVE2_Builder::simd_pext(unsigned fw, std::vector<Value *> v, Value * extract_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_BITPERM) && hasFeature(Feature::ARM_SVE2_BITPERM) && mBitBlockWidth == 128
        && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        std::vector<Value *> w(v.size());
        for (unsigned i = 0; i < v.size(); i++) {
            w[i] = sveBitPerm(Intrinsic::aarch64_sve_bext_x, fw, v[i], extract_mask);
        }
        return w;
    }
    return IDISA_Builder::simd_pext(fw, v, extract_mask);
}

// BDEP is the inverse of BEXT and zeroes the unselected bit positions, so the
// trailing mask the generic version applies is not needed here.
Value * IDISA_ARM_SVE2_Builder::simd_pdep(unsigned fw, Value * v, Value * deposit_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_BITPERM) && hasFeature(Feature::ARM_SVE2_BITPERM) && mBitBlockWidth == 128
        && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        return sveBitPerm(Intrinsic::aarch64_sve_bdep_x, fw, v, deposit_mask);
    }
    return IDISA_Builder::simd_pdep(fw, v, deposit_mask);
}

}