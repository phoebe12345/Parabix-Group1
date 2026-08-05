#pragma once

#include <idisa/idisa_arm_builder.h>
#include <llvm/IR/Intrinsics.h>

namespace IDISA {
class IDISA_ARM_SVE2_Builder : public IDISA_ARM_Builder {
public:
    IDISA_ARM_SVE2_Builder(llvm::LLVMContext & C, const FeatureSet & featureSet, unsigned bitBlockWidth, unsigned laneWidth);

    std::string getBuilderUniqueName() override;
    llvm::Value * mvmd_compress(unsigned fw, llvm::Value * a, llvm::Value * select_mask) override;
    llvm::Value * mvmd_expand(unsigned fw, llvm::Value * a, llvm::Value * select_mask) override;
    std::vector<llvm::Value *> simd_pext(unsigned fw, std::vector<llvm::Value *> v, llvm::Value * extract_mask) override;
    llvm::Value * simd_pdep(unsigned fw, llvm::Value * v, llvm::Value * deposit_mask) override;

    ~IDISA_ARM_SVE2_Builder() override {}

protected:
    llvm::Value * sveBitPerm(llvm::Intrinsic::ID id, unsigned fw, llvm::Value * a, llvm::Value * mask);
};

}
