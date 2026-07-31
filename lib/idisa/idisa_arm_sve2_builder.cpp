#include <idisa/idisa_arm_sve2_builder.h>

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
    return mBitBlockWidth != 128 ? "ARM_SVE2_" + std::to_string(mBitBlockWidth) : "ARM_SVE2";
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
    if (mBitBlockWidth == 128 && (fw == 32 || fw == 64)) {
        const unsigned fieldCount = 128 / fw; // 4 or 2
        Type * elemTy = getIntNTy(fw);
        auto * fixedVecTy = FixedVectorType::get(elemTy, fieldCount);
        auto * fixedPredTy = FixedVectorType::get(getInt1Ty(), fieldCount);
        auto * scalableVecTy = ScalableVectorType::get(elemTy, fieldCount);
        auto * scalablePredTy = ScalableVectorType::get(getInt1Ty(), fieldCount);

        // Build a fixed <fieldCount x i1> predicate, one lane per field,
        // using unrolled scalar bit tests assembled with InsertElement -
        // same technique used elsewhere in this file, chosen to avoid a
        // width-mismatch risk from a single vector-wide op.
        Value * mask = CreateZExtOrTrunc(select_mask, getIntNTy(fieldCount));
        Value * predBits = UndefValue::get(fixedPredTy);
        for (unsigned i = 0; i < fieldCount; i++) {
            Value * bit = CreateAnd(CreateLShr(mask, ConstantInt::get(getIntNTy(fieldCount), i)),
                                     ConstantInt::get(getIntNTy(fieldCount), 1));
            Value * isSet = CreateICmpNE(bit, ConstantInt::get(getIntNTy(fieldCount), 0));
            predBits = CreateInsertElement(predBits, isSet, ConstantInt::get(getInt32Ty(), i));
        }

        // Bridge the fixed-width predicate and data into SVE's scalable
        // types, at the field's real element width this time (not bytes).
        Function * insertPred = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalablePredTy, fixedPredTy});
        Value * scalablePredBase = ConstantAggregateZero::get(scalablePredTy);
        Value * scalablePred = CreateCall(insertPred->getFunctionType(), insertPred,
                                           {scalablePredBase, predBits, getInt64(0)});

        Value * fixedData = fwCast(fw, a);
        Function * insertData = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalableVecTy, fixedVecTy});
        Value * scalableDataBase = ConstantAggregateZero::get(scalableVecTy);
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
// NOTE: as of this writing, this function has not yet been executed on
// real or emulated SVE2 hardware - only mvmd_compress has been tested so
// far. Test this explicitly before treating it as verified.
Value * IDISA_ARM_SVE2_Builder::mvmd_expand(unsigned fw, Value * a, Value * select_mask) {
    if (mBitBlockWidth == 128 && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        const unsigned fieldCount = 16;
        Type * i8Ty = getInt8Ty();
        auto * fixed16xi8Ty = FixedVectorType::get(i8Ty, fieldCount);
        auto * scalable16xi8Ty = ScalableVectorType::get(i8Ty, 16);

        // Per-lane "is output position j selected" boolean, built with
        // scalar bit tests rather than a vector-wide op (see mvmd_compress
        // above for why).
        //
        // fw==8 uses select_mask directly; fw==16/32/64 expand the
        // field-level mask to byte granularity first, same as
        // mvmd_compress above and NEON's own widening.
        Value * maskBits = (fw == 8) ? CreateZExtOrTrunc(select_mask, getInt16Ty())
                                      : expandFieldMaskToBytes(select_mask, fw);
        Value * selectedBytes = UndefValue::get(fixed16xi8Ty);
        for (unsigned i = 0; i < fieldCount; i++) {
            Value * bit = CreateAnd(CreateLShr(maskBits, ConstantInt::get(getInt16Ty(), i)),
                                     ConstantInt::get(getInt16Ty(), 1));
            Value * isSelBit = CreateICmpNE(bit, ConstantInt::get(getInt16Ty(), 0));
            Value * asByte = CreateSExt(isSelBit, i8Ty); // 0xFF or 0x00
            selectedBytes = CreateInsertElement(selectedBytes, asByte, ConstantInt::get(getInt32Ty(), i));
        }
        Value * isSelected = CreateICmpNE(selectedBytes, ConstantAggregateZero::get(fixed16xi8Ty));

        // Exclusive prefix sum: rank[j] = number of selected positions
        // strictly before lane j. hsimd_partial_sum is inherited from the
        // generic IDISA_Builder base (the ARM builder doesn't override it),
        // so this is the exact same call NEON's mvmd_expand makes.
        Value * ones = CreateLShr(selectedBytes, getSplat(fieldCount, getInt8(7)));
        Value * inclusiveRank = hsimd_partial_sum(8, ones);
        Value * rank = simd_sub(8, inclusiveRank, ones);

        // Unselected lanes get an arbitrary in-range index (0) rather than
        // an out-of-range sentinel - see the function comment above for
        // why we don't lean on the gather's out-of-range behaviour here.
        Value * gatherIdx = CreateSelect(isSelected, rank, ConstantAggregateZero::get(fixed16xi8Ty));

        // Bridge data and index into SVE's scalable types, same pattern as
        // mvmd_compress, then gather with SVE's native table-lookup
        // instruction.
        Function * insertData = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalable16xi8Ty, fixed16xi8Ty});
        Value * fixedData = fwCast(8, a);
        Value * scalableDataBase = ConstantAggregateZero::get(scalable16xi8Ty);
        Value * scalableData = CreateCall(insertData->getFunctionType(), insertData,
                                           {scalableDataBase, fixedData, getInt64(0)});

        Value * scalableIdxBase = ConstantAggregateZero::get(scalable16xi8Ty);
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

}