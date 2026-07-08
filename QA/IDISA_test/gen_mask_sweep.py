#
# gen_mask_sweep.py
#
# Generates mask_sweep_a (data) and mask_sweep_b (mask source) with one
# 16-byte block per 16-bit mask value, 65536 blocks total. Block i of
# operand2 has hsimd_signmask(8, block) == i, so running mvmd_compress or
# mvmd_expand over the pair exercises every possible byte level mask.
#
# The files are about 2 MB each, so they are generated at test time by
# run_mask_sweep rather than checked in.

def hex_for_idisa_test(data):
    # HexToBinary reads the low nibble from the first char of each pair
    return "".join(format(b & 0xF, "x") + format(b >> 4, "x") for b in data)

def data_block(i):
    # nonzero payload; a gather that leaks a[0] or a[8] only shows if those lanes are nonzero
    return bytes(((i * 31 + j * 97 + 13) % 255) + 1 for j in range(16))

def mask_block(i):
    # sign bit of lane j = bit j of the block index, low 7 bits pseudorandom
    return bytes((((i >> j) & 1) << 7) | ((i * 13 + j * 29 + 5) % 128) for j in range(16))

def main():
    with open("mask_sweep_a", "w") as fa, open("mask_sweep_b", "w") as fb:
        for i in range(65536):
            fa.write(hex_for_idisa_test(data_block(i)))
            fb.write(hex_for_idisa_test(mask_block(i)))
    print("Generated mask_sweep_a and mask_sweep_b: 65536 blocks, all 16-bit masks")

if __name__ == "__main__":
    main()
