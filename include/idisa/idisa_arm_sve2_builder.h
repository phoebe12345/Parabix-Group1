#pragma once

#include <idisa/idisa_arm_builder.h>

namespace IDISA {
class IDISA_ARM_SVE2_Builder : public IDISA_ARM_Builder {
public:
    IDISA_ARM_SVE2_Builder(llvm::LLVMContext & C, const FeatureSet & featureSet, unsigned bitBlockWidth, unsigned laneWidth);

    std::string getBuilderUniqueName() override;
    llvm::Value * mvmd_compress(unsigned fw, llvm::Value * a, llvm::Value * select_mask) override;
    llvm::Value * mvmd_expand(unsigned fw, llvm::Value * a, llvm::Value * select_mask) override;

    ~IDISA_ARM_SVE2_Builder() override {}
};

}
