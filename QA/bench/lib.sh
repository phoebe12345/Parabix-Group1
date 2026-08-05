#!/usr/bin/env bash
#
# Shared helpers for the ARM/SVE2 benchmark harness. Source this, do not run it.
#
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
BENCH="$REPO/QA/bench"
BUILD="${BUILD:-$REPO/build}"
BIN="$BUILD/bin"
CORPUS="${CORPUS:-$BENCH/corpus}"
RESULTS="${RESULTS:-$BENCH/results}"
OBJCACHE="${OBJCACHE:-$HOME/.parabix/objcache}"
OBJDUMP="${OBJDUMP:-/opt/homebrew/opt/llvm@18/bin/llvm-objdump}"
CLASSIFY="$BENCH/classify_insns.awk"

die() { echo "FATAL: $*" >&2; exit 1; }
note() { echo "[bench] $*" >&2; }

ALL_BENCH_BITS="compress expand shift2 shift4 bitperm"

bench_bit_flag() {
    case "$1" in
        compress) echo -bench-generic-compress ;;
        expand)   echo -bench-generic-expand ;;
        shift2)   echo -bench-generic-shift2 ;;
        shift4)   echo -bench-generic-shift4 ;;
        bitperm)  echo -bench-generic-bitperm ;;
        *) die "unknown bench bit '$1'" ;;
    esac
}

bench_bit_suffix() {
    case "$1" in
        compress) echo _bgc ;;
        expand)   echo _bge ;;
        shift2)   echo _bgs2 ;;
        shift4)   echo _bgs4 ;;
        bitperm)  echo _bgb ;;
        *) die "unknown bench bit '$1'" ;;
    esac
}

# Run without a pipeline and store the exit status in RUN_STATUS.
run_one() {
    local out="$1"; shift
    local err="$1"; shift
    RUN_STATUS=0
    "$@" >"$out" 2>"$err" || RUN_STATUS=$?
    return 0
}

# As run_one, and also sets RUN_NS to the wall time of the subprocess alone.
run_one_timed() {
    local out="$1"; shift
    local err="$1"; shift
    local res
    res="$(python3 "$BENCH/time_run.py" "$out" "$err" "$@")"
    RUN_STATUS="$(printf '%s' "$res" | awk '{print $1}')"
    RUN_NS="$(printf '%s' "$res" | awk '{print $2}')"
    return 0
}

# Three-way classification of a run: ok, signal, wrong_answer, harness_error.
classify_status() {
    local st="$1"
    if [ "$st" -eq 0 ]; then echo ok
    elif [ "$st" -ge 128 ]; then echo signal
    elif [ "$st" -eq 1 ]; then echo wrong_answer
    else echo harness_error
    fi
}

# Emit "items ns pct spread" for every counter row whose NAME column equals $2.
# The counter table goes to stderr. Column 4 is NANOSECONDS on Apple Silicon, never cycles.
parse_counter_rows() {
    local err="$1" name="$2"
    awk -v want="$name" '$2 == want && NF >= 12 { s = (NF >= 14 ? $14 : "0"); print $3, $4, $12, s }' "$err"
}

# Parse the shorter pipeline-total row separately from kernel rows.
parse_pipeline_total_ns() {
    local err="$1" want="$2"
    awk -v w="$want" '$2 == w { print $4; exit }' "$err"
}

# Emit "items ns pct spread" for exactly one expected row. Fails if the row count is not 1.
parse_counter_row() {
    local err="$1" name="$2" rows n
    rows="$(parse_counter_rows "$err" "$name")"
    n="$(printf '%s\n' "$rows" | grep -c . || true)"
    [ "$n" -eq 1 ] || die "expected exactly one counter row named '$name', found $n in $err"
    printf '%s\n' "$rows"
}

# BSD sed has no alternation in basic regex, so -E is required here.
trace_module_ids() {
    sed -nE 's/^(Wrote cache file|Read cache file|Already compiled): (.*)\.kernel$/\2/p' "$1" || true
}

# Require the expected builder suffix and kernel, with no scalar fallback.
assert_trace() {
    local err="$1" armname="$2" kernel="$3" ids bad
    ids="$(trace_module_ids "$err")"
    if [ -z "$ids" ]; then die "no object cache trace lines in $err (was -trace-object-cache passed?)"; fi
    bad="$(printf '%s\n' "$ids" | grep -v "_${armname}\$" || true)"
    if [ -n "$bad" ]; then
        die "trace has module ids not built by arm '$armname': $(printf '%s' "$bad" | tr '\n' ' ')"
    fi
    # _C is the IDISA_I64_Builder unique name; seeing it means the scalar fallback ran.
    if printf '%s\n' "$ids" | grep -qE '_C$'; then die "scalar IDISA_I64_Builder appeared in $err"; fi
    if ! printf '%s\n' "$ids" | grep -qx "${kernel}_${armname}"; then
        die "expected kernel '${kernel}_${armname}' absent from trace in $err"
    fi
    return 0
}

# The set of cache prefixes present, sorted. A new prefix mid-session means someone built.
snapshot_prefixes() {
    ls "$OBJCACHE" 2>/dev/null | grep -E '^[^_]+_' | cut -d_ -f1 | sort -u
}

# Avoid head because pipefail would expose ls receiving SIGPIPE.
newest_prefix() {
    local listing
    listing="$(ls -t "$OBJCACHE" 2>/dev/null || true)"
    printf '%s\n' "$listing" | awk -F_ 'NF > 1 && !seen { print $1; seen = 1 }'
}

md5_of_kernel() {
    local prefix="$1" kernel="$2" armname="$3" f
    f="$OBJCACHE/${prefix}_${kernel}_${armname}.o"
    [ -f "$f" ] || die "cached object missing: $f"
    md5 -q "$f"
}

kernel_object_path() {
    printf '%s/%s_%s_%s.o\n' "$OBJCACHE" "$1" "$2" "$3"
}

# Count vector and scalar instructions using the shared classifier.
count_insns() {
    local obj="$1" sym="$2"
    "$OBJDUMP" -d --no-show-raw-insn --disassemble-symbols="$sym" "$obj" | awk -f "$CLASSIFY"
}

count_vector_insns() { count_insns "$1" "$2" | awk '{print $1}'; }
count_scalar_insns() { count_insns "$1" "$2" | awk '{print $2}'; }

count_mnemonic() {
    local obj="$1" sym="$2" mnem="$3"
    "$OBJDUMP" -d --no-show-raw-insn --disassemble-symbols="$sym" "$obj" \
        | awk '/^[[:space:]]+[0-9a-f]+:/ { print $2 }' \
        | grep -cxF "$mnem" || true
}

# Return the pipeline module id without its builder suffix.
pipeline_module_base() {
    trace_module_ids "$1" | awk '/^P[0-9a-f]{40}_/ { sub(/_[A-Z].*$/, ""); print; exit }'
}

# Resolve the cache prefix from an object touched after the marker.
resolve_prefix_by_touch() {
    local marker="$1" kernel="$2" armname="$3" hit
    hit="$(find "$OBJCACHE" -name "*_${kernel}_${armname}.o" -newer "$marker" -print | sort | awk 'NR==1')"
    [ -n "$hit" ] || return 1
    basename "$hit" | sed -E "s/_${kernel}_${armname}\.o\$//"
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

utc_stamp() { date -u +%Y%m%dT%H%M%SZ; }
