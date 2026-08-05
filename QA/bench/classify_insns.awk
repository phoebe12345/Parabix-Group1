# Classify Apple/GNU NEON and SVE assembly by arrangement suffix or vector
# register operands. Output is "VECTOR SCALAR"; mode=list emits each instruction.

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
        # GNU NEON data, SVE data, and SVE predicate registers.
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
