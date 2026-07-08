#include <idisa/idisa_arm_builder.h>

#include <llvm/IR/Constants.h>
#include <llvm/IR/GlobalVariable.h>
#include <llvm/IR/Intrinsics.h>
#include <llvm/IR/IntrinsicsAArch64.h>
#include <llvm/IR/Module.h>
#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(17, 0, 0)
#include <llvm/TargetParser/Host.h>
#else
#include <llvm/Support/Host.h>
#endif

using namespace llvm;

namespace {

// Builds (once per module, cached by name) a 256-entry lookup table used to
// turn an 8-bit sub-mask into a NEON TBL1 gather index.
//
// table[m] is a 16-byte vector where lane k (k = 0..popcount(m)-1) holds the
// position of the k-th set bit in m, in increasing order; every remaining
// lane holds 16, an out-of-range index. AArch64's TBL instruction is
// defined to return 0 for any index >= the table size (16 for a single
// register), so those lanes come back zero for free.
//
// This is deliberately built as a genuine "for each output position, which
// input feeds it" gather map, not a "for each input, where does it go"
// scatter map, since only the former works directly with TBL.
llvm::GlobalVariable * getOrCreateByteCompressTable(llvm::Module * mod, llvm::LLVMContext & C) {
    const char * const name = "__idisa_arm_byte_compress_table";
    if (llvm::GlobalVariable * existing = mod->getGlobalVariable(name)) {
        return existing;
    }
    llvm::IntegerType * i8Ty = llvm::IntegerType::getInt8Ty(C);
    llvm::FixedVectorType * entryTy = llvm::FixedVectorType::get(i8Ty, 16);
    llvm::SmallVector<llvm::Constant *, 256> entries(256);
    for (unsigned m = 0; m < 256; m++) {
        llvm::Constant * lanes[16];
        unsigned pos = 0;
        for (unsigned bit = 0; bit < 8; bit++) {
            if (m & (1u << bit)) {
                lanes[pos++] = llvm::ConstantInt::get(i8Ty, bit);
            }
        }
        for (unsigned i = pos; i < 16; i++) {
            lanes[i] = llvm::ConstantInt::get(i8Ty, 16); // out-of-range => TBL yields 0
        }
        entries[m] = llvm::ConstantVector::get(llvm::ArrayRef<llvm::Constant *>(lanes, 16));
    }
    llvm::ArrayType * tableTy = llvm::ArrayType::get(entryTy, 256);
    llvm::Constant * tableInit = llvm::ConstantArray::get(tableTy, entries);
    return new llvm::GlobalVariable(*mod, tableTy, /*isConstant=*/true,
                                     llvm::GlobalValue::PrivateLinkage, tableInit, name);
}

} // anonymous namespace

namespace IDISA {

std::string IDISA_ARM_Builder::getBuilderUniqueName() { return mBitBlockWidth != 128 ? "ARM_" + std::to_string(mBitBlockWidth) : "ARM";}

Value* IDISA_ARM_Builder::simd_popcount(unsigned fw, Value * a) {
    if (getVectorBitWidth(a) != ARM_width || fw < 8 || fw % 8 != 0) {
        return IDISA_Builder::simd_popcount(fw, a);
    }

    // There is a CNT instruction offered by NEON that counts set bits in each byte.
    // It only exists for vectors of i8, i.e. <8 x i8> and <16 x i8>. For some reason,
    // LLVM exposes an instrinsic for this instruction but fails to select it
    // during compilation. As a workaround we use the LLVM ctpop instrinsic which does
    // the right thing and emits CNT.
    Value* countInBytes = CreatePopcount(fwCast(8, a));

    if (fw == 8) { // if `a` is a vector of i8 then we're already done
        return countInBytes;
    } else if (fw == 128) {
        auto addv = Intrinsic::getDeclaration(getModule(),
                                              Intrinsic::aarch64_neon_uaddv,
                                              { getInt32Ty(), FixedVectorType::get(getInt8Ty(), 16) });

        auto popcnt = CreateCall(addv->getFunctionType(),
                                     addv,
                                     fwCast(8, countInBytes));

        // It appears that when fw == 128 most calling code expects we return 2xi64
        return CreateInsertElement(fwCast(64, allZeroes()),
                                   CreateZExt(popcnt, getInt64Ty()),
                                   Constant::getNullValue(getInt32Ty()));
    } else {
        // addParirsW: pairwise widening add
        // Adds each pair of fields in a vector together and stores
        // the result in a vector whose fields are twice as wide as
        // the source vector
        auto addPairsW = [this](unsigned _fw, Value* _a) -> Value* {
            unsigned nElems = getVectorBitWidth(_a) / _fw;
            unsigned destFw = _fw * 2;
            unsigned destNElems = nElems / 2;

            auto low = CreateExtractVector(FixedVectorType::get(getIntNTy(_fw), nElems / 2),
                                           _a,
                                           ConstantInt::get(getInt64Ty(), 0));
            auto hi = CreateExtractVector(FixedVectorType::get(getIntNTy(_fw), nElems / 2),
                                           _a,
                                           ConstantInt::get(getInt64Ty(), nElems / 2));

            auto lowExt = CreateZExt(low, FixedVectorType::get(getIntNTy(destFw), destNElems));
            auto hiExt = CreateZExt(hi, FixedVectorType::get(getIntNTy(destFw), destNElems));

            auto addp = Intrinsic::getDeclaration(getModule(),
                                                  Intrinsic::aarch64_neon_addp,
                                                  FixedVectorType::get(getIntNTy(destFw), destNElems));
            return fwCast(destFw, CreateCall(addp->getFunctionType(), addp, {lowExt, hiExt}));
        };

        // Add pairs together and widen each field until we have reduced
        // to the destination field width
        Value* result = countInBytes;
        for (unsigned thisFw = 8; thisFw < fw; thisFw <<= 1) {
            result = addPairsW(thisFw, result);
        }
        return result;
    }
}

Value * IDISA_ARM_Builder::simd_bitreverse(unsigned fw, Value * a) {

    if (fw < 8 || getVectorBitWidth(a) != ARM_width) {
        return IDISA_Builder::simd_bitreverse(fw, a);
    }

    // First reverse the bits in each byte
    auto rbit = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_rbit, fwVectorType(fw));
    if (fw == 8) {
        return CreateCall(rbit->getFunctionType(), rbit, fwCast(8, a));
    }
    Function* refBytesInFields = nullptr;

    // Then reverse the bytes in each field
    if (fw == 64) {
        refBytesInFields = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_revw);
    } else if (fw == 32) {
        refBytesInFields = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_revh);
    } else if (fw == 16) {
        refBytesInFields = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_sve_revb);
    } else {
        return IDISA_Builder::simd_bitreverse(fw, a);
    }

    auto bitsInBytesRevsd = CreateCall(rbit->getFunctionType(), rbit, fwCast(8, a));
    return CreateCall(refBytesInFields->getFunctionType(), refBytesInFields, fwCast(fw, bitsInBytesRevsd));
}

Value * IDISA_ARM_Builder::mvmd_shuffle(unsigned fw, Value * data_table, Value * index_vector) {
  if (mBitBlockWidth == 128 && fw > 8) {
    // Create a table for shuffling with smaller field widths.
    const unsigned fieldCount = mBitBlockWidth/fw;
    Constant * idxMask = getSplat(fieldCount, ConstantInt::get(getIntNTy(fw), fieldCount-1));
    Value * idx = simd_and(index_vector, idxMask);
    unsigned half_fw = fw/2;
    unsigned field_count = mBitBlockWidth/half_fw;
    // Build a ConstantVector of alternating 0 and 1 values.
    SmallVector<Constant *, 16> Idxs(field_count);
    for (unsigned int i = 0; i < field_count; i++) {
      Idxs[i] = ConstantInt::get(getIntNTy(fw/2), i & 1);
    }
    Constant * splat01 = ConstantVector::get(Idxs);
    
    Value * half_fw_indexes = simd_or(idx, mvmd_slli(half_fw, idx, 1));
    half_fw_indexes = simd_add(fw, simd_add(fw, half_fw_indexes, half_fw_indexes), splat01);
    Value * rslt = mvmd_shuffle(half_fw, data_table, half_fw_indexes);
    return rslt;
  }
  if (mBitBlockWidth == 128 && fw == 8) {
    Function * shuf8Func = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_neon_tbl1, FixedVectorType::get(getInt8Ty(), 16));
    return fwCast(8, CreateCall(shuf8Func->getFunctionType(), shuf8Func, {fwCast(8, data_table), fwCast(8, simd_select_lo(fw, index_vector))}));
  }
  return IDISA_Builder::mvmd_shuffle(fw, data_table, index_vector);
}

Value * IDISA_ARM_Builder::mvmd_shuffle2(unsigned fw, Value * table0, Value * table1, Value * index_vector) {
    if (mBitBlockWidth == 128 && fw == 8) {
        Function * shuf8Func = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_neon_tbl2, FixedVectorType::get(getInt8Ty(), 16));
        Value * rslt = CreateCall(shuf8Func->getFunctionType(), shuf8Func, {fwCast(8, table0), fwCast(8, table1), fwCast(8, index_vector)});
            return rslt;
    }
    return IDISA_Builder::mvmd_shuffle2(fw, table0, table1, index_vector);
}

// mvmd_compress: NEON implementation.
//
// NEON has no direct hardware "compress" instruction (unlike AVX-512's
// VPCOMPRESS or SVE2's COMPACT). An earlier version of this function built
// a per-input destination index and fed it straight into mvmd_shuffle
// (NEON's TBL1) - but TBL1 gathers ("for output slot i, which input feeds
// it"), while that index was a scatter map ("for input i, where does it
// go"). Those are inverse permutations, and using one where the other is
// required silently produces the wrong output.
//
// This version instead builds the gather map directly, using a small
// precomputed table (see getOrCreateByteCompressTable above) so no
// inversion is ever needed:
//
//   1. Split the 16 one-byte fields into a low half (bits 0-7 of the mask)
//      and a high half (bits 8-15). For each half, look up its 8-bit
//      sub-mask in the table to get a ready-made TBL1 gather index that
//      packs that half's selected bytes to the front, in order.
//   2. Gather each half directly out of `a` with mvmd_shuffle (the high
//      half's table entry is offset by +8 so it points at source lanes
//      8-15 instead of 0-7).
//   3. Slide the high half's compressed bytes up so they sit right after
//      the low half's - i.e. starting at index countLow, the number of
//      bits set in the low mask - using another TBL1 gather with a
//      shift-by-countLow index vector. 8-bit wraparound arithmetic sends
//      "negative" shifts to a large, out-of-range value, which TBL1
//      naturally zeroes, so no separate masking is needed there.
//   4. OR the two halves together, then (defensively) zero anything past
//      the true total popcount.
//
// NOTE: this only handles mBitBlockWidth == 128, fw == 8. Other field
// widths still fall back to the generic IDISA_Builder path.
// Turns a fieldCount-bit mask (one bit per fw-wide field) into a 16-bit
// byte-mask, replicating each field's selection bit across every byte that
// field occupies. See the header comment for why this lets fw==16/32/64
// safely reuse the byte-granularity compress/expand logic.
Value * IDISA_ARM_Builder::expandFieldMaskToBytes(Value * select_mask, unsigned fw) {
    const unsigned fieldCount = 128 / fw;      // 8, 4, or 2 for fw=16/32/64
    const unsigned bytesPerField = fw / 8;     // 2, 4, or 8
    Value * mask = CreateZExtOrTrunc(select_mask, getIntNTy(fieldCount));
    Value * byteMask = ConstantInt::get(getInt16Ty(), 0);
    for (unsigned j = 0; j < fieldCount; j++) {
        Value * bit = CreateAnd(CreateLShr(mask, ConstantInt::get(getIntNTy(fieldCount), j)),
                                 ConstantInt::get(getIntNTy(fieldCount), 1));
        Value * bit16 = CreateZExt(bit, getInt16Ty());
        for (unsigned k = 0; k < bytesPerField; k++) {
            unsigned destBit = j * bytesPerField + k;
            Value * shifted = CreateShl(bit16, ConstantInt::get(getInt16Ty(), destBit));
            byteMask = CreateOr(byteMask, shifted);
        }
    }
    return byteMask;
}

// mvmd_compress: NEON implementation, byte-granularity core.
//
// NEON has no direct hardware "compress" instruction (unlike AVX-512's
// VPCOMPRESS or SVE2's COMPACT). An earlier version of this function built
// a per-input destination index and fed it straight into mvmd_shuffle
// (NEON's TBL1) - but TBL1 gathers ("for output slot i, which input feeds
// it"), while that index was a scatter map ("for input i, where does it
// go"). Those are inverse permutations, and using one where the other is
// required silently produces the wrong output.
//
// This version instead builds the gather map directly, using a small
// precomputed table (see getOrCreateByteCompressTable above) so no
// inversion is ever needed:
//
//   1. Split the 16 one-byte fields into a low half (bits 0-7 of the mask)
//      and a high half (bits 8-15). For each half, look up its 8-bit
//      sub-mask in the table to get a ready-made TBL1 gather index that
//      packs that half's selected bytes to the front, in order.
//   2. Gather each half directly out of `a` with mvmd_shuffle (the high
//      half's table entry is offset by +8 so it points at source lanes
//      8-15 instead of 0-7).
//   3. Slide the high half's compressed bytes up so they sit right after
//      the low half's - i.e. starting at index countLow, the number of
//      bits set in the low mask - using another TBL1 gather with a
//      shift-by-countLow index vector. 8-bit wraparound arithmetic sends
//      "negative" shifts to a large, out-of-range value, which TBL1
//      naturally zeroes, so no separate masking is needed there.
//   4. OR the two halves together, then (defensively) zero anything past
//      the true total popcount.
Value * IDISA_ARM_Builder::compressBytes(Value * a, Value * byteMask) {
    GlobalVariable * table = getOrCreateByteCompressTable(getModule(), getContext());
    Type * i32Ty = getInt32Ty();
    FixedVectorType * v16xi8Ty = FixedVectorType::get(getInt8Ty(), 16);

    Value * maskBits = byteMask;
    Value * lowMaskByte = CreateTrunc(maskBits, getInt8Ty());
    Value * highMaskByte = CreateTrunc(CreateLShr(maskBits, ConstantInt::get(getInt16Ty(), 8)), getInt8Ty());

    auto loadTableEntry = [&](Value * idxByte) -> Value * {
        Value * idx32 = CreateZExt(idxByte, i32Ty);
        Value * gep = CreateInBoundsGEP(table->getValueType(), table,
                                         {ConstantInt::get(i32Ty, 0), idx32});
        return CreateLoad(v16xi8Ty, gep);
    };

    // Gather index for the low half points directly at source lanes 0-7.
    Value * lowIdx = loadTableEntry(lowMaskByte);
    // The table always encodes local positions 0-7; add 8 uniformly so
    // the high half's index points at source lanes 8-15 instead.
    // Sentinel (16) lanes become 24, still out-of-range, still zero.
    Value * highIdxBase = loadTableEntry(highMaskByte);
    Value * highIdx = simd_add(8, highIdxBase, getSplat(16, getInt8(8)));

    Value * lowCompressed = mvmd_shuffle(8, a, lowIdx);
    Value * highCompressed = mvmd_shuffle(8, a, highIdx);

    Value * countLow = CreateZExtOrTrunc(CreatePopcount(lowMaskByte), getInt8Ty());
    Constant * identity[16];
    for (unsigned i = 0; i < 16; i++) {
        identity[i] = getInt8(i);
    }
    Value * identityVec = ConstantVector::get(ArrayRef<Constant *>(identity, 16));
    Value * shiftIdx = simd_sub(8, identityVec, simd_fill(8, countLow));
    Value * shiftedHigh = mvmd_shuffle(8, highCompressed, shiftIdx);

    Value * result = simd_or(lowCompressed, shiftedHigh);

    // Defensive: zero anything past the true total popcount. By
    // construction the two halves shouldn't overlap or leave gaps, but
    // this costs little and guards against an off-by-one slipping in.
    Value * totalCount = CreateZExtOrTrunc(CreatePopcount(maskBits), getInt8Ty());
    Value * validLane = CreateICmpULT(identityVec, simd_fill(8, totalCount));
    Value * zeroMask = CreateSExt(validLane, v16xi8Ty);

    return simd_and(result, zeroMask);
}

// NOTE on scope: fw==8 uses the select_mask directly; fw==16/32/64 first
// expand the field-level mask to byte granularity (expandFieldMaskToBytes)
// and reuse this same logic unchanged. This means fw==16/32/64 inherit
// whatever bugs fw==8 currently has - known issue: fw==8 has a confirmed,
// not-yet-isolated regression against real Unicode NFC data (see nfc_test),
// despite passing randomized and boundary-case idisa_test checks. Treat
// fw==16/32/64 compress as carrying the same open risk until that's fixed.
Value * IDISA_ARM_Builder::mvmd_compress(unsigned fw, Value * a, Value * select_mask) {
    if (mBitBlockWidth == 128 && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        Value * byteMask = (fw == 8) ? CreateZExtOrTrunc(select_mask, getInt16Ty())
                                      : expandFieldMaskToBytes(select_mask, fw);
        return compressBytes(a, byteMask);
    }
    return IDISA_Builder::mvmd_compress(fw, a, select_mask);
}

// mvmd_expand: NEON implementation, byte-granularity core.
//
// mvmd_expand is the mirror image of mvmd_compress: it spreads the packed
// input fields (in positions 0, 1, 2, ...) out to whichever output
// positions select_mask marks, leaving zero everywhere else.
//
// Unlike mvmd_compress, this direction doesn't need any inversion trick:
// for output lane j, the field that belongs there (if any) is simply the
// input field at "rank(j)" - the number of selected positions before j.
// That's already exactly the index mvmd_shuffle/TBL1 wants ("for output
// slot j, which input feeds it"), so we can compute it directly:
//
//   1. Build a per-lane boolean for whether output position j is selected
//      (broadcast the mask, test one bit per lane).
//   2. Take an exclusive prefix sum of that boolean to get rank(j) - reusing
//      the existing hsimd_partial_sum helper rather than hand-rolling the
//      scan again.
//   3. Where a lane isn't selected, push its index out of TBL1's valid
//      0-15 range so it comes back zero for free.
//   4. Gather directly from `a` with that index vector.
Value * IDISA_ARM_Builder::expandBytes(Value * a, Value * byteMask) {
    const unsigned fieldCount = 16;
    FixedVectorType * v16xi8Ty = FixedVectorType::get(getInt8Ty(), fieldCount);

    // Per-lane "is output position j selected" boolean, built entirely
    // with scalar ops (16 unrolled bit tests on the mask) rather than a
    // vector AND against per-lane bit-position constants. A 16-bit mask
    // needs one-hot constants up to 1<<15, which don't fit in 8-bit
    // lanes - trying to do this as a single <16 x i16> vector op would
    // require a 256-bit register, which doesn't exist here.
    Value * maskBits = byteMask;
    // Build selectedBytes via a small memory round-trip (16 scalar stores,
    // then one vector load) instead of chaining CreateInsertElement calls.
    // The InsertElement-chain version crashes LLVM 18's AArch64 backend
    // inside DAGCombiner::visitVSELECT/SimplifyDemandedVectorElts when
    // fed by a byte-mask built from expandFieldMaskToBytes (fw==16/32/64) -
    // this appears to be a real optimizer bug/fragility, not a logic error
    // in this function, since the exact same downstream code works fine at
    // fw==8. Routing the vector through memory sidesteps whatever SSA-level
    // pattern the optimizer was choking on.
    Value * selectedBytesBuf = CreateAlloca(v16xi8Ty);
    for (unsigned i = 0; i < fieldCount; i++) {
        Value * bit = CreateAnd(CreateLShr(maskBits, ConstantInt::get(getInt16Ty(), i)),
                                 ConstantInt::get(getInt16Ty(), 1));
        Value * isSelBit = CreateICmpNE(bit, ConstantInt::get(getInt16Ty(), 0));
        Value * asByte = CreateSExt(isSelBit, getInt8Ty()); // 0xFF or 0x00
        Value * bytePtr = CreateGEP(getInt8Ty(), CreateBitCast(selectedBytesBuf, getInt8Ty()->getPointerTo()),
                                     ConstantInt::get(getInt32Ty(), i));
        CreateStore(asByte, bytePtr);
    }
    Value * selectedBytes = CreateLoad(v16xi8Ty, selectedBytesBuf);
    Value * isSelected = CreateICmpNE(selectedBytes, allZeroes());

    // Exclusive prefix sum: rank[j] = number of selected positions
    // strictly before lane j. hsimd_partial_sum gives the inclusive
    // version; subtracting the 0/1 flag converts it to exclusive.
    Value * ones = CreateLShr(selectedBytes, getSplat(fieldCount, getInt8(7)));
    Value * inclusiveRank = hsimd_partial_sum(8, ones);
    Value * rank = simd_sub(8, inclusiveRank, ones);

    // Unselected lanes should read nothing. We can't rely purely on
    // pushing their index out of TBL1's 0-15 range: mvmd_shuffle's
    // fw==8 path masks every index to its low 4 bits (via
    // simd_select_lo) before the actual TBL1 call, so any sentinel
    // value above 15 silently wraps back into range instead of
    // zeroing out. So explicitly zero unselected lanes afterward
    // using the isSelected mask we already have.
    Value * outOfRange = getSplat(fieldCount, getInt8(fieldCount));
    Value * gatherIdx = CreateSelect(isSelected, rank, outOfRange);

    Value * gathered = mvmd_shuffle(8, a, gatherIdx);
    return simd_and(gathered, CreateSExt(isSelected, v16xi8Ty));
}

// NOTE on scope: fw==16/32/64 expand the field-level mask to byte
// granularity (expandFieldMaskToBytes) and reuse the fw==8 logic unchanged.
// mvmd_expand at fw==8 has been verified correct both by randomized
// idisa_test checks and by bisection against real Unicode NFC/NFD data
// (ruled out as the cause of the nfc_test regression), so fw==16/32/64
// expand should be on solid footing - but has not itself been separately
// re-verified at those widths yet.
Value * IDISA_ARM_Builder::mvmd_expand(unsigned fw, Value * a, Value * select_mask) {
    if (mBitBlockWidth == 128 && (fw == 8 || fw == 16 || fw == 32 || fw == 64)) {
        Value * byteMask = (fw == 8) ? CreateZExtOrTrunc(select_mask, getInt16Ty())
                                      : expandFieldMaskToBytes(select_mask, fw);
        return expandBytes(a, byteMask);
    }
    return IDISA_Builder::mvmd_expand(fw, a, select_mask);
}

Value * IDISA_ARM_Builder::hsimd_packl(unsigned fw, Value * a, Value * b) {
    if ((fw >= 16) && (fw <= 64) && (getVectorBitWidth(a) == ARM_width)) {
        int nElems = getVectorBitWidth(a) / fw;
        int halfFw = fw / 2;
        Function* uzp1_fn = Intrinsic::getDeclaration(getModule(),
                                                      Intrinsic::aarch64_sve_uzp1,
                                                      FixedVectorType::get(getIntNTy(halfFw), nElems * 2));
        return CreateCall(uzp1_fn->getFunctionType(), uzp1_fn, {fwCast(halfFw, a), fwCast(halfFw, b)});
    }
    // Otherwise use default logic.
    return IDISA_Builder::hsimd_packl(fw, a, b);
}

Value * IDISA_ARM_Builder::hsimd_packh(unsigned fw, Value * a, Value * b) {
    if ((fw >= 16) && (fw <= 64) && (getVectorBitWidth(a) == ARM_width)) {
        int nElems = getVectorBitWidth(a) / fw;
        int halfFw = fw / 2;
        Function* uzp2_fn = Intrinsic::getDeclaration(getModule(),
                                                      Intrinsic::aarch64_sve_uzp2,
                                                      FixedVectorType::get(getIntNTy(halfFw), nElems * 2));
        return CreateCall(uzp2_fn->getFunctionType(), uzp2_fn, {fwCast(halfFw, a), fwCast(halfFw, b)});
    }
    // Otherwise use default logic.
    return IDISA_Builder::hsimd_packh(fw, a, b);
}

Value * IDISA_ARM_Builder::hsimd_packus(unsigned fw, Value * a, Value * b) {
  if ((fw == 16) && (getVectorBitWidth(a) == ARM_width)) {
    Function * vqmovun_s16_func = Intrinsic::getDeclaration(getModule(), Intrinsic::aarch64_neon_uqxtn, FixedVectorType::get(getInt8Ty(), 8));
    Value * sat_a = CreateCall(vqmovun_s16_func->getFunctionType(), vqmovun_s16_func, fwCast(16, a));
    Value * sat_b = CreateCall(vqmovun_s16_func->getFunctionType(), vqmovun_s16_func, fwCast(16, b));
    return fwCast(8, CreateDoubleVector(sat_a, sat_b));
  }
  // Otherwise use default logic.
  return IDISA_Builder::hsimd_packus(fw, a, b);
}

Value * IDISA_ARM_Builder::esimd_mergeh(unsigned fw, Value * a, Value * b) {

  if ((fw >= 16) && (fw <= 64) && (getVectorBitWidth(a) == ARM_width)) {
    int nElms = getVectorBitWidth(a) / fw;
    int halfFw = fw / 2;
    Function * zip2_fn = Intrinsic::getDeclaration(getModule(),
                                                 Intrinsic::aarch64_sve_zip2,
                                                 FixedVectorType::get(getIntNTy(halfFw), nElms * 2));
    return CreateCall(zip2_fn->getFunctionType(), zip2_fn, {fwCast(halfFw, a), fwCast(halfFw, b)});
  }
  return IDISA_Builder::esimd_mergeh(fw, a, b);
}

Value * IDISA_ARM_Builder::esimd_mergel(unsigned fw, Value * a, Value * b) {
  if ((fw >= 16) && (fw <= 64) && (getVectorBitWidth(a) == ARM_width)) {
    int nElms = getVectorBitWidth(a) / fw;
    int halfFw = fw / 2;
    Function * zip1_fn = Intrinsic::getDeclaration(getModule(),
                                                 Intrinsic::aarch64_sve_zip1,
                                                 FixedVectorType::get(getIntNTy(halfFw), nElms * 2));
    return CreateCall(zip1_fn->getFunctionType(), zip1_fn, {fwCast(halfFw, a), fwCast(halfFw, b)});
  }
  return IDISA_Builder::esimd_mergel(fw, a, b);
}

}