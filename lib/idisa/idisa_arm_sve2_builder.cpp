#include <idisa/idisa_arm_sve2_builder.h>

using namespace llvm;

namespace IDISA {

IDISA_ARM_SVE2_Builder::IDISA_ARM_SVE2_Builder(LLVMContext & C, const FeatureSet & featureSet, unsigned bitBlockWidth, unsigned laneWidth)
: IDISA_Builder(C, featureSet, ARM_width, bitBlockWidth, laneWidth)
, IDISA_ARM_Builder(C, featureSet, bitBlockWidth, laneWidth) {

}

std::string IDISA_ARM_SVE2_Builder::getBuilderUniqueName() {
    return mBitBlockWidth != 128 ? "ARM_SVE2_" + std::to_string(mBitBlockWidth) : "ARM_SVE2";
}

}