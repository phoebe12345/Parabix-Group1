#!/usr/bin/env python3
"""Field-width-aware density generator for the mvmd_compress/mvmd_expand sweep.

idisa_test derives the select mask with hsimd_signmask(fw, operand2)
(idisa_test.cpp:166,169), so only the sign bit of each fw-wide field of operand2
reaches the operation. At fw=32 that is bytes 3, 7, 11 and 15 of each 128-bit
block, not all 16. Setting k of 16 byte sign bits and calling it a field density
gives a hypergeometric spread instead of the density that was asked for, so this
generator writes sign bits only on the bytes the requested fw actually reads.

Every block gets exactly the same number of selected fields, so the achieved
density is exact per block rather than exact on average.

The density axis is a field count, not a percentage. A 128-bit block holds only
128/fw fields, so at fw=64 there are three possible densities and no more. Asking
for a percentage instead would silently collapse seven requested points onto three
distinct inputs and present the duplicates as a sweep.

Usage: gen_density.py FW K BLOCKS SEED OUT_PREFIX
  K is the number of selected fields per block, 0 to 128/fw inclusive.
Writes OUT_PREFIXa (data) and OUT_PREFIXb (mask source).
"""

import random
import sys


def hex_for_idisa_test(data):
    """HexToBinary reads the low nibble from the first char of each pair."""
    return "".join(format(b & 0xF, "x") + format(b >> 4, "x") for b in data)


def sign_byte_indices(fw):
    """Byte holding the sign bit of each fw-wide field of a little-endian 128-bit block."""
    nfields = 128 // fw
    return [(fw * k + fw - 1) // 8 for k in range(nfields)]


def data_block(rng):
    return bytes(rng.randrange(1, 256) for _ in range(16))


def mask_block(rng, sign_bytes, k):
    selected = set(rng.sample(sign_bytes, k))
    out = bytearray(16)
    for i in range(16):
        low7 = rng.randrange(128)
        top = 0x80 if i in selected else 0x00
        # Bit 7 of a byte the current fw does not read must stay clear, so a
        # misread field width shows up as a wrong answer rather than as noise.
        out[i] = top | low7 if i in sign_bytes else low7
    return bytes(out)


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    fw = int(sys.argv[1])
    k = int(sys.argv[2])
    blocks = int(sys.argv[3])
    seed = int(sys.argv[4])
    prefix = sys.argv[5]

    if fw not in (8, 16, 32, 64):
        print("fw must be one of 8, 16, 32, 64", file=sys.stderr)
        return 2
    sign_bytes = sign_byte_indices(fw)
    nfields = len(sign_bytes)
    if not 0 <= k <= nfields:
        print("k must be between 0 and %d for fw=%d" % (nfields, fw), file=sys.stderr)
        return 2
    density = 100.0 * k / nfields

    rng = random.Random(seed)
    with open(prefix + "a", "w") as fa, open(prefix + "b", "w") as fb:
        for _ in range(blocks):
            fa.write(hex_for_idisa_test(data_block(rng)))
            fb.write(hex_for_idisa_test(mask_block(rng, sign_bytes, k)))

    print("fw=%d k=%d of %d fields density=%.4f%% blocks=%d bytes=%d"
          % (fw, k, nfields, density, blocks, blocks * 32))
    return 0


if __name__ == "__main__":
    sys.exit(main())
