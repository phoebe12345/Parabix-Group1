/*
 *  Part of the Parabix Project, under the Open Software License 3.0.
 *  SPDX-License-Identifier: OSL-3.0
 */

#include <kernel/core/idisa_target.h>

#include <toolchain/toolchain.h>
#include <idisa/idisa_i64_builder.h>
#ifdef PARABIX_ARM_TARGET
#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(16, 0, 0)
#include <llvm/TargetParser/AArch64TargetParser.h>
#endif
#include <idisa/idisa_arm_builder.h>
#include <idisa/idisa_arm_sve2_builder.h>
#endif
#ifdef PARABIX_X86_TARGET
#include <idisa/idisa_sse_builder.h>
#include <idisa/idisa_avx_builder.h>
#endif
#ifdef PARABIX_NVPTX_TARGET
#include <idisa/idisa_nvptx_builder.h>
#endif
#include <llvm/IR/Module.h>

#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(16, 0, 0)
#include <llvm/TargetParser/Triple.h>
#else
#include <llvm/ADT/Triple.h>
#endif

#include <llvm/Support/CommandLine.h>
#include <llvm/Support/ErrorHandling.h>
#include <llvm/Support/raw_ostream.h>
#include <kernel/core/kernel_builder.h>

#include <cstdlib>
#include <cstring>

#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(17, 0, 0)
#include <llvm/TargetParser/Host.h>
#elif LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(11, 0, 0)
#include <llvm/Support/Host.h>
#endif

#define ADD_IF_FOUND(Flag, Value) if (features.lookup(Value)) featureSet.set((size_t)Feature::Flag)

using namespace kernel;
using namespace llvm;

struct Features {
    bool hasAVX;
    bool hasAVX2;
    bool hasAVX512F;
    Features() : hasAVX(0), hasAVX2(0), hasAVX512F(0) { }
};

Features getHostCPUFeatures(const StringMap<bool> & features) {
    Features hostCPUFeatures;
    hostCPUFeatures.hasAVX = features.lookup("avx");
    hostCPUFeatures.hasAVX2 = features.lookup("avx2");
    hostCPUFeatures.hasAVX512F = features.lookup("avx512f");
    return hostCPUFeatures;
}

#ifdef PARABIX_ARM_TARGET
// getHostCPUFeatures changed signature in LLVM 19.
static bool getHostFeatures(StringMap<bool> & features) {
#if LLVM_VERSION_INTEGER < LLVM_VERSION_CODE(19, 0, 0)
    return sys::getHostCPUFeatures(features);
#else
    features = sys::getHostCPUFeatures();
    return !features.empty();
#endif
}

// True if the host CPU model's default extension list contains ext.
static bool cpuModelHasExtension(const char * ext) {
#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(16, 0, 0)
    std::vector<StringRef> extNames;
#if LLVM_VERSION_INTEGER >= LLVM_VERSION_CODE(17, 0, 0)
    auto info = llvm::AArch64::parseCpu(sys::getHostCPUName());
    if (info) {
        llvm::AArch64::getExtensionFeatures(info->Arch.DefaultExts | info->DefaultExtensions, extNames);
    }
#else
    const llvm::AArch64::CpuInfo & info = llvm::AArch64::parseCpu(sys::getHostCPUName());
    llvm::AArch64::getExtensionFeatures(info.Arch.DefaultExts | info.DefaultExtensions, extNames);
#endif
    for (const auto eName : extNames) {
        if (eName == ext) return true;
    }
#endif
    return false;
}

// Darwin needs the CPU-model fallback; QEMU needs the reported feature flags.
static bool armFeatureAvailable(const char * feature, const char * alias, const char * modelExt) {
    StringMap<bool> features;
    if (getHostFeatures(features)
        && (features.lookup(feature) || (alias && features.lookup(alias)))) {
        return true;
    }
    return cpuModelHasExtension(modelExt);
}
#endif

static bool ARM_available() {
#ifdef PARABIX_ARM_TARGET
    return armFeatureAvailable("asimd", "neon", "+neon");
#endif
    return false;
}

static bool SVE2_available() {
#ifdef PARABIX_ARM_TARGET
    return armFeatureAvailable("sve2", nullptr, "+sve2");
#endif
    return false;
}

static bool SVE2_BitPerm_available() {
#ifdef PARABIX_ARM_TARGET
    return armFeatureAvailable("sve2-bitperm", "svebitperm", "+sve2-bitperm");
#endif
    return false;
}

bool AVX2_available() {
    #if LLVM_VERSION_INTEGER < LLVM_VERSION_CODE(19, 0, 0)
    StringMap<bool> features;
    if (LLVM_UNLIKELY(!sys::getHostCPUFeatures(features))) {
        return false;
    }
    #else
    const auto features = sys::getHostCPUFeatures();
    #endif
    return features.lookup("avx2");
}

bool AVX512BW_available() {
    #if LLVM_VERSION_INTEGER < LLVM_VERSION_CODE(19, 0, 0)
    StringMap<bool> features;
    if (LLVM_UNLIKELY(!sys::getHostCPUFeatures(features))) {
        return false;
    }
    #else
    const auto features = sys::getHostCPUFeatures();
    #endif
    return features.lookup("avx512bw");
}

// Benchmark-only switches. Each one turns a single native override off so an A/B can
// measure it against the generic path from one binary. They are folded into the ARM
// builders' unique names, so the two arms never share an object cache entry.
static cl::opt<bool> BenchGenericCompress("bench-generic-compress",
    cl::desc("BENCHMARK ONLY: disable native mvmd_compress; run the generic path."),
    cl::init(false), cl::cat(codegen::CodeGenOptions));

static cl::opt<bool> BenchGenericExpand("bench-generic-expand",
    cl::desc("BENCHMARK ONLY: disable native mvmd_expand; run the generic path."),
    cl::init(false), cl::cat(codegen::CodeGenOptions));

static cl::opt<bool> BenchGenericShift2("bench-generic-shift2",
    cl::desc("BENCHMARK ONLY: disable the fw=2 simd_sllv/simd_srlv override."),
    cl::init(false), cl::cat(codegen::CodeGenOptions));

static cl::opt<bool> BenchGenericShift4("bench-generic-shift4",
    cl::desc("BENCHMARK ONLY: disable the fw=4 simd_sllv/simd_srlv fast path."),
    cl::init(false), cl::cat(codegen::CodeGenOptions));

static cl::opt<bool> BenchGenericBitperm("bench-generic-bitperm",
    cl::desc("BENCHMARK ONLY: disable SVE2 BEXT/BDEP; run the generic simd_pext/simd_pdep."),
    cl::init(false), cl::cat(codegen::CodeGenOptions));

namespace IDISA {

KernelBuilder * GetIDISA_Builder(llvm::LLVMContext & C, const StringMap<bool> & features) {
    IDISA_Builder::FeatureSet featureSet;
    const bool anyBench = BenchGenericCompress || BenchGenericExpand
                        || BenchGenericShift2 || BenchGenericShift4
                        || BenchGenericBitperm;
    // Only the ARM builders fold these bits into getBuilderUniqueName. On any other
    // builder the two arms would share a cache key and serve each other stale kernels.
    auto rejectBenchOptions = [&]() {
        if (LLVM_UNLIKELY(anyBench)) {
            report_fatal_error(StringRef("bench-generic-* options are only valid for the ARM and "
                                         "ARM_SVE2 builders; the selected builder does not encode "
                                         "them in its unique name and would poison the object cache."));
        }
    };
    auto setBenchFeatures = [&]() {
        if (BenchGenericCompress) featureSet.set((size_t)Feature::BENCH_GENERIC_COMPRESS);
        if (BenchGenericExpand)   featureSet.set((size_t)Feature::BENCH_GENERIC_EXPAND);
        if (BenchGenericShift2)   featureSet.set((size_t)Feature::BENCH_GENERIC_SHIFT2);
        if (BenchGenericShift4)   featureSet.set((size_t)Feature::BENCH_GENERIC_SHIFT4);
        if (BenchGenericBitperm)  featureSet.set((size_t)Feature::BENCH_GENERIC_BITPERM);
    };
    if (codegen::BlockSize == 64) {
        rejectBenchOptions();
        return new KernelBuilderImpl<IDISA_I64_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
    }
#ifdef PARABIX_ARM_TARGET
    if (LLVM_LIKELY(codegen::BlockSize == 0)) {  // No BlockSize override: use processor SIMD width
        codegen::BlockSize = 128;
    }
    // User-mode QEMU reports host features, so tests may select a builder directly.
    if (const char * const forced = std::getenv("PARABIX_FORCE_BUILDER")) {
        if (*forced) {
            llvm::errs() << "NOTE: PARABIX_FORCE_BUILDER=" << forced
                         << " overrides CPU detection.\n";
            if (std::strcmp(forced, "ARM_SVE2") == 0) {
                featureSet.set((size_t)Feature::ARM_SVE2);
                // PARABIX_EXTRA_MATTR must also expose BitPerm to LLVM.
                featureSet.set((size_t)Feature::ARM_SVE2_BITPERM);
                setBenchFeatures();
                return new KernelBuilderImpl<IDISA_ARM_SVE2_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
            }
            if (std::strcmp(forced, "ARM") == 0) {
                setBenchFeatures();
                return new KernelBuilderImpl<IDISA_ARM_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
            }
            report_fatal_error(StringRef("PARABIX_FORCE_BUILDER: unknown builder '") + forced
                               + "'; expected ARM or ARM_SVE2");
        }
    }
    if (ARM_available()) {
        if (SVE2_available()) {
            featureSet.set((size_t)Feature::ARM_SVE2);
            if (SVE2_BitPerm_available()) {
                featureSet.set((size_t)Feature::ARM_SVE2_BITPERM);
            }
            setBenchFeatures();
            return new KernelBuilderImpl<IDISA_ARM_SVE2_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
        }
        setBenchFeatures();
        return new KernelBuilderImpl<IDISA_ARM_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
    }
    // NEON is mandatory in ARMv8-A; reaching this path means detection failed.
    llvm::errs() << "WARNING: built for ARM but NEON was not detected. "
                    "Falling back to a non-SIMD builder; ARM code paths will "
                    "not be exercised and timings will not be meaningful.\n";
#endif
    // Every remaining path selects a non-ARM builder, none of which encode the bench bits.
    rejectBenchOptions();
#ifdef PARABIX_X86_TARGET

    const auto HasAVX = features.lookup("avx");
    const auto HasAVX2 = features.lookup("avx2");
    const auto HasAVX512F = features.lookup("avx512f");

    if (LLVM_LIKELY(codegen::BlockSize == 0)) {  // No BlockSize override: use processor SIMD width
        if (LLVM_UNLIKELY(HasAVX512F)) {
            codegen::BlockSize = 512;
        } else if (HasAVX2) {
            codegen::BlockSize = 256;
        } else {
            codegen::BlockSize = 128;
        }
    } else if (((codegen::BlockSize & (codegen::BlockSize - 1)) != 0) || (codegen::BlockSize < 64)) {
        llvm::report_fatal_error("BlockSize must be a power of 2 and >=64");
    }

    if (HasAVX || HasAVX2) {
        ADD_IF_FOUND(AVX_BMI, "bmi");
        ADD_IF_FOUND(AVX_BMI2, "bmi2");
    }
    if (HasAVX512F) {
        ADD_IF_FOUND(AVX512_CD, "avx512cd");
        ADD_IF_FOUND(AVX512_BW, "avx512bw");
        ADD_IF_FOUND(AVX512_DQ, "avx512dq");
        ADD_IF_FOUND(AVX512_VL, "avx512vl");
        // AVX512_VBMI, AVX512_VBMI2 and AVX512_VPOPCNTDQ  have not been tested as we
        //did not have hardware support. It should work in theory (tm)
        ADD_IF_FOUND(AVX512_VBMI, "avx512vbmi");
        ADD_IF_FOUND(AVX512_VBMI2, "avx512vbmi2");
        ADD_IF_FOUND(AVX512_VPOPCNTDQ, "avx512vpopcntdq");
    }
    // AVX512BW builder can only be used for BlockSize multiples of 512
    if (codegen::BlockSize >= 512 && HasAVX512F) {
        return new KernelBuilderImpl<IDISA_AVX512F_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
    }
    if (codegen::BlockSize >= 256) {
        // AVX2 or AVX builders can only be used for BlockSize multiples of 256
        if (HasAVX2) {
            return new KernelBuilderImpl<IDISA_AVX2_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
        } else if (HasAVX) {
            return new KernelBuilderImpl<IDISA_AVX_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
        }
    }
    if (codegen::BlockSize == 128) {
        if (features.lookup("ssse3")) {
            return new KernelBuilderImpl<IDISA_SSSE3_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
        } else {
            return new KernelBuilderImpl<IDISA_SSE2_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
        }
    }
#endif
    llvm::errs() << "BlockSize 64 default!\n";
    codegen::BlockSize = 64;
    return new KernelBuilderImpl<IDISA_I64_Builder>(C, featureSet, codegen::BlockSize, codegen::LaneWidth);
}
#ifdef PARABIX_NVPTX_TARGET
KernelBuilder * GetIDISA_GPU_Builder(llvm::LLVMContext & C) {
    return new KernelBuilderImpl<IDISA_NVPTX20_Builder>(C, 64 * 64, 64);
}
#endif
} 
