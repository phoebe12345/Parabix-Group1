# One definition of "vector instruction" for the whole harness.
#
# It reads either llvm-objdump output or a -ShowASM dump, in either Apple syntax
# (add.16b v0, v1, v2) or GNU syntax (add v0.16b, v1.16b, v2.16b), and it covers both
# NEON and SVE. Classification is by operand register class, not by a list of mnemonics:
# and, orr, add, sub, lsl, lsr and mov are all scalar mnemonics as well as vector ones,
# so any allow-list of mnemonics counts loop bookkeeping as vector work.
#
# An instruction counts as vector when the mnemonic carries a NEON arrangement suffix,
# or when any operand names a v, z, p or q register. The q form is included because
# "ldr q1, [x9]" is a 128 bit vector transfer; leaving it out undercounts NEON against
# SVE, whose equivalent ld1b names a z register and would be counted. The scalar float
# forms d, s, h and b are not counted, because those registers are also plain scalar
# floating point and this code emits none.
#
# Output: "VECTOR SCALAR". With -v mode=list it prints "class mnemonic" per instruction.

function strip_comment(s) {
    sub(/\/\/.*$/, "", s)
    sub(/;.*$/, "", s)
    return s
}

{
    line = strip_comment($0)
    gsub(/^[ \t]+/, "", line)
    gsub(/[ \t]+$/, "", line)
    if (line == "") next
    if (substr(line, 1, 1) == ".") next          # assembler directive
    sub(/^[0-9a-f]+:[ \t]*/, "", line)           # llvm-objdump address column
    if (line == "") next
    if (line ~ /^[0-9a-f]{8,}[ \t]+</) next      # objdump symbol header
    if (line ~ /^Disassembly of section/) next
    if (line ~ /^[^ \t]+:$/) next                # label on its own line

    split(line, part, /[ \t]+/)
    mnem = part[1]
    if (mnem ~ /:$/) next                        # label followed by something else
    if (mnem == "") next

    operands = line
    sub(/^[^ \t]+[ \t]*/, "", operands)

    isvec = 0
    # Apple syntax puts the NEON arrangement on the mnemonic: add.16b v0, v1, v2
    if (mnem ~ /\.(8b|16b|4h|8h|2s|4s|1d|2d)$/) isvec = 1

    if (!isvec) {
        # GNU NEON, all SVE data registers, and SVE predicate registers. No general
        # purpose register is named v, z or p, so a digit after one of those letters
        # is an unambiguous vector operand.
        norm = operands
        gsub(/[{}\[\],\/!]/, " ", norm)
        n = split(norm, tok, /[ \t]+/)
        for (i = 1; i <= n; i++) {
            if (tok[i] ~ /^[vzpq][0-9]+/) { isvec = 1; break }
        }
    }

    if (isvec) vec++; else scal++
    if (mode == "list") printf "%s %s\n", (isvec ? "vector" : "scalar"), mnem
}

END {
    if (mode != "list") printf "%d %d\n", vec + 0, scal + 0
}
