# ARM and SVE2 benchmarks

This directory contains the benchmark tools used to evaluate the ARM IDISA work in
this branch. The main comparison is between the native implementation and the generic
fallback in the same binary.

The harness covers:

- `mvmd_compress` and `mvmd_expand`
- `simd_sllv` and `simd_srlv` at field widths 2 and 4
- the SVE2 `simd_pext` and `simd_pdep` paths
- `u32u8` and `nfc` as application-level checks

Results are written under `QA/bench/results/`. The selected submission runs are kept
in `QA/bench/canonical/`.

## Quick start

Build once before starting a timing session. Do not rebuild while a session is in
progress.

```sh
bash QA/bench/prove_path.sh --selftest
bash QA/bench/make_corpus.sh --micro

bash QA/bench/bench_micro.sh --null \
    --op simd_sllv --fw 2 --bit shift2

bash QA/bench/bench_micro.sh \
    --op simd_sllv --fw 2 --bit shift2 \
    --w-null-file QA/bench/results/<null-session>/w_null.json
```

Use `--smoke` for a short test of the harness. Smoke runs use three pairs and are not
valid measurements.

## Benchmark switches

Each switch disables one native path so it can be compared with its generic fallback.

| Option | Disabled path |
|---|---|
| `-bench-generic-compress` | native `mvmd_compress` |
| `-bench-generic-expand` | native `mvmd_expand` |
| `-bench-generic-shift2` | field-width 2 variable shifts |
| `-bench-generic-shift4` | field-width 4 variable shifts |
| `-bench-generic-bitperm` | SVE2 BEXT and BDEP |

The switch is included in the builder name, which gives the two arms separate object
cache entries. The scripts also check the cached object files to confirm that the
expected path ran.

These switches apply to the builder, not just the kernel being timed. A switch can
therefore change the pipeline module as well as the target kernel. Each session records
both objects in `path_proof.txt` and compares the measured run with a null run that has
the same pipeline layout.

## Timing and sampling

The scripts use paired, interleaved samples. The order alternates between native and
generic runs to reduce drift. Statistics are calculated from the ratio within each
pair.

The `CYCLES` field produced by `-EnableCycleCounter` is a timer value on Apple Silicon,
not a CPU cycle count. It uses `CNTVCT_EL0` at 1 GHz and is reported here in
nanoseconds. `stats.py` warns when a sample is too short for that timer resolution.

Each measurement needs a null run from the same driver and input. The null session
writes `w_null.json`, which is passed to the measurement with `--w-null-file`. A floor
from another driver, input, or measurement type is rejected.

Two floor values are recorded:

- `floor_spread` is the p10 to p90 spread of the paired null ratios. It is used by the
  result gate.
- `floor_ci` is the bootstrap confidence interval half-width for the null median. It is
  included for reference.

## Result gates

A result is marked reportable only when all seven checks pass.

| Gate | Check |
|---|---|
| S1 | The 95% bootstrap interval excludes 1.0. |
| S2 | The measured effect is at least three times `floor_spread`. |
| S3 | The exact sign test gives `p < 0.01`. |
| S4 | The trace and cached objects confirm the expected code paths. |
| S5 | Outputs match and fewer than 2% of pairs end in a signal. |
| S6 | The cache prefix and object hashes stay unchanged during the session. |
| S7 | The null and measured pairs have the same cache and pipeline structure. |

The point estimate is still saved when a gate fails, but it is not treated as a
confirmed result.

## Path checks

The harness checks the executed path in three places:

1. `-trace-object-cache` confirms the builder name and expected kernel.
2. The cached kernel object is disassembled and checked for the expected instruction
   pattern.
3. The cached pipeline object is hashed for both arms.

`classify_insns.awk` counts vector instructions from their operands. It handles Apple,
GNU, NEON, and SVE assembly syntax. Run its fixture before collecting results:

```sh
bash QA/bench/prove_path.sh --selftest
```

For field-width 2 shifts, the generic path contains two `eor.16b` instructions and the
native path contains none. This is used as the path discriminator.

## Drivers

| File | Purpose |
|---|---|
| `bench_micro.sh` | Microbenchmarks for shifts and other IDISA operations |
| `bench_density.sh` | Compress and expand tests across mask densities |
| `bench_u32u8.sh` | End-to-end `u32u8` test with kernel attribution |
| `bench_wall.py` | Whole-process wall-time test for tools such as `nfc` |
| `crosscheck_rebuild.sh` | Rebuild-based check of the field-width 2 shift result |
| `sve2_icount.sh` | Static SVE2 instruction counts under QEMU |
| `make_corpus.sh` | Reproducible benchmark inputs |
| `preflight.sh` | Build, cache, and machine-state checks |
| `stats.py` | Paired statistics and result gates |

Typical commands:

```sh
# u32u8
bash QA/bench/make_corpus.sh --u32u8
bash QA/bench/bench_u32u8.sh --null --bit shift2
bash QA/bench/bench_u32u8.sh --bit shift2 \
    --w-null-file QA/bench/results/<null-session>/w_null.json

# compress density sweep
bash QA/bench/bench_density.sh --null --op mvmd_compress
bash QA/bench/bench_density.sh --op mvmd_compress \
    --w-null-file QA/bench/results/<null-session>/w_null.json

# whole-process nfc timing
python3 QA/bench/bench_wall.py --bit compress --pairs 31 \
    build/bin/nfc QA/bench/corpus/nfc/<input>
```

## Cache rules

- Leave `~/.parabix/objcache` in place during a session.
- Build before the session, not during it. A build creates a new cache prefix.
- Keep the cache enabled for macOS timing runs.
- Disable it for QEMU runs and runs using `PARABIX_EXTRA_MATTR`.
- Stop `cachejanitord` before a full measurement.
- Do not set `PARABIX_EXTRA_MATTR` for macOS measurements.
- Do not pass `-object-cache-dir`; the current toolchain does not use it.

`preflight.sh` checks these conditions and records the repository and machine state in
the session manifest.

## Reading application results

`bench_u32u8.sh` reports both the share of pipeline time and the share of whole-process
time for kernels containing the operation. This is an upper bound on the operation
itself because the counter surrounds the full kernel segment.

The `u32u8` switch controls the field-width 2 or 4 shift implementation used to build
generic pext and pdep. It does not directly disable `simd_pext` or `simd_pdep`.

`bench_wall.py` measures the complete process. Its manifest includes the input SHA-256,
git state, raw paired samples, path proof, and summary.

## Limits

- The test machine does not support SVE2. SVE2 runs under QEMU are used for correctness
  and static instruction counts only.
- The timer does not provide CPU cycle counts.
- macOS does not provide CPU pinning comparable to `taskset`.
- Thermal state cannot be fully controlled or recorded on Apple Silicon.
- Controls are per operation. There is no generic 128-bit ARM builder baseline.
- Results from separate sessions are not combined because session drift can be larger
  than the measured effects.
- `u32u8` does not call `mvmd_compress` or `mvmd_expand`.
- `nfc` uses compress and expand at field width 8, so its SVE2 path delegates to NEON.
- Static QEMU counts do not show dynamic instruction frequency.
- Results apply to the tested host, compiler, input, and build configuration.

## Known issues

- `-object-cache-dir` is parsed but not used by the object cache.
- `PARABIX_EXTRA_MATTR` affects generated code but is not part of the cache key.
- Generic `mvmd_expand` fails below field width 64, so those density rows are skipped.
- Benchmark switches may also change the pipeline driver module.
- The field-width 4 gate lives in the generic builder, although it is intended for the
  ARM benchmark path.

See `QA/bench/canonical/README.md` for the submitted sessions and their status.
