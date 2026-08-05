#!/usr/bin/env bash
#
# Abort conditions and session manifest. Every bench_*.sh calls this first.
# Takes the build lock, so exactly one session runs at a time.
#
# Usage: preflight.sh SESSION_DIR [--allow-force-builder] [--skip-selftest] [--smoke]
#
# --smoke turns the machine-state checks into warnings so the harness can be exercised
# off AC power. A smoke session is a dry run of the harness, not a measurement, and it
# is stamped as such in manifest.json. Never report a number from one.
#
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SESSION="${1:-}"
[ -n "$SESSION" ] || die "usage: preflight.sh SESSION_DIR [--allow-force-builder] [--skip-selftest] [--smoke]"
shift
ALLOW_FORCE=0
SKIP_SELFTEST=0
SMOKE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-force-builder) ALLOW_FORCE=1 ;;
        --skip-selftest)       SKIP_SELFTEST=1 ;;
        --smoke)               SMOKE=1 ;;
        *) die "preflight: unknown argument $1" ;;
    esac
    shift
done

soft_die() {
    if [ "$SMOKE" -eq 1 ]; then
        note "SMOKE (not a measurement): $*"
    else
        die "$*"
    fi
}

# 1. bash, not zsh. zsh does not populate PIPESTATUS, so a piped exit code would vanish.
[ -n "${BASH_VERSION:-}" ] || die "not running under bash"
case "$-" in *e*) : ;; *) die "set -e is not in effect" ;; esac
case "$-" in *u*) : ;; *) die "set -u is not in effect" ;; esac
[ -o pipefail ] || die "set -o pipefail is not in effect"

# 2. Low Power Mode caps frequency. High Power Mode raises the thermal ceiling instead,
# so it is safe to measure under. Only mode 1 disqualifies. The mode reaches the manifest
# either way, because it is not comparable across modes.
POWERMODE="$(pmset -g 2>/dev/null | awk '$1 == "powermode" { print $2 }' || true)"
case "$POWERMODE" in
    0|2) : ;;
    1) soft_die "powermode is 1 (Low Power Mode); it caps frequency" ;;
    *) soft_die "powermode is '${POWERMODE:-unreadable}', expected 0 or 2" ;;
esac

# 3. AC power.
PS_STATE="$(pmset -g ps 2>/dev/null | head -1 || true)"
case "$PS_STATE" in *"AC Power"*) : ;; *) soft_die "not on AC Power: $PS_STATE" ;; esac

# 4. Environment overrides that change codegen without changing the cache key.
[ -z "${PARABIX_EXTRA_MATTR:-}" ] || die "PARABIX_EXTRA_MATTR is set; it changes codegen and is absent from the cache key"
if [ "$ALLOW_FORCE" -eq 0 ]; then
    [ -z "${PARABIX_FORCE_BUILDER:-}" ] || die "PARABIX_FORCE_BUILDER is set; pass --allow-force-builder for D4 only"
fi

# 5. No build or run in progress in this tree. Match the executable name, not the
# command line. A shell whose command line merely mentions cmake, which is what
# driving this harness from a one-liner produces, is not a build.
BUSY="$(ps -eo pid=,comm= 2>/dev/null \
        | awk '{ n = $2; sub(/^.*\//, "", n);
                 if (n == "make" || n == "cmake" || n == "ninja" || n == "cc1plus") print }' || true)"
[ -z "$BUSY" ] || die "a build is running: $BUSY"
BUSY="$(pgrep -fl "$BIN/" 2>/dev/null | grep -v preflight || true)"
[ -z "$BUSY" ] || die "a parabix binary is already running: $BUSY"
# The janitor's argv holds no path under build/bin, so the check above cannot see it.
# It deletes expired cache entries on its own schedule, which turns a cache read into a
# JIT compile inside a timed run.
JANITOR="$(pgrep -fl cachejanitord 2>/dev/null || true)"
[ -z "$JANITOR" ] || soft_die "cachejanitord is running and can delete cache entries mid-session: $JANITOR"

# 6 and 2 of section 3. The lock is released by the caller's EXIT trap.
LOCK="$BUILD/.bench.lock"
mkdir "$LOCK" 2>/dev/null || die "build lock $LOCK already exists; another session is running or crashed"

# 7. A pending build voids everything, because it would rotate CACHE_PREFIX mid-session.
# include/ is in the list because benchSuffix and the whole Feature enum live in
# include/idisa/idisa_builder.h. That header is the cache-separation mechanism this
# harness rests on, and it is not under lib/. There is no 2>/dev/null here: a path that
# does not exist must fail loudly, not make the whole check vacuous.
[ -x "$BIN/idisa_test" ] || die "missing $BIN/idisa_test"
NEWER="$(find "$REPO/include" "$REPO/lib/idisa" "$REPO/lib/kernel" "$REPO/tools/idisa_test" \
         -type f \( -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) \
         -newer "$BIN/idisa_test" -print)"
[ -z "$NEWER" ] || die "source newer than $BIN/idisa_test, build first: $(printf '%s' "$NEWER" | tr '\n' ' ')"

# 8.
[ -x "$OBJDUMP" ] || die "missing $OBJDUMP"

# 9. Validate the instruction classifier before recording samples.
if [ "$SKIP_SELFTEST" -eq 0 ]; then
    bash "$BENCH/prove_path.sh" --selftest > "$SESSION/selftest.txt" 2>&1 \
        || { cat "$SESSION/selftest.txt" >&2; die "prove_path.sh --selftest failed"; }
fi

mkdir -p "$SESSION"
PREFIXES="$(snapshot_prefixes)"
OBJCACHE_STAMP="$BUILD/lib/objcache/CMakeFiles/objcache.dir/object_cache.cpp.o"
{
    printf '{\n'
    printf '  "utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "git_head": "%s",\n' "$(git -C "$REPO" rev-parse HEAD)"
    printf '  "git_branch": "%s",\n' "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
    printf '  "git_diff_stat": "%s",\n' "$(git -C "$REPO" diff --stat | tr '\n' ';' | sed 's/"/\\"/g')"
    printf '  "git_status_porcelain": "%s",\n' "$(git -C "$REPO" status --porcelain | tr '\n' ';' | sed 's/"/\\"/g')"
    printf '  "uname": "%s",\n' "$(uname -a | sed 's/"/\\"/g')"
    printf '  "hw_model": "%s",\n' "$(sysctl -n hw.model)"
    printf '  "llvm_objdump_version": "%s",\n' "$("$OBJDUMP" --version | awk 'NR==2 {print $0}' | sed 's/"/\\"/g')"
    printf '  "objcache_dir": "%s",\n' "$OBJCACHE"
    printf '  "cache_prefixes": "%s",\n' "$(printf '%s' "$PREFIXES" | tr '\n' ' ')"
    printf '  "newest_cache_prefix": "%s",\n' "$(newest_prefix)"
    printf '  "object_cache_o_mtime": "%s",\n' "$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$OBJCACHE_STAMP" 2>/dev/null || echo unknown)"
    for b in idisa_test u32u8; do
        printf '  "bin_%s": "%s",\n' "$b" \
            "$(stat -f '%Sm %z' -t '%Y-%m-%dT%H:%M:%SZ' "$BIN/$b" 2>/dev/null || echo absent)"
    done
    printf '  "cachejanitord": "%s",\n' "$(printf '%s' "$JANITOR" | tr '\n' ' ' | sed 's/"/\\"/g')"
    printf '  "powermode": "%s",\n' "$POWERMODE"
    printf '  "power_source": "%s",\n' "$(printf '%s' "$PS_STATE" | sed 's/"/\\"/g')"
    printf '  "smoke_not_a_measurement": %s,\n' "$([ "$SMOKE" -eq 1 ] && echo true || echo false)"
    printf '  "corpus_sha256": "%s"\n' "$([ -f "$CORPUS/sha256.txt" ] && shasum -a 256 "$CORPUS/sha256.txt" | awk '{print $1}' || echo absent)"
    printf '}\n'
} > "$SESSION/manifest.json"

printf '%s\n' "$PREFIXES" > "$SESSION/prefixes.before"
note "preflight passed; session $SESSION"
