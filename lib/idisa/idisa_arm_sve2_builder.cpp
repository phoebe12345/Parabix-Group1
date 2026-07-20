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

std::string IDISA_ARM_SVE2_Builder::getBuilderUniqueName() {
    return mBitBlockWidth != 128 ? "ARM_SVE2_" + std::to_string(mBitBlockWidth) : "ARM_SVE2";
}

Value * IDISA_ARM_SVE2_Builder::mvmd_compress(unsigned fw, Value * a, Value * select_mask) {
    if (mBitBlockWidth == 128 && fw == 8) {
        Type * i1Ty = getInt1Ty();
        Type * i8Ty = getInt8Ty();
        auto * fixed16xi8Ty = FixedVectorType::get(i8Ty, 16);
        auto * fixed16xi1Ty = FixedVectorType::get(i1Ty, 16);
        auto * scalable16xi8Ty = ScalableVectorType::get(i8Ty, 16);
        auto * scalable16xi1Ty = ScalableVectorType::get(i1Ty, 16);

        Value * maskBits = CreateZExtOrTrunc(select_mask, getInt16Ty());
        Value * predBits = UndefValue::get(fixed16xi1Ty);
        for (unsigned i = 0; i < 16; i++) {
            Value * bit = CreateAnd(CreateLShr(maskBits, ConstantInt::get(getInt16Ty(), i)),
                                     ConstantInt::get(getInt16Ty(), 1));
            Value * isSet = CreateICmpNE(bit, ConstantInt::get(getInt16Ty(), 0));
            predBits = CreateInsertElement(predBits, isSet, ConstantInt::get(getInt32Ty(), i));
        }

        Function * insertPred = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalable16xi1Ty, fixed16xi1Ty});
        Value * scalablePredBase = ConstantAggregateZero::get(scalable16xi1Ty);
        Value * scalablePred = CreateCall(insertPred->getFunctionType(), insertPred,
                                           {scalablePredBase, predBits, getInt64(0)});

        Function * insertData = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_insert,
                                                            {scalable16xi8Ty, fixed16xi8Ty});
        Value * fixedData = fwCast(8, a); // <16 x i8>, the block's byte view
        Value * scalableDataBase = ConstantAggregateZero::get(scalable16xi8Ty);
        Value * scalableData = CreateCall(insertData->getFunctionType(), insertData,
                                           {scalableDataBase, fixedData, getInt64(0)});

        Function * compact = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_compact,
                                                         {scalable16xi8Ty});
        Value * scalableResult = CreateCall(compact->getFunctionType(), compact,
                                             {scalablePred, scalableData});

        // Extract the low 16 lanes back into our fixed-width representation.
        Function * extractResult = Intrinsic::getDeclaration(getModule(), Intrinsic::vector_extract,
                                                               {fixed16xi8Ty, scalable16xi8Ty});
        Value * fixedResult = CreateCall(extractResult->getFunctionType(), extractResult,
                                          {scalableResult, getInt64(0)});
        return fwCast(8, fixedResult);
    }
    return IDISA_ARM_Builder::mvmd_compress(fw, a, select_mask);
}

Value * IDISA_ARM_SVE2_Builder::mvmd_expand(unsigned fw, Value * a, Value * select_mask) {
    if (mBitBlockWidth == 128 && fw == 8) {
        const unsigned fieldCount = 16;
        Type * i8Ty = getInt8Ty();
        auto * fixed16xi8Ty = FixedVectorType::get(i8Ty, fieldCount);
        auto * scalable16xi8Ty = ScalableVectorType::get(i8Ty, 16);

        Value * maskBits = CreateZExtOrTrunc(select_mask, getInt16Ty());
        Value * selectedBytes = UndefValue::get(fixed16xi8Ty);
        for (unsigned i = 0; i < fieldCount; i++) {
            Value * bit = CreateAnd(CreateLShr(maskBits, ConstantInt::get(getInt16Ty(), i)),
                                     ConstantInt::get(getInt16Ty(), 1));
            Value * isSelBit = CreateICmpNE(bit, ConstantInt::get(getInt16Ty(), 0));
            Value * asByte = CreateSExt(isSelBit, i8Ty); // 0xFF or 0x00
            selectedBytes = CreateInsertElement(selectedBytes, asByte, ConstantInt::get(getInt32Ty(), i));
        }
        Value * isSelected = CreateICmpNE(selectedBytes, ConstantAggregateZero::get(fixed16xi8Ty));

        Value * ones = CreateLShr(selectedBytes, getSplat(fieldCount, getInt8(7)));
        Value * inclusiveRank = hsimd_partial_sum(8, ones);
        Value * rank = simd_sub(8, inclusiveRank, ones);

        Value * gatherIdx = CreateSelect(isSelected, rank, ConstantAggregateZero::get(fixed16xi8Ty));

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

        Value * zeroMask = CreateSExt(isSelected, fixed16xi8Ty);
        return simd_and(gathered, zeroMask);
    }
    return IDISA_ARM_Builder::mvmd_expand(fw, a, select_mask);
}

}