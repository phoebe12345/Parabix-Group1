#!/usr/bin/env bash
#
# Build QA/bench/corpus/. Nothing here is committed; see .gitignore.
#
# nfd input is excluded because the branch does not produce a valid reference output.
#
# Usage:
#   make_corpus.sh --smoke              tiny inputs, seconds, for a harness dry run
#   make_corpus.sh --micro              hex64a and hex64b only (D1 needs just these)
#   make_corpus.sh --u32u8              t160.u32 plus the u32u8 reference output
#   make_corpus.sh --nfc                nfc256.txt
#   make_corpus.sh --density            the D3 density sets
#   make_corpus.sh --all
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

TWAIN="$REPO/QA/TestCorpora/Twain.txt"
SMOKE=0
DO_MICRO=0; DO_U32U8=0; DO_NFC=0; DO_DENSITY=0

HEX_BYTES=$((64 * 1024 * 1024))
U32_SRC_BYTES=$((160 * 1024 * 1024))
NFC_BYTES=$((256 * 1024 * 1024))
DENSITY_BLOCKS=$((1 << 19))
DENSITIES="0 6.25 25 50 75 93.75 100"
FWS="8 16 32 64"

while [ $# -gt 0 ]; do
    case "$1" in
        --smoke)   SMOKE=1; DO_MICRO=1; DO_U32U8=1; DO_NFC=1; DO_DENSITY=1 ;;
        --micro)   DO_MICRO=1 ;;
        --u32u8)   DO_U32U8=1 ;;
        --nfc)     DO_NFC=1 ;;
        --density) DO_DENSITY=1 ;;
        --all)     DO_MICRO=1; DO_U32U8=1; DO_NFC=1; DO_DENSITY=1 ;;
        *) die "unknown argument $1" ;;
    esac
    shift
done
[ $((DO_MICRO + DO_U32U8 + DO_NFC + DO_DENSITY)) -gt 0 ] || die "nothing selected; see --help in the header"

if [ "$SMOKE" -eq 1 ]; then
    HEX_BYTES=$((1024 * 1024))
    U32_SRC_BYTES=$((2 * 1024 * 1024))
    NFC_BYTES=$((2 * 1024 * 1024))
    DENSITY_BLOCKS=$((1 << 12))
    # Keep smoke inputs separate from full-size corpora.
    CORPUS="$CORPUS/smoke"
fi

mkdir -p "$CORPUS"
[ -f "$TWAIN" ] || die "missing $TWAIN"

repeat_to_size() {
    local src="$1" want="$2" dst="$3" have=0 srcsize
    srcsize="$(wc -c < "$src" | tr -d ' ')"
    : > "$dst"
    while [ "$have" -lt "$want" ]; do
        cat "$src" >> "$dst"
        have=$((have + srcsize))
    done
    # Trim so every corpus is an exact size and the sha256 is stable.
    /usr/bin/head -c "$want" "$dst" > "$dst.trim"
    mv "$dst.trim" "$dst"
}

if [ "$DO_MICRO" -eq 1 ]; then
    note "hex operands, $HEX_BYTES bytes each"
    python3 "$BENCH/gen_hex.py" "$HEX_BYTES" 1 "$CORPUS/hex64a"
    python3 "$BENCH/gen_hex.py" "$HEX_BYTES" 2 "$CORPUS/hex64b"
fi

if [ "$DO_U32U8" -eq 1 ]; then
    note "UTF-32LE corpus from $U32_SRC_BYTES bytes of Twain"
    repeat_to_size "$TWAIN" "$U32_SRC_BYTES" "$CORPUS/t160.utf8"
    iconv -f UTF-8 -t UTF-32LE < "$CORPUS/t160.utf8" > "$CORPUS/t160.u32"
    rm -f "$CORPUS/t160.utf8"
    note "u32u8 reference output, produced by the unmodified native path"
    # Use the native path as the byte-for-byte reference for both arms.
    st=0
    "$BIN/u32u8" "$CORPUS/t160.u32" > "$CORPUS/u32u8.reference" 2>"$CORPUS/u32u8.reference.err" || st=$?
    [ "$st" -eq 0 ] || die "u32u8 reference run exited $st, see $CORPUS/u32u8.reference.err"
fi

if [ "$DO_NFC" -eq 1 ]; then
    note "nfc corpus, $NFC_BYTES bytes"
    repeat_to_size "$TWAIN" "$NFC_BYTES" "$CORPUS/nfc256.txt"
    st=0
    "$BIN/nfc" "$CORPUS/nfc256.txt" > "$CORPUS/nfc.reference" 2>"$CORPUS/nfc.reference.err" || st=$?
    [ "$st" -eq 0 ] || die "nfc reference run exited $st, see $CORPUS/nfc.reference.err"
fi

if [ "$DO_DENSITY" -eq 1 ]; then
    mkdir -p "$CORPUS/density"
    : > "$CORPUS/density/achieved.txt"
    for fw in $FWS; do
        # A 128-bit block holds only 128/fw fields, so the requested percentages are
        # mapped onto distinct field counts and duplicates are dropped rather than run.
        ks="$(awk -v fw="$fw" -v ds="$DENSITIES" 'BEGIN {
            n = 128 / fw; c = split(ds, a, " "); out = "";
            for (i = 1; i <= c; i++) { k = int(a[i] / 100.0 * n + 0.5); seen[k] = 1 }
            for (k = 0; k <= n; k++) if (seen[k]) out = out k " ";
            print out }')"
        for k in $ks; do
            tag="$(printf 'fw%s_k%s' "$fw" "$k")"
            note "density set $tag"
            python3 "$BENCH/gen_density.py" "$fw" "$k" "$DENSITY_BLOCKS" 7 \
                "$CORPUS/density/${tag}_" >> "$CORPUS/density/achieved.txt"
        done
    done
fi

note "hashing corpus"
( cd "$CORPUS" && find . -type f ! -name sha256.txt ! -name '*.err' -print0 \
    | xargs -0 shasum -a 256 > sha256.txt )
note "done; see $CORPUS/sha256.txt"
