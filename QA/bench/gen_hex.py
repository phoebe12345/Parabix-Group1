#!/usr/bin/env python3
"""Write a deterministic random hex operand file for idisa_test.

idisa_test reads its two operand files as ASCII hex, so one output byte carries
four bits of operand data.

Usage: gen_hex.py BYTES SEED OUT
"""

import random
import sys

CHUNK = 1 << 20


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    nbytes, seed, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    rng = random.Random(seed)
    digits = b"0123456789abcdef"
    written = 0
    with open(out, "wb") as fh:
        while written < nbytes:
            n = min(CHUNK, nbytes - written)
            fh.write(bytes(digits[rng.randrange(16)] for _ in range(n)))
            written += n
    return 0


if __name__ == "__main__":
    sys.exit(main())
