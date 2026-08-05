# Linux arm64 environment for exercising the SVE2 builder.
#
# Ubuntu 24.04 carries LLVM 18, Boost, Z3 and qemu-user in its default repos,
# so no third-party apt sources are needed.
#
# The container runs at native speed on Apple Silicon. Only the binary under
# test is emulated, by qemu-user, which is far cheaper than emulating a whole
# machine.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        python3 \
        llvm-18-dev \
        llvm-18-tools \
        clang-18 \
        libboost-filesystem-dev \
        libboost-iostreams-dev \
        libboost-regex-dev \
        libz3-dev \
        z3 \
        qemu-user \
        # LLVM 18's exported cmake targets reference these; without them the
        # find_package(LLVM) step fails on a missing ZLIB::ZLIB target.
        zlib1g-dev \
        libzstd-dev \
        libedit-dev \
        libcurl4-openssl-dev \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

ENV LLVM_DIR=/usr/lib/llvm-18/lib/cmake/llvm

WORKDIR /src
