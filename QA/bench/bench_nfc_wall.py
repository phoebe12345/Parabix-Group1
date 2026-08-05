#!/usr/bin/env python3
"""Certified-style macro A/B for nfc: whole-process wall time, scope=process.

Follows the QA/bench discipline: discovered null bit with structural signature
match, paired interleaved sampling, bootstrap CI, exact sign test, 3x-floor gate,
path proof by object md5, output equality, cache-prefix void check.
"""
import subprocess, time, statistics, sys, os, hashlib, random, math, json

REPO = "/Users/manvir/sfu/479summer2026/Parabix-Group1"
NFC = f"{REPO}/build/bin/nfc"
OBJCACHE = os.path.expanduser("~/.parabix/objcache")
INP = sys.argv[1]
PAIRS = 31
WARMUP = 3
MEASURE = "-bench-generic-compress"
CANDIDATES = ["-bench-generic-bitperm", "-bench-generic-shift4", "-bench-generic-shift2"]
SUFFIX = {"": "_ARM", "-bench-generic-compress": "_ARM_bgc",
          "-bench-generic-bitperm": "_ARM_bgb",
          "-bench-generic-shift4": "_ARM_bgs4",
          "-bench-generic-shift2": "_ARM_bgs2"}

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def newest_prefix():
    by_prefix = {}
    for f in os.listdir(OBJCACHE):
        if not f.endswith(".o"): continue
        p = f.split("_", 1)[0]
        m = os.path.getmtime(os.path.join(OBJCACHE, f))
        by_prefix[p] = max(by_prefix.get(p, 0), m)
    return max(by_prefix, key=by_prefix.get)

def is_pipeline_key(key):
    return key.startswith("P") and len(key) > 20 and \
        all(c in "0123456789abcdef" for c in key[1:])

def arm_map(prefix, flag, trace):
    """Objects for exactly the kernels this run's trace names, keyed without
    the builder suffix. Pipeline modules are returned as a sorted md5 list,
    because their hash-based ids differ between arms."""
    suf = SUFFIX[flag]
    names = set()
    for line in open(trace):
        for tok in line.split():
            if tok.endswith(".kernel"):
                names.add(tok[:-len(".kernel")])
    kmap, pmods = {}, []
    for n in sorted(names):
        if not n.endswith(suf): continue
        key = n[: -len(suf)]
        path = os.path.join(OBJCACHE, f"{prefix}_{n}.o")
        if not os.path.exists(path): continue
        h = md5(path)
        if is_pipeline_key(key): pmods.append(h)
        else: kmap[key] = h
    return kmap, sorted(pmods)

def run_once(flags, trace=None):
    err = subprocess.DEVNULL if trace is None else open(trace, "w")
    r = subprocess.run([NFC] + flags + ([ "-trace-object-cache"] if trace else []) + [INP],
                       stdout=subprocess.DEVNULL, stderr=err)
    if trace: err.close()
    return r.returncode

def timed(flags):
    t0 = time.perf_counter_ns()
    r = subprocess.run([NFC] + flags + [INP], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    t1 = time.perf_counter_ns()
    if r.returncode != 0:
        print(f"SIGNAL DEATH: exit {r.returncode} flags={flags}"); sys.exit(1)
    return (t1 - t0) / 1e6

def paired(flags_b, n):
    ratios = []
    for i in range(n):
        if i % 2 == 0:
            ta = timed([]); tb = timed(flags_b)
        else:
            tb = timed(flags_b); ta = timed([])
        ratios.append(tb / ta)
    return sorted(ratios)

def stats(ratios, label):
    n = len(ratios)
    med = statistics.median(ratios)
    p10, p90 = ratios[max(0, round(0.10 * (n - 1)))], ratios[round(0.90 * (n - 1))]
    rng = random.Random(20260804)
    boots = sorted(statistics.median(rng.choices(ratios, k=n)) for _ in range(10000))
    ci = (boots[249], boots[9749])
    above = sum(1 for r in ratios if r > 1.0)
    p_sign = min(1.0, 2 * sum(math.comb(n, k) for k in range(min(above, n - above) + 1)) / 2 ** n)
    print(f"{label}: median {med:.4f}  p10 {p10:.4f}  p90 {p90:.4f}  "
          f"CI95 [{ci[0]:.4f},{ci[1]:.4f}]  sign {above}/{n} p={p_sign:.2e}")
    return dict(median=med, p10=p10, p90=p90, ci=ci, above=above, p_sign=p_sign)

def sig(nat, other):
    (nk, np_), (ok, op_) = nat, other
    kdiff = [k for k in nk if k in ok and nk[k] != ok[k]]
    pdiff = np_ != op_
    missing = [k for k in nk if k not in ok]
    return kdiff, pdiff, missing

os.chdir(REPO)
prefix_before = newest_prefix()
print(f"cache prefix: {prefix_before}")

# probe all arms once, collect object maps and traces
maps, scalar_leak = {}, {}
for flag in [""] + [MEASURE] + CANDIDATES:
    tr = f"/tmp/nfc_trace{SUFFIX[flag]}.txt"
    rc = run_once([flag] if flag else [], trace=tr)
    if rc != 0: print(f"arm '{flag or 'native'}' exit {rc}"); sys.exit(1)
    with open(tr) as f: t = f.read()
    scalar_leak[flag] = "_C.kernel" in t
    maps[flag] = arm_map(prefix_before, flag, tr)
    print(f"arm '{flag or 'native'}': {len(maps[flag][0])} kernels + "
          f"{len(maps[flag][1])} pipeline objects, scalar leak: {scalar_leak[flag]}")

kdiff_m, pdiff_m, miss_m = sig(maps[""], maps[MEASURE])
print(f"measured pair: {len(kdiff_m)} kernels differ, pipeline distinct: {pdiff_m}, "
      f"missing: {miss_m}")
print(f"differing kernels: {kdiff_m}")

null_flag = None
for c in CANDIDATES:
    kd, pd, ms = sig(maps[""], maps[c])
    print(f"candidate {c}: {len(kd)} kernel diffs, pipeline distinct: {pd}, missing {len(ms)}")
    if not kd and not ms and pd == pdiff_m:
        null_flag = c; break
if null_flag is None:
    for c in CANDIDATES:
        kd, pd, ms = sig(maps[""], maps[c])
        if not kd and not ms:
            null_flag = c
            print("WARNING: no candidate matches pipeline structure; S7 will not hold")
            break
if null_flag is None: print("FATAL: no usable null bit"); sys.exit(1)
print(f"null bit: {null_flag}")

# S5: output equality across all three arms
outs = {}
for flag in ["", MEASURE, null_flag]:
    r = subprocess.run([NFC] + ([flag] if flag else []) + [INP], capture_output=True)
    outs[flag] = hashlib.md5(r.stdout).hexdigest()
print(f"outputs identical: {len(set(outs.values())) == 1}")

for _ in range(WARMUP):
    timed([]); timed([null_flag]); timed([MEASURE])

null_ratios = paired([null_flag], PAIRS)
null_stats = stats(null_ratios, f"NULL  (native vs {null_flag})")
floor = max(abs(null_stats["p10"] - 1.0), abs(null_stats["p90"] - 1.0))

meas_ratios = paired([MEASURE], PAIRS)
m = stats(meas_ratios, f"MEAS  (native vs {MEASURE})")

prefix_after = newest_prefix()
void = prefix_after != prefix_before \
       or arm_map(prefix_before, "", f"/tmp/nfc_trace{SUFFIX['']}.txt") != maps[""] \
       or arm_map(prefix_before, MEASURE, f"/tmp/nfc_trace{SUFFIX[MEASURE]}.txt") != maps[MEASURE]

effect = abs(m["median"] - 1.0)
gates = {
    "S1_ci_excludes_1": not (m["ci"][0] <= 1.0 <= m["ci"][1]),
    "S2_3x_floor": effect >= 3 * floor,
    "S3_sign_p<0.01": m["p_sign"] < 0.01,
    "S4_path_proof": bool(kdiff_m) and not any(scalar_leak.values()),
    "S5_outputs_equal": len(set(outs.values())) == 1,
    "S6_not_void": not void,
    "S7_floor_structure": (lambda kd_pd=sig(maps[""], maps[null_flag]):
                           not kd_pd[0] and kd_pd[1] == pdiff_m)(),
}
print(f"\nfloor_spread {floor:.4f}   effect {effect:.4f}   scope process")
for k, v in gates.items(): print(f"  {k}: {'PASS' if v else 'FAIL'}")
verdict = "REPORTABLE" if all(gates.values()) else "NOT REPORTABLE"
print(f"\n{verdict}: generic-compress over native = {m['median']:.4f} "
      f"(floor {floor:.4f}, N={PAIRS}, whole-process wall time)")
json.dump(dict(input=INP, pairs=PAIRS, null_flag=null_flag, floor=floor,
               null_stats={k: v for k, v in null_stats.items()},
               measured={k: v for k, v in m.items()},
               kernels_differing=kdiff_m, pipeline_distinct=pdiff_m,
               gates=gates, verdict=verdict, prefix=prefix_before),
          open("/private/tmp/claude-501/-Users-manvir-sfu-479summer2026/174d3d2d-3839-480f-a0ca-518324072485/scratchpad/nfc_certified_summary.json", "w"), indent=1, default=str)
