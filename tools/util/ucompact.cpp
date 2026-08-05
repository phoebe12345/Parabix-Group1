/*
 *  Part of the Parabix Project, under the Open Software License 3.0.
 *  SPDX-License-Identifier: OSL-3.0
 */

#include <kernel/basis/p2s_kernel.h>
#include <kernel/basis/s2p_kernel.h>
#include <kernel/core/streamset.h>
#include <kernel/io/source_kernel.h>
#include <kernel/io/stdout_kernel.h>
#include <kernel/pipeline/driver/cpudriver.h>
#include <kernel/pipeline/program_builder.h>
#include <kernel/streamutils/deletion.h>
#include <kernel/unicode/UCD_property_kernel.h>
#include <kernel/unicode/utf8_decoder.h>
#include <kernel/unicode/utf8_support.h>
#include <re/adt/adt.h>
#include <re/parse/parser.h>
#include <re/transforms/re_simplifier.h>
#include <re/unicode/resolve_properties.h>
#include <toolchain/toolchain.h>
#include <llvm/Support/CommandLine.h>

#include <cerrno>
#include <cstdint>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using namespace llvm;
using namespace codegen;
using namespace kernel;

static cl::OptionCategory ucFlags("Command Flags", "ucompact options");

static cl::opt<std::string> CC_expr(cl::Positional, cl::desc("<Unicode character class expression>"), cl::Required, cl::cat(ucFlags));
static cl::opt<std::string> inputFile(cl::Positional, cl::desc("<input file>"),  cl::cat(ucFlags));
static cl::opt<unsigned> CompressFw("cfw", cl::desc("field width for stream compression (8, 16, 32 or 64)"), cl::init(64), cl::cat(ucFlags));

#define SHOW_STREAM(name) if (codegen::EnableIllustrator) P.captureBitstream(#name, name)
#define SHOW_BIXNUM(name) if (codegen::EnableIllustrator) P.captureBixNum(#name, name)
#define SHOW_BYTES(name) if (codegen::EnableIllustrator) P.captureByteData(#name, name)

using UCompactFunction = void (*)(uint32_t fd);

UCompactFunction pipelineGen(CPUDriver & driver, re::Name * CC_name) {
    auto P = CreatePipeline(driver, Input<uint32_t>{"fileDescriptor"});
    Scalar * const fileDescriptor = P.getInputScalar("fileDescriptor");

    StreamSet * const ByteStream = P.CreateStreamSet(1, 8);
    SHOW_BYTES(ByteStream);
    P.CreateKernelCall<ReadSourceKernel>(fileDescriptor, ByteStream);

    StreamSet * BasisBits = P.CreateStreamSet(8, 1);
    SHOW_BIXNUM(BasisBits);
    P.CreateKernelCall<S2PKernel>(ByteStream, BasisBits);

    StreamSet * CCmask = P.CreateStreamSet(1, 1);
    P.CreateKernelFamilyCall<UnicodePropertyKernelBuilder>(CC_name, BasisBits, CCmask);
    SHOW_STREAM(CCmask);

    StreamSet * u8index = P.CreateStreamSet(1, 1);
    P.CreateKernelCall<UTF8_index>(BasisBits, u8index);
    SHOW_STREAM(u8index);

    StreamSet * CCspans = P.CreateStreamSet(1, 1);
    P.CreateKernelCall<U8Spans>(CCmask, u8index, CCspans);
    SHOW_STREAM(CCspans);

    // Compress the basis streams at the requested field width.
    StreamSet * FilteredBasis = P.CreateStreamSet(8, 1);
    FilterByMask(P, CCspans, BasisBits, FilteredBasis, 0, CompressFw);

    StreamSet * const FilteredBytes = P.CreateStreamSet(1, 8);
    P.CreateKernelCall<P2SKernel>(FilteredBasis, FilteredBytes);

    SHOW_BYTES(FilteredBytes);

    P.CreateKernelCall<StdOutKernel>(FilteredBytes);

    return P.compile();
}

int main(int argc, char *argv[]) {
    codegen::ParseCommandLineOptions(argc, argv, {&ucFlags, &codegen::JIT_InfoOptions, &codegen::InstrumentationOptions});
    if (CompressFw != 8 && CompressFw != 16 && CompressFw != 32 && CompressFw != 64) {
        std::cerr << "ucompact: -cfw must be 8, 16, 32 or 64.\n";
        exit(1);
    }
    CPUDriver driver("ucompact");

    UCompactFunction fnPtr = nullptr;
    re::RE * CC_re = re::simplifyRE(re::RE_Parser::parse(CC_expr));
    CC_re = UCD::linkAndResolve(CC_re);
    CC_re = UCD::externalizeProperties(CC_re);
    if (re::Name * UCD_property_name = dyn_cast<re::Name>(CC_re)) {
        fnPtr = pipelineGen(driver, UCD_property_name);
    } else if (re::CC * CC_ast = dyn_cast<re::CC>(CC_re)) {
        fnPtr = pipelineGen(driver, makeName(CC_ast));
    } else {
        std::cerr << "Input expression must be a Unicode property or CC but found: " << CC_expr << " instead.\n";
        exit(1);
    }

    const int fd = open(inputFile.c_str(), O_RDONLY);
    if (LLVM_UNLIKELY(fd == -1)) {
        if (errno == EACCES) {
            std::cerr << "ucompact: " << inputFile << ": Permission denied.\n";
        }
        else if (errno == ENOENT) {
            std::cerr << "ucompact: " << inputFile << ": No such file.\n";
        }
        else {
            std::cerr << "ucompact: " << inputFile << ": Failed.\n";
        }
        exit(1);
    }
    struct stat sb;
    if (stat(inputFile.c_str(), &sb) == 0 && S_ISDIR(sb.st_mode)) {
        std::cerr << "ucompact: " << inputFile << ": Is a directory.\n";
        close(fd);
        exit(1);
    }

    fnPtr(fd);
    close(fd);
    return 0;
}
