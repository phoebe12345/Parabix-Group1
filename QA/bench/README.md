# ARM and SVE2 benchmark harness

This harness measures the four IDISA operations that this branch adds to the ARM
builder. It compares a native path against the generic path from one binary.

Read this file before you run any script. The rules below stop the harness from
reporting a difference that is not there.

## 1. What the harness measures

The unit is nanoseconds. The `-EnableCycleCounter` column named CYCLES is not a
cycle count on Apple Silicon. It is `mrs CNTVCT_EL0`, measured at 1.000 GHz. Do not
write the word "cycles" in any script, column heading, figure or sentence.

The counter is scaled to 1.000 GHz but it steps in 41.67 ns. A measurement of a few
hundred steps carries visible quantisation. `stats.py` prints a CAUTION when a median
falls below 100 steps, which is 4167 ns. Do not quote decimals from a run that carries
that caution.

## 2. Control mechanism

Each arm runs the same binary. Arm B adds one `-bench-generic-*` option. The option
sets a bit in the builder feature set. The bit turns one native override off, and the
bit also changes `getBuilderUniqueName`.

The name change is the safety property. The object cache key is
`CACHE_PREFIX + kernelName + "_" + getBuilderUniqueName()`. The feature set and the
JIT `-mattr` list are not in the key. A benchmark switch that changed the emitted code
but not the name would let one arm read the other arm's kernel. The two arms have
different names, so they have different cache entries, and each arm reads its own.

The options are:

| Option | Turns off |
|---|---|
| `-bench-generic-compress` | native `mvmd_compress`, NEON and SVE2 |
| `-bench-generic-expand` | native `mvmd_expand`, NEON and SVE2 |
| `-bench-generic-shift2` | the fw=2 `simd_sllv` and `simd_srlv` override |
| `-bench-generic-shift4` | the fw=4 `simd_sllv` and `simd_srlv` fast path |
| `-bench-generic-bitperm` | SVE2 BEXT and BDEP in `simd_pext` and `simd_pdep` |

`-bench-generic-compress` makes SVE2 decline and makes the NEON fallback decline. The
arm then runs the generic path. That bit answers "what does any native compress buy".
It does not answer "what does SVE2 buy over NEON". Use `PARABIX_FORCE_BUILDER` for
that second question. It is a different axis.

A non-ARM builder does not put these bits in its name. `GetIDISA_Builder` stops with a
fatal error if an option is set and the selected builder is not ARM or ARM_SVE2.

### The switches are global to the builder

A bench bit is not scoped to the kernel under test. It can also change the PIPELINE
DRIVER module, which brackets `llvm.readcyclecounter` and supplies the PIPE component
of every counter row in the table. Measured on this build:

| Configuration | timed kernel | pipeline module |
|---|---|---|
| `simd_sllv` fw=2, `-bench-generic-shift2` | differs | identical |
| `u32u8`, `-bench-generic-shift2` | differs | differs |
| `simd_sllv` fw=2, `-bench-generic-bitperm` | identical | differs |

The third row is the danger. A switch that changes zero bytes of the timed kernel can
still move the counter row it is read from, because the pipeline image around it
changed. Every driver therefore proves the pipeline object as well as the kernel
object, writes both md5 values into `path_proof.txt`, and records a structural
signature: `separate-cache-entries,pipeline-identical` or
`separate-cache-entries,pipeline-distinct`.

## 3. Cache lifecycle

A session is one run of one `bench_*.sh` script.

1. Do not delete `~/.parabix/objcache`. Not before a session, not between arms, not
   after. The delete kills a concurrent writer.
2. Do not build during a session. `preflight.sh` takes a lock and stops if a build
   runs, or if any source file under `include/`, `lib/idisa`, `lib/kernel` or
   `tools/idisa_test` is newer than `build/bin/idisa_test`. `include/` is in that list
   because `benchSuffix` and the `Feature` enum live in `include/idisa/idisa_builder.h`.
3. Build once before the session. CMake touches `object_cache.cpp` on every build, and
   that file supplies `CACHE_PREFIX`. A build therefore gives a fresh cache namespace.
   This is the only cache clearing that happens, and it costs nothing.
4. The cache stays on for every macOS timing run. The per-kernel counter brackets
   `DoSegment`, so JIT time is not in any sample.
5. Turn the cache off in two places only: a run with `PARABIX_EXTRA_MATTR` set, and
   every run in the QEMU container. Turn it off for both arms, never for one.
6. Stop `cachejanitord` before a real session. It deletes expired entries on its own
   schedule, and a deleted entry turns a cache read into a JIT compile inside a timed
   run. `preflight.sh` aborts when it is running, and warns instead in smoke mode.

The session records the set of cache prefixes at the start and at the end. The session
also records the md5 of each arm's timed kernel object and of each arm's pipeline
object. If a prefix appears, or an md5 changes, the session is void. Discard all
samples.

## 4. Proof of the executed path

Three layers. All are necessary. A run without all three is not reportable.

Layer 1 runs on every run. Pass `-trace-object-cache`. The harness reads stderr and
checks three things: every module id ends in the arm's builder name, the token `_C`
never appears, and the expected kernel appears. The `_C` check catches the scalar
`IDISA_I64_Builder` fallback for free.

Layer 2 runs once per arm per session. The harness disassembles the cached object that
executed. It does not use `-ShowASM`, because `-ShowASM` turns the cache off and would
report code from a different caching regime.

Layer 3 is the pipeline module. The harness resolves the `P<hash>` module id from the
trace and md5s both arms' pipeline objects. The result is the structural signature in
section 2, and S7 gates on it.

For fw=2 `simd_sllv` and `simd_srlv` the discriminator is `eor.16b`. The native path
emits none. The generic path emits two, because `simd_eq` below fw=8 is
`not(xor(a,b))` (`idisa_builder.cpp:228`). Count vector instructions only.

### One definition of "vector instruction"

`classify_insns.awk` is the only instruction counter in the harness. Both the macOS
drivers and the SVE2 container driver use it, so the two platforms cannot count
different things. It classifies by operand register class, never by a list of
mnemonics: `and`, `orr`, `add`, `sub`, `lsl`, `lsr` and `mov` are scalar mnemonics as
well as vector ones, and an allow-list of those counts loop bookkeeping as vector work.
An instruction is vector when the mnemonic carries a NEON arrangement suffix, or when
any operand names a `v`, `z`, `p` or `q` register. That rule reads Apple syntax
(`and.16b v0, v1, v2`), GNU syntax (`and v0.16b, v1.16b, v2.16b`) and SVE
(`bext z1.d, z0.d, z2.d`, `ptrue p0.b`, `ld1d {z0.d}, p0/z, [x0]`). Vector and scalar
are always reported as two separate numbers.

`prove_path.sh --selftest` and `sve2_icount.sh` both run a fixture through the counter
and assert an exact hand-checked answer before any number is written down.

## 5. Noise floors

There are two different quantities and the harness keeps them apart.

    floor_spread  the p10 to p90 span of the null session's paired ratios. This is how
                  far one paired ratio strays. It does not shrink with N. S2 uses it.
    floor_ci      the bootstrap CI half-width of the null's median ratio. This shrinks
                  as 1/sqrt(N). It is printed and never gated on.

Gating on the CI half-width made S2 easier to pass the more data you collected while
the run to run variability it was supposed to bound did not move. That is fixed.

### A floor belongs to one driver, one input and one quantity

Every null writes `w_null.json` with the floor, the CI half-width, the driver, the
quantity and the sha256 prefix of the input it was measured on. Every measurement run
computes the label it requires and passes it to `stats.py`. S2 fails outright, with the
mismatch printed, when a floor from another driver, another input or another quantity
is supplied. A micro-kernel counter floor can no longer gate a whole-process wall time.

Each driver measures its own floors:

| Driver | keys in `w_null.json` |
|---|---|
| `bench_micro.sh --null` | `counter` |
| `bench_u32u8.sh --null` | `op`, `wall` |
| `bench_density.sh --null` | `counter_fw8`, `counter_fw16`, ... |

### The null arm is discovered, not assumed

An A/A null that runs the identical command line twice shares one object file, one code
layout and one set of addresses between its arms. It contains no information about
whether a shift comes from the code change or from arm B's kernel landing at a
different address.

Each `--null` run therefore probes every other bench bit and picks one that

* leaves every timed kernel byte-identical, and
* reproduces the measured configuration's pipeline signature.

For `simd_sllv` fw=2 that is `-bench-generic-compress`: separate cache entry,
byte-identical kernel, byte-identical pipeline. For `u32u8` it is also
`-bench-generic-compress`: separate cache entry, byte-identical deposit kernels, and a
different pipeline image, which is exactly the structure `-bench-generic-shift2`
produces there. The floor then contains the layout term and, where the measurement has
one, the pipeline-image term.

If no bit reproduces the structure, the driver falls back to the identical command line
and stamps the floor `same-command-line,pipeline-identical`. S7 then fails against a
measured signature of `separate-cache-entries,...`, so the gap can never pass silently.

## 6. When a difference is reportable

A difference is reportable only if all seven conditions hold:

| | Condition |
|---|---|
| S1 | The bootstrap 95% CI on the median ratio excludes 1.0. |
| S2 | `abs(median_r - 1) >= 3 * floor_spread`, and the floor's label matches this configuration's driver, quantity and input. |
| S3 | The exact sign test gives p < 0.01. |
| S4 | Layer 1 and Layer 2 passed for both arms, and the two objects differ by md5. |
| S5 | No wrong-answer run, and the signal death rate is below 0.02. |
| S6 | The session is not void. |
| S7 | The floor's arms differ from each other in the same structural way the measured arms do. |

If any condition fails, write: "No difference resolvable at N=31 with a noise floor of
`floor_spread`". State the floor. Do not report the point estimate as a result.

### Attribution: two numbers, never one

For an end-to-end claim the denominator is the whole process, never the pipeline.

    share of PIPELINE time = measured kernels / the pipeline driver's own counter row
    share of PROCESS  time = measured kernels / the wall time of the whole process

`bench_u32u8.sh` measures both from the same runs of the same timing loop and prints
them side by side with the pipeline-to-process ratio next to them. On the 2 MB smoke
input the two are 0.37 and 0.05, a factor of 7.4. `stats.py` prints
`min resolvable end-to-end effect` only when the scope is `process`, and only from the
process share.

    min_effect_end_to_end = floor_spread / share_of_PROCESS_time

Every `summary.json` carries a `scope` field: `kernel`, `kernel-group`, `process` or
`sweep-point`. A kernel-counter ratio and a whole-process ratio can no longer arrive in
a report wearing the same stamp.

## 7. Design rules

- Sample order is paired and interleaved, never blocked. One pair holds one arm A run
  and one arm B run. The order alternates between pairs.
- The density axis is interleaved too. One repetition visits every density point before
  the next repetition starts.
- Statistics use the paired ratio. The ratio cancels session drift.
- Do not compare across sessions. Drift between sessions minutes apart reaches 7%.
- Report the median and the spread. State N. Never report a bare mean. Never report a
  maximum as a statistic.
- Discard by pair, never by one sample. There is no outlier rejection. A slow run is
  never discarded.
- A signal death discards the pair. A wrong answer stops the session at once.
- `-thread-num=1` is necessary. The default is 2, which sums counts across threads.
- Do not use `-BlockSize=64`. It selects a different scalar builder before any ARM code
  runs. Do not use `-BlockSize=256` for timing. Use it only to read code shape.
- Do not wrap a run in `taskpolicy`. Background policy is about 6 times slower.
- Do not set `PARABIX_EXTRA_MATTR` on macOS. It changes the emitted code and it is not
  in the cache key. `preflight.sh` stops if it is set.
- Do not pass `-object-cache-dir`. It is dead code. See section 10.

## 8. Order of work

    bash QA/bench/prove_path.sh --selftest
    bash QA/bench/make_corpus.sh --micro
    bash QA/bench/bench_micro.sh --null --op simd_sllv --fw 2 --bit shift2
    bash QA/bench/bench_micro.sh --op simd_sllv --fw 2 --bit shift2 \
         --w-null-file <that session>/w_null.json
    bash QA/bench/make_corpus.sh --u32u8
    bash QA/bench/bench_u32u8.sh --null --bit shift2
    bash QA/bench/bench_u32u8.sh --bit shift2 --w-null-file <that session>/w_null.json

Each null must be run before its own measurement, with the same driver and the same
input. There is no shared `<W>` number any more, and no way to pass one.

Steps 1 to 7 give the two numbers that carry the report. Everything after them is
secondary: the rebuild cross-check, `simd_srlv`, the fw=4 configuration, the density
sweep, the SVE2 instruction counts, and `nfc`.

## 9. Smoke mode

Every driver accepts `--smoke`. Smoke mode uses a tiny input and 3 pairs. It exercises
the harness. It is not a measurement. Smoke mode turns the machine-state checks into
warnings, and it stamps `smoke_not_a_measurement: true` in `manifest.json`. Never
report a number from a smoke session.

The smoke corpus lives in `corpus/smoke/`. A small file under a real corpus name would
be picked up by a later real run.

## 10. What this harness cannot show

State these in the report. Items 13 to 17 are the limitations that survived the repair
work described above. They cannot be fixed inside the harness.

1. SVE2 speed, at all. The M4 Pro implements no SVE. Under `qemu-user` the results and
   the instruction counts are correct, but wall time and `CNTVCT_EL0` are meaningless.
   Every SVE2 figure is an instruction count and is labelled as one.
2. CPU cycles. The counter is nanoseconds. A cycle figure would come from a separately
   measured core frequency and must be labelled derived.
3. P-core placement. macOS has no `taskset`. Placement is assumed, not enforced.
4. Thermal state. `pmset -g therm` reports nothing on Apple Silicon. Only Low Power
   Mode is readable.
5. A whole-builder generic baseline. No generic 128-bit ARM builder can be made. Every
   control arm here is per operation.
6. Addition of the shift effects. fw=2 and fw=4 are separate bits and separate
   configurations. Their effects do not add.
7. Anything about `nfd`. It fails on this branch and exits 0 while it writes wrong
   bytes.
8. `icgrep` text throughput. Plain `icgrep` runs none of the four operations. With
   `--colors=always` the operation-bearing kernels see matched lines only, so any
   number depends on match density.
9. `mvmd_compress` or `mvmd_expand` in `u32u8`. `u32u8` does not call them.
10. SVE2 in `nfc`. `nfc` runs compress and expand at fw=8, where SVE COMPACT has no
    encoding and SVE2 delegates to NEON.
11. `idisa_test` wall time. Process startup dominates a warm small run.
12. Cross-machine or cross-compiler generality. One host, one LLVM version, one build
    type.

### 13. The time of an operation, as opposed to the time of a kernel that contains it

`bench_u32u8.sh` sums the counter rows for `u8depositMask`, `FieldDeposit64_3` and
`FieldDeposit64_6`. Those kernels are not the operation. `u8depositMask`
(`lib/kernel/unicode/utf8gen.cpp:57-114`) is about twenty stream loads, long Or and And
chains, six `esimd_merge` calls and eight stores, with `simd_pext` at exactly one call
site inside a four-iteration loop.

The counter brackets a whole `DoSegment`. There is no instrument in this build that
attributes time inside a kernel to one call site, so the harness cannot produce the
operation's own share. Every figure it prints is an UPPER BOUND, it is labelled
"kernels that contain the operation" everywhere it appears, and the scope field says
`kernel-group`, never `operation`. `path_proof.txt` prints the vector and scalar
instruction counts of each kernel next to the md5 so a reader can see how much of each
kernel is not the operation.

Do not write "u32u8 spends X% of its time in simd_pext and simd_pdep". Write "the
kernels that contain simd_pext and simd_pdep hold X% of pipeline time, which is an
upper bound on the operations themselves".

Related: the `--bit` switch that `bench_u32u8.sh` toggles is `-bench-generic-shift2` or
`-bench-generic-shift4`. Those toggle the fw=2 or fw=4 `simd_sllv` and `simd_srlv`
override that the generic pext and pdep are built on. They do not toggle `simd_pext` or
`simd_pdep`. Every heading in the output now names the switch.

### 14. Which part of a difference belongs to the pipeline image

Where the two arms get different pipeline driver objects, the floor measured by
`--null` contains a pipeline-image term of the same shape, so an effect that clears
`3 * floor_spread` is not explained by the pipeline alone. That is a bound, not a
decomposition. The null's pipeline image differs from arm A's in a different way than
the measured arm B's does, and no run can say how much of a surviving difference is
kernel and how much is pipeline. Report the effect against the floor. Do not split it.

### 15. The density floor comes from one density point per width

`bench_density.sh --null` measures one floor per field width, at the first density
point of that width, and every point of that width is gated against it. Each density
point is a different operand file, so a floor measured on one point is not literally a
floor for another. The floor record carries `measured_at_point` and the point is
printed. The instrument, the kernel and the field width are identical across the
points; only the operand bytes differ.

The density axis itself does have a proper floor. A repeat control point re-measures
the first density of each width under a second point id over byte-identical operand
files, inside the same interleaved session, and the sweep refuses to call an arm flat
or data dependent when the density spread is below that repeat spread.

### 16. The rebuild cross-check has no floor of its own

`crosscheck_rebuild.sh` measures the ratio a second way, by deleting the fw=2 override
at source and rebuilding. It proves the path in both binaries, proves that the two
binaries write under different cache prefixes, proves the `eor.16b` discriminator in
each, and aborts when the two trees resolved different LLVM versions. Its verdict is an
overlap test on the two bootstrap intervals.

It does not run a null of the rebuild protocol, so it cannot say how much of any
disagreement is the protocol and how much is the code. Its `stats.py` report prints
NOT REPORTABLE with reason S2 on purpose: the rebuild ratio is a cross-check and never
a result on its own.

### 17. Dynamic instruction counts under QEMU

`sve2_icount.sh` reports static counts from a `-ShowASM` dump. A TCG instruction-count
plugin was not confirmed present in the container image, so no dynamic count is
produced and nothing is substituted for one.

## 11. Found bugs to report upstream

1. `-object-cache-dir` is dead. `lib/toolchain/toolchain.cpp` declares it, parses it and
   stores it in `codegen::ObjectCacheDir`. Nothing reads that variable. The cache path
   is a compile-time absolute string, so a `HOME` override does nothing either.
2. `PARABIX_EXTRA_MATTR` changes the emitted code through `setMAttrs` and is absent
   from the cache key. A run with the variable set can read back a kernel that was
   compiled without those features. The fix is one line: fold the mattr list into
   `getBuilderUniqueName`.
3. Generic `IDISA_Builder::mvmd_expand` crashes at fw=8, fw=16 and fw=32. It works at
   fw=64 only. Two independent routes reach the same result: `-bench-generic-expand`,
   and `-BlockSize=256` with no bench option at all. The second route uses no code from
   this harness, so the defect is upstream and not a benchmark artefact.

       idisa_test -q -BlockSize=256 mvmd_expand 8  <hexA> <hexB>   # status 139, SIGSEGV
       idisa_test -q -BlockSize=256 mvmd_expand 32 <hexA> <hexB>   # status 138, SIGBUS

   The effect on this study is direct: the density sweep for `mvmd_expand` has no
   control arm below fw=64, so `bench_density.sh` checks each width first and records
   the widths it must skip. The sweep for `mvmd_compress` is unaffected and runs at all
   four widths.
4. The `-bench-generic-*` options are not scoped to the operation they name. They change
   the pipeline driver module as well, so a bit that gates nothing in the timed kernel
   still changes the image around it. See section 2. This matters to anyone who adds a
   benchmark switch to this framework.

## Open items

1. The `-bench-generic-*` options appear in `--help` for every tool that links the
   kernel library. Their description says they are for benchmarks only and they default
   to off. Decide before upstreaming whether to hide them behind a build option.
2. The fw=4 gate is in `IDISA_Builder`, which the x86 builders also use. Those builders
   do not put the bench bits in their name. The fatal-error guard stops that
   combination, so no cache damage is possible, but the gate is dead weight for x86.
3. The density axis is a field count, not a percentage. A 128-bit block holds 128/fw
   fields, so fw=64 gives three densities and no more. Requested percentages are mapped
   onto distinct field counts and duplicates are dropped.
