#pragma once

#include <idisa/idisa_arm_builder.h>

namespace IDISA {

// SVE2-capable ARM builder.
//
// This is a part of Phase 3: for now it inherits every NEON implementation
// from IDISA_ARM_Builder, so functionally it behaves exactly like
// the plain NEON builder. right now is just to exist as a
//  separately selectable class 

class IDISA_ARM_SVE2_Builder : public IDISA_ARM_Builder {
public:
    IDISA_ARM_SVE2_Builder(llvm::LLVMContext & C, const FeatureSet & featureSet, unsigned bitBlockWidth, unsigned laneWidth);

    std::string getBuilderUniqueName() override;

    ~IDISA_ARM_SVE2_Builder() override {}
};

}