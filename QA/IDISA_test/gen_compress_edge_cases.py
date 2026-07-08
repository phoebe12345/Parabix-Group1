#
# gen_compress_edge_cases.py
#
# Generates two hex-encoded files (same format as randhex65536a/b) but with
# operand2 deliberately chosen so hsimd_signmask produces specific edge-case
# 16-bit masks per block, targeting mvmd_compress's low/high-half boundary -
# the one piece of logic mvmd_expand doesn't have, and the prime suspect for
# the nfc_test regression.
#
# Each 16-byte block of operand2 is built so hsimd_signmask(8, block) equals
# a chosen 16-bit mask: byte i has its high bit set iff mask bit i is set.
#
import codecs

def bytes_for_mask(mask):
    # one byte per bit position; 0x80 if that bit is set (sign bit -> selected),
    # 0x00 otherwise (low, unselected). Low 7 bits are arbitrary padding.
    return bytes((0x80 if (mask >> i) & 1 else 0x00) | 0x0F for i in range(16))

def main():
    masks = []
    masks.append(0x0000)                 # nothing selected
    masks.append(0xFFFF)                 # everything selected
    for i in range(16):
        masks.append(1 << i)             # exactly one bit, at every position 0-15

    # Boundary-focused: sweep every possible split between low half (bits 0-7)
    # and high half (bits 8-15), with every possible countLow/countHigh combo,
    # so every value the shiftIdx combine step can compute gets exercised.
    for countLow in range(0, 9):
        for countHigh in range(0, 9):
            lowMask = (1 << countLow) - 1          # low `countLow` bits set
            highMask = ((1 << countHigh) - 1) << 8 # high `countHigh` bits set
            masks.append(lowMask | highMask)

    # A few adversarial patterns: alternating bits, and bits clustered right
    # at the low/high boundary (bit 7 and bit 8 specifically).
    masks.append(0b0101010101010101)
    masks.append(0b1010101010101010)
    masks.append(1 << 7)                 # last bit of low half only
    masks.append(1 << 8)                 # first bit of high half only
    masks.append((1 << 7) | (1 << 8))    # exactly straddling the boundary

    operand2_bytes = b"".join(bytes_for_mask(m) for m in masks)
    # operand1 payload: doesn't matter for mask correctness, just needs to be
    # non-trivial so we can see which byte landed where. Use a simple ramp
    # repeated per block so each block's bytes are distinguishable (0-15).
    block_count = len(masks)
    operand1_bytes = bytes(range(16)) * block_count

    with open("compress_edge_a", "wb") as f1:
        f1.write(codecs.encode(operand1_bytes, "hex"))
    with open("compress_edge_b", "wb") as f2:
        f2.write(codecs.encode(operand2_bytes, "hex"))

    print(f"Generated {block_count} targeted blocks covering:")
    print("  - all-zero and all-one masks")
    print("  - every single-bit mask (positions 0-15)")
    print("  - every countLow/countHigh combination (0-8 each) = 81 cases")
    print("  - alternating-bit and low/high-boundary-straddling patterns")

if __name__ == "__main__":
    main()
