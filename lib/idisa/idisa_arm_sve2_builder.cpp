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
, IDISA_ARM_Builder(C, featureSet, bitBlockWidth, laneWidth) {}

// SVE2 and NEON require distinct object-cache namespaces.
std::string IDISA_ARM_SVE2_Builder::getBuilderUniqueName() {
    return (mBitBlockWidth != 128 ? "ARM_SVE2_" + std::to_string(mBitBlockWidth) : "ARM_SVE2") + benchSuffix();
}

// SVE COMPACT supports 32- and 64-bit elements only. NEON handles fw 8/16.
Value * IDISA_ARM_SVE2_Builder::mvmd_compress(unsigned fw, Value * a, Value * select_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_COMPRESS) && mBitBlockWidth == 128 && (fw == 32 || fw == 64)) {
        const unsigned fieldCount = 128 / fw; // 4 or 2
        Type * elemTy = getIntNTy(fw);
        auto * fixedVecTy = FixedVectorType::get(elemTy, fieldCount);
        auto * fixedPredTy = FixedVectorType::get(getInt1Ty(), fieldCount);
        auto * scalableVecTy = ScalableVectorType::get(elemTy, fieldCount);
        auto * scalablePredTy = ScalableVectorType::get(getInt1Ty(), fieldCount);

        // Test every selection bit in parallel to avoid an InsertElement chain.
        Value * splat = simd_fill(fw, CreateZExtOrTrunc(select_mask, elemTy));
        SmallVector<Constant *, 16> selBits(fieldCount);
        for (unsigned i = 0; i < fieldCount; i++) {
            selBits[i] = ConstantInt::get(elemTy, 1ULL << i);
        }
        Value * selVec = ConstantVector::get(selBits);
        Value * predBits = CreateICmpNE(fwCast(fw, simd_and(splat, selVec)),
                                        ConstantAggregateZero::get(fixedVecTy));

        // COMPACT needs a zero predicate base; extra active lanes would move data.
        // Data lanes outside the fixed vector are inactive and may remain poison.
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
    return IDISA_ARM_Builder::mvmd_compress(fw, a, select_mask);
}

// SVE TBL supports byte elements. Unselected lanes are masked explicitly
// because mvmd_shuffle normalizes out-of-range indexes before gathering.
Value * IDISA_ARM_SVE2_Builder::mvmd_expand(unsigned fw, Value * a, Value * select_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_EXPAND) && mBitBlockWidth == 128 && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        const unsigned fieldCount = 16;
        Type * i8Ty = getInt8Ty();
        auto * fixed16xi8Ty = FixedVectorType::get(i8Ty, fieldCount);
        auto * scalable16xi8Ty = ScalableVectorType::get(i8Ty, 16);

        Value * maskBits = (fw == 8) ? CreateZExtOrTrunc(select_mask, getInt16Ty())
                                      : expandFieldMaskToBytes(select_mask, fw);
        Value * isSelected = byteMaskToLaneMask(maskBits);

        // rank[j] is the number of selected positions before lane j.
        Value * ones = CreateZExt(isSelected, fixed16xi8Ty);
        Value * inclusiveRank = hsimd_partial_sum(8, ones);
        Value * rank = simd_sub(8, inclusiveRank, ones);

        Value * gatherIdx = CreateSelect(isSelected, rank, ConstantAggregateZero::get(fixed16xi8Ty));

        // TBL is lane-local, and only the 16 inserted lanes are extracted.
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

        Value * zeroMask = CreateSExt(isSelected, fixed16xi8Ty);
        return simd_and(gathered, zeroMask);
    }
    return IDISA_ARM_Builder::mvmd_expand(fw, a, select_mask);
}

// Bridge fixed vectors to SVE for the otherwise identical BEXT/BDEP paths.
Value * IDISA_ARM_SVE2_Builder::sveBitPerm(Intrinsic::ID id, unsigned fw, Value * a, Value * mask) {
    const unsigned fieldCount = 128 / fw;
    Type * elemTy = getIntNTy(fw);
    auto * fixedVecTy = FixedVectorType::get(elemTy, fieldCount);
    auto * scalableVecTy = ScalableVectorType::get(elemTy, fieldCount);

    // Both operations are lane-local, so lanes outside the fixed vector stay poison.
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

// SVE BitPerm is optional and supports fields up to 64 bits.
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

Value * IDISA_ARM_SVE2_Builder::simd_pdep(unsigned fw, Value * v, Value * deposit_mask) {
    if (!hasFeature(Feature::BENCH_GENERIC_BITPERM) && hasFeature(Feature::ARM_SVE2_BITPERM) && mBitBlockWidth == 128
        && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        return sveBitPerm(Intrinsic::aarch64_sve_bdep_x, fw, v, deposit_mask);
    }
    return IDISA_Builder::simd_pdep(fw, v, deposit_mask);
}

}
