#!/usr/bin/env python3
"""Certified-style macro A/B on whole-process wall time, scope=process.

Follows the QA/bench discipline: discovered null bit with structural signature
match, paired interleaved sampling, bootstrap CI, exact sign test, 3x-floor gate,
path proof by object md5, output equality, cache-prefix void check.

Usage: bench_wall.py [--bit compress] [--pairs 31] TOOL INPUT [TOOL_ARGS...]

Writes manifest, raw samples, path proof and summary into a session directory
under QA/bench/results, like the shell drivers.
"""
import argparse, subprocess, time, statistics, sys, os, hashlib, random, math, json

BENCH = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(BENCH))
RESULTS = os.path.join(BENCH, "results")
OBJCACHE = os.path.expanduser("~/.parabix/objcache")
BITS = ["compress", "expand", "shift2", "shift4", "bitperm"]
SUF = {"compress": "_bgc", "expand": "_bge", "shift2": "_bgs2",
       "shift4": "_bgs4", "bitperm": "_bgb"}

ap = argparse.ArgumentParser()
ap.add_argument("--bit", default="compress", choices=BITS)
ap.add_argument("--pairs", type=int, default=31)
ap.add_argument("--warmup", type=int, default=3)
ap.add_argument("tool")
ap.add_argument("input")
ap.add_argument("base", nargs=argparse.REMAINDER)
A = ap.parse_args()

TOOL, INP, BASE, PAIRS = A.tool, A.input, A.base, A.pairs
MEASURE = "-bench-generic-" + A.bit
# expand has no working generic arm at fw=8, so it is never a null candidate
CANDIDATES = ["-bench-generic-" + b for b in ["bitperm", "shift4", "shift2", "compress"]
              if b != A.bit and b != "expand"]
SUFFIX = {"": "_ARM", MEASURE: "_ARM" + SUF[A.bit]}
for c in CANDIDATES:
    SUFFIX[c] = "_ARM" + SUF[c.replace("-bench-generic-", "")]

STAMP = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
SESSION = os.path.join(RESULTS, f"{STAMP}_wall_{os.path.basename(TOOL)}_{A.bit}")
os.makedirs(SESSION, exist_ok=True)

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def sha256(path):
    h = hashlib.sha256()
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
    """Objects for exactly the kernels this run's trace names, keyed without the
    builder suffix. Pipeline modules come back as a sorted md5 list, because
    their hash-based ids differ between arms."""
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
    r = subprocess.run([TOOL] + BASE + flags + (["-trace-object-cache"] if trace else []) + [INP],
                       stdout=subprocess.DEVNULL, stderr=err)
    if trace: err.close()
    return r.returncode

def timed(flags):
    t0 = time.perf_counter_ns()
    r = subprocess.run([TOOL] + BASE + flags + [INP], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    t1 = time.perf_counter_ns()
    if r.returncode != 0:
        print(f"SIGNAL DEATH: exit {r.returncode} flags={flags}"); sys.exit(1)
    return (t1 - t0) / 1e6

def paired(flags_b, n, csv_path):
    rows = []
    for i in range(n):
        if i % 2 == 0:
            ta = timed([]); tb = timed(flags_b); order = "AB"
        else:
            tb = timed(flags_b); ta = timed([]); order = "BA"
        rows.append((i, order, ta, tb, tb / ta))
    with open(csv_path, "w") as f:
        f.write("pair,order,t_native_ms,t_other_ms,ratio_b_over_a\n")
        for r in rows:
            f.write(f"{r[0]},{r[1]},{r[2]:.3f},{r[3]:.3f},{r[4]:.6f}\n")
    return sorted(r[4] for r in rows)

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

def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args),
                          capture_output=True, text=True).stdout.strip()

prefix_before = newest_prefix()
print(f"session {SESSION}")
print(f"cache prefix: {prefix_before}")

maps, scalar_leak = {}, {}
for flag in [""] + [MEASURE] + CANDIDATES:
    tr = os.path.join(SESSION, f"trace{SUFFIX[flag]}.txt")
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
if null_flag is None: print("FATAL: no usable null bit"); sys.exit(1)
print(f"null bit: {null_flag}")

outs = {}
for flag in ["", MEASURE, null_flag]:
    h = hashlib.md5()
    p = subprocess.Popen([TOOL] + BASE + ([flag] if flag else []) + [INP],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for chunk in iter(lambda: p.stdout.read(1 << 20), b""):
        h.update(chunk)
    p.wait()
    outs[flag] = h.hexdigest()
print(f"outputs identical: {len(set(outs.values())) == 1}")

for _ in range(A.warmup):
    timed([]); timed([null_flag]); timed([MEASURE])

null_ratios = paired([null_flag], PAIRS, os.path.join(SESSION, "samples_null.csv"))
null_stats = stats(null_ratios, f"NULL  (native vs {null_flag})")
floor = max(abs(null_stats["p10"] - 1.0), abs(null_stats["p90"] - 1.0))

meas_ratios = paired([MEASURE], PAIRS, os.path.join(SESSION, "samples_measured.csv"))
m = stats(meas_ratios, f"MEAS  (native vs {MEASURE})")

prefix_after = newest_prefix()
void = prefix_after != prefix_before \
       or arm_map(prefix_before, "", os.path.join(SESSION, f"trace{SUFFIX['']}.txt")) != maps[""] \
       or arm_map(prefix_before, MEASURE, os.path.join(SESSION, f"trace{SUFFIX[MEASURE]}.txt")) != maps[MEASURE]

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
print(f"\n{verdict}: {MEASURE} over native = {m['median']:.4f} "
      f"(floor {floor:.4f}, N={PAIRS}, whole-process wall time)")

with open(os.path.join(SESSION, "path_proof.txt"), "w") as f:
    f.write(f"prefix {prefix_before}\n")
    for flag in ["", MEASURE, null_flag]:
        kmap, pmods = maps[flag]
        f.write(f"\narm '{flag or 'native'}' ({SUFFIX[flag]}):\n")
        for k in sorted(kmap): f.write(f"  {k}  {kmap[k]}\n")
        for pm in pmods: f.write(f"  pipeline  {pm}\n")
    f.write(f"\ndiffering kernels vs native: {kdiff_m}\npipeline distinct: {pdiff_m}\n")

manifest = dict(
    utc=STAMP, scope="process",
    quantity="wall time of the whole process, start to teardown",
    tool=TOOL, base_args=BASE, input=INP,
    input_bytes=os.path.getsize(INP), input_sha256=sha256(INP),
    switch_toggled=MEASURE, null_bit=null_flag, pairs=PAIRS, warmup=A.warmup,
    git_head=git("rev-parse", "HEAD"), git_branch=git("rev-parse", "--abbrev-ref", "HEAD"),
    git_status=git("status", "--porcelain"),
    uname=subprocess.run(["uname", "-a"], capture_output=True, text=True).stdout.strip(),
    hw_model=subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
    power=subprocess.run(["pmset", "-g", "ps"], capture_output=True, text=True).stdout.splitlines()[0],
    cache_prefix=prefix_before,
)
json.dump(manifest, open(os.path.join(SESSION, "manifest.json"), "w"), indent=1)
json.dump(dict(null=null_stats, measured=m, floor_spread=floor, effect=effect,
               gates=gates, verdict=verdict, outputs_md5=outs,
               kernels_differing=kdiff_m, pipeline_distinct=pdiff_m),
          open(os.path.join(SESSION, "summary.json"), "w"), indent=1, default=str)
print(f"artifacts in {SESSION}")
