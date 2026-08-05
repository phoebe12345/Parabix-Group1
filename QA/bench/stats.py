#!/usr/bin/env python3
"""Paired A/B statistics for the ARM/SVE2 benchmark harness.

Reads samples.csv with the header pair,arm,ns,items,status,pct and writes
summary.json plus a plain-text table. Standard library only.

The measured unit is nanoseconds. On Apple Silicon the counter is mrs CNTVCT_EL0
at 1.000 GHz, so it is not a cycle count and this program never says otherwise.
The counter steps in 41.67 ns, so a median below a few thousand nanoseconds carries
visible quantisation and this program says so.

Two floors, not one:

  floor_spread  the p10 to p90 span of the null session's paired ratios. This is the
                run to run variability of the instrument. It does not shrink with N.
                S2 uses this one.
  floor_ci      the bootstrap CI half-width of the null session's median ratio. This
                shrinks as 1/sqrt(N) and is an estimate of where the median sits, not
                of how far one pair can stray. It is printed, never gated on.

A floor also carries provenance. A floor measured on another driver, another input or
another quantity is not a floor for this configuration, and S2 fails when they differ.
"""

import argparse
import csv
import json
import math
import random
import sys

BOOTSTRAP_RESAMPLES = 10000
BOOTSTRAP_SEED = 20260804
COUNTER_STEP_NS = 41.67

SCOPES = ("kernel", "kernel-group", "process", "sweep-point")


def percentile(sorted_values, q):
    if not sorted_values:
        return float("nan")
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    pos = (len(sorted_values) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return float(sorted_values[int(pos)])
    return sorted_values[lo] * (hi - pos) + sorted_values[hi] * (pos - lo)


def median(values):
    return percentile(sorted(values), 0.5)


def describe(values):
    s = sorted(values)
    med = percentile(s, 0.5)
    q1 = percentile(s, 0.25)
    q3 = percentile(s, 0.75)
    iqr = q3 - q1
    return {
        "n": len(s),
        "median_ns": med,
        "iqr_ns": iqr,
        "iqr_pct_of_median": (100.0 * iqr / med) if med else float("nan"),
        "p10_ns": percentile(s, 0.10),
        "p90_ns": percentile(s, 0.90),
        "min_ns": s[0] if s else float("nan"),
        "max_ns": s[-1] if s else float("nan"),
    }


def bootstrap_median_ci(ratios, resamples=BOOTSTRAP_RESAMPLES, seed=BOOTSTRAP_SEED):
    rng = random.Random(seed)
    n = len(ratios)
    if n == 0:
        return float("nan"), float("nan")
    medians = []
    for _ in range(resamples):
        sample = [ratios[rng.randrange(n)] for _ in range(n)]
        medians.append(median(sample))
    medians.sort()
    return percentile(medians, 0.025), percentile(medians, 0.975)


def binom_tail_le(k, n):
    return sum(math.comb(n, i) for i in range(0, k + 1)) / (2.0 ** n)


def sign_test(ratios):
    """Exact two-sided binomial sign test on r > 1. Ties are dropped."""
    gt = sum(1 for r in ratios if r > 1.0)
    lt = sum(1 for r in ratios if r < 1.0)
    n = gt + lt
    if n == 0:
        return {"n_nonzero": 0, "n_greater": 0, "p_value": 1.0}
    k = min(gt, lt)
    p = 2.0 * binom_tail_le(k, n)
    return {"n_nonzero": n, "n_greater": gt, "p_value": min(1.0, p)}


def load_samples(path):
    rows = []
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            rows.append({
                "pair": int(row["pair"]),
                "arm": row["arm"].strip(),
                "ns": float(row["ns"]),
                "items": int(row["items"]),
                "status": int(row["status"]),
                "pct": float(row["pct"]) if row.get("pct") not in (None, "") else float("nan"),
            })
    return rows


def build_pairs(rows):
    """Keep only pairs where both arms produced an accepted sample."""
    by_pair = {}
    for r in rows:
        by_pair.setdefault(r["pair"], {})[r["arm"]] = r
    pairs, dropped = [], 0
    for idx in sorted(by_pair):
        entry = by_pair[idx]
        if "A" not in entry or "B" not in entry:
            dropped += 1
            continue
        if entry["A"]["status"] != 0 or entry["B"]["status"] != 0:
            dropped += 1
            continue
        pairs.append((entry["A"], entry["B"]))
    return pairs, dropped


def check_items(pairs):
    """ITEMS must be identical across every accepted sample of a configuration."""
    problems = []
    for arm, idx in (("A", 0), ("B", 1)):
        seen = {p[idx]["items"] for p in pairs}
        if len(seen) > 1:
            problems.append("arm %s has inconsistent ITEMS: %s" % (arm, sorted(seen)))
    return problems


def spread_floor(ratios):
    """The systematic floor: how far one paired ratio strays, not where the median is."""
    s = sorted(ratios)
    return max(abs(percentile(s, 0.10) - 1.0), abs(percentile(s, 0.90) - 1.0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("samples", help="path to samples.csv")
    ap.add_argument("--out", help="path to write summary.json")
    ap.add_argument("--label", default="unnamed", help="configuration label")
    ap.add_argument("--kernel", default="", help="counter row this configuration measured")
    ap.add_argument("--scope", choices=SCOPES, required=True,
                    help="what the measured quantity covers. Only 'process' may carry an "
                         "end-to-end sentence")
    ap.add_argument("--quantity", default="",
                    help="plain words for what was measured, printed above the ratio")
    ap.add_argument("--switch", default="",
                    help="the option that was toggled between the arms, printed in the caption")
    ap.add_argument("--w-null", type=float, default=None,
                    help="systematic floor: p10..p90 span of the null session's paired ratios")
    ap.add_argument("--w-null-ci", type=float, default=None,
                    help="the null session's bootstrap CI half-width, printed only")
    ap.add_argument("--w-null-label", default="",
                    help="provenance of the floor: driver, quantity and input it came from")
    ap.add_argument("--expect-w-null-label", default="",
                    help="the provenance this configuration requires; S2 fails on a mismatch")
    ap.add_argument("--floor-signature", default="",
                    help="structural signature of the null arms, kernel and pipeline")
    ap.add_argument("--expect-floor-signature", default="",
                    help="structural signature of the measured arms; S7 fails on a mismatch")
    ap.add_argument("--n-signal", type=int, default=0)
    ap.add_argument("--n-attempted", type=int, default=0)
    ap.add_argument("--path-proof", choices=["pass", "fail"], default="fail")
    ap.add_argument("--md5-distinct", choices=["yes", "no"], default="no")
    ap.add_argument("--session-void", choices=["yes", "no"], default="no")
    ap.add_argument("--attribution-pipeline", type=float, default=None,
                    help="share of PIPELINE time held by the measured kernels")
    ap.add_argument("--attribution-wall", type=float, default=None,
                    help="share of PROCESS wall time held by the measured kernels")
    ap.add_argument("--is-null", action="store_true",
                    help="this run is the noise floor itself, so S2 and S7 do not apply")
    args = ap.parse_args()

    rows = load_samples(args.samples)
    pairs, dropped = build_pairs(rows)
    if not pairs:
        print("NOT REPORTABLE: no complete accepted pairs in %s" % args.samples)
        return 1

    item_problems = check_items(pairs)
    a_ns = [p[0]["ns"] for p in pairs]
    b_ns = [p[1]["ns"] for p in pairs]
    ratios = [p[1]["ns"] / p[0]["ns"] for p in pairs if p[0]["ns"] > 0]

    med_r = median(ratios)
    ci_lo, ci_hi = bootstrap_median_ci(ratios)
    sign = sign_test(ratios)
    own_spread = spread_floor(ratios)

    reasons = []
    s1 = not (ci_lo <= 1.0 <= ci_hi)
    if not s1:
        reasons.append("S1: bootstrap 95%% CI on median ratio [%.5f, %.5f] contains 1.0" % (ci_lo, ci_hi))

    if args.is_null:
        s2 = True
    elif args.w_null is None:
        s2 = False
        reasons.append("S2: no noise floor supplied; run this same driver with --null first")
    elif args.expect_w_null_label and args.w_null_label != args.expect_w_null_label:
        s2 = False
        reasons.append("S2: the floor was measured as '%s' but this configuration needs '%s'. "
                       "A floor from another driver, input or quantity is not a floor here."
                       % (args.w_null_label or "unlabelled", args.expect_w_null_label))
    else:
        s2 = abs(med_r - 1.0) >= 3.0 * args.w_null
        if not s2:
            reasons.append("S2: |median r - 1| = %.5f is below 3 * w_null = %.5f"
                           % (abs(med_r - 1.0), 3.0 * args.w_null))

    s3 = sign["p_value"] < 0.01
    if not s3:
        reasons.append("S3: exact sign test p = %.4g is not below 0.01" % sign["p_value"])

    s4 = args.path_proof == "pass" and args.md5_distinct == "yes"
    if not s4:
        reasons.append("S4: path proof=%s, arms' objects distinct=%s" % (args.path_proof, args.md5_distinct))

    signal_rate = (args.n_signal / args.n_attempted) if args.n_attempted else 0.0
    s5 = signal_rate < 0.02
    if not s5:
        reasons.append("S5: signal death rate %.4f is at or above 0.02" % signal_rate)
    if item_problems:
        s5 = False
        reasons.extend("S5: " + p for p in item_problems)

    s6 = args.session_void == "no"
    if not s6:
        reasons.append("S6: session void, the cache prefix set or a kernel object changed mid-session")

    # S7 requires matching pipeline and cache structure in the floor session.
    if args.is_null:
        s7 = True
    elif not args.expect_floor_signature:
        s7 = False
        reasons.append("S7: no structural signature recorded for the measured arms")
    elif args.floor_signature != args.expect_floor_signature:
        s7 = False
        reasons.append("S7: the floor's arms differ as '%s' but the measured arms differ as '%s'. "
                       "The floor does not contain the same confound."
                       % (args.floor_signature or "unrecorded", args.expect_floor_signature))
    else:
        s7 = True

    reportable = all([s1, s2, s3, s4, s5, s6, s7])

    w_null = args.w_null if args.w_null is not None else float("nan")
    a_desc, b_desc = describe(a_ns), describe(b_ns)
    quantised = min(a_desc["median_ns"], b_desc["median_ns"]) < 100.0 * COUNTER_STEP_NS

    summary = {
        "label": args.label,
        "kernel": args.kernel,
        "scope": args.scope,
        "quantity": args.quantity,
        "switch_toggled": args.switch,
        "unit": "nanoseconds",
        "counter_step_ns": COUNTER_STEP_NS,
        "quantisation_warning": quantised,
        "n_pairs_accepted": len(pairs),
        "n_pairs_dropped": dropped,
        "arm_A_native": a_desc,
        "arm_B_control": b_desc,
        "paired_ratio_B_over_A": {
            "median": med_r,
            "p10": percentile(sorted(ratios), 0.10),
            "p90": percentile(sorted(ratios), 0.90),
            "iqr": percentile(sorted(ratios), 0.75) - percentile(sorted(ratios), 0.25),
            "spread_floor": own_spread,
            "ci95_low": ci_lo,
            "ci95_high": ci_hi,
            "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
            "bootstrap_seed": BOOTSTRAP_SEED,
        },
        "sign_test": sign,
        "w_null": w_null,
        "w_null_ci": args.w_null_ci if args.w_null_ci is not None else float("nan"),
        "w_null_label": args.w_null_label,
        "floor_signature": args.floor_signature,
        "expect_floor_signature": args.expect_floor_signature,
        "signal_rate": signal_rate,
        "counter_pct_arm_A": median([p[0]["pct"] for p in pairs if not math.isnan(p[0]["pct"])] or [float("nan")]),
        "counter_pct_arm_B": median([p[1]["pct"] for p in pairs if not math.isnan(p[1]["pct"])] or [float("nan")]),
        "conditions": {"S1": s1, "S2": s2, "S3": s3, "S4": s4, "S5": s5, "S6": s6, "S7": s7},
        "reportable": reportable,
        "reasons_not_reportable": reasons,
    }
    if args.attribution_pipeline is not None:
        summary["attribution_pipeline"] = args.attribution_pipeline
        summary["min_effect_pipeline_level"] = (
            (w_null / args.attribution_pipeline) if args.w_null else float("nan"))
    if args.attribution_wall is not None:
        summary["attribution_wall"] = args.attribution_wall
        summary["min_effect_end_to_end"] = (
            (w_null / args.attribution_wall) if args.w_null else float("nan"))

    if args.out:
        with open(args.out, "w") as fh:
            json.dump(summary, fh, indent=2)

    print("configuration : %s" % args.label)
    print("scope         : %s" % args.scope)
    if args.quantity:
        print("quantity      : %s" % args.quantity)
    if args.switch:
        print("switch toggled: %s" % args.switch)
    print("counter row   : %s" % (args.kernel or "n/a"))
    print("unit          : nanoseconds (CNTVCT_EL0 at 1.000 GHz), not cycles; step %.2f ns"
          % COUNTER_STEP_NS)
    print("pairs         : %d accepted, %d dropped" % (len(pairs), dropped))
    if quantised:
        print("CAUTION       : a median below %.0f ns is fewer than 100 counter steps, so the"
              % (100.0 * COUNTER_STEP_NS))
        print("                printed decimals are below the resolution of the instrument")
    print("")
    print("  arm                 median ns        IQR    IQR%       p10        p90        min        max    N")
    for name, d in (("A native", a_desc), ("B control", b_desc)):
        print("  %-11s %14.1f %10.1f %6.2f %10.1f %10.1f %10.1f %10.1f %4d"
              % (name, d["median_ns"], d["iqr_ns"], d["iqr_pct_of_median"],
                 d["p10_ns"], d["p90_ns"], d["min_ns"], d["max_ns"], d["n"]))
    print("")
    r = summary["paired_ratio_B_over_A"]
    print("  paired ratio B/A : median %.5f   p10 %.5f   p90 %.5f   IQR %.5f"
          % (med_r, r["p10"], r["p90"], r["iqr"]))
    print("  bootstrap 95%% CI : [%.5f, %.5f]  (%d resamples, seed %d)"
          % (ci_lo, ci_hi, BOOTSTRAP_RESAMPLES, BOOTSTRAP_SEED))
    print("  sign test        : %d of %d pairs above 1, exact two-sided p = %.4g"
          % (sign["n_greater"], sign["n_nonzero"], sign["p_value"]))
    print("  own spread       : p10..p90 of this run's paired ratios is %.5f from 1.0" % own_spread)
    if args.is_null:
        print("  this run IS the noise floor. S2 and S7 do not apply to it.")
    print("  noise floor      : w_null = %s   (systematic, p10..p90 of the null's ratios)"
          % ("%.5f" % w_null if args.w_null is not None else "NOT SUPPLIED"))
    if args.w_null_ci is not None:
        print("                     null CI half-width %.5f, printed only; it shrinks with N"
              % args.w_null_ci)
    if args.w_null_label:
        print("  floor from       : %s" % args.w_null_label)
    if args.expect_floor_signature:
        print("  arms differ in   : %s" % args.expect_floor_signature)
    if args.floor_signature:
        print("  floor arms differ: %s" % args.floor_signature)
    print("  counter %% of pipeline : arm A %.2f, arm B %.2f"
          % (summary["counter_pct_arm_A"], summary["counter_pct_arm_B"]))

    if args.attribution_pipeline is not None:
        print("  share of PIPELINE time in the measured kernels : %.4f" % args.attribution_pipeline)
    if args.attribution_wall is not None:
        print("  share of PROCESS  time in the measured kernels : %.4f" % args.attribution_wall)

    # End-to-end attribution uses process time, including setup and teardown.
    if args.scope == "process":
        if args.attribution_wall is None:
            print("  min resolvable end-to-end effect : unknown, no process-level attribution")
        elif args.w_null is None:
            print("  min resolvable end-to-end effect : unknown until w_null is supplied")
        else:
            print("  min resolvable end-to-end effect : %.4f (w_null / share of PROCESS time %.4f)"
                  % (summary["min_effect_end_to_end"], args.attribution_wall))
    elif args.attribution_pipeline is not None and args.w_null is not None:
        print("  min resolvable pipeline-level effect : %.4f (w_null / share of PIPELINE time %.4f)"
              % (summary["min_effect_pipeline_level"], args.attribution_pipeline))
        print("  this is NOT an end-to-end figure. Scope is %s." % args.scope)

    print("")
    if args.is_null:
        print("NOISE FLOOR RUN. This is not a result and carries no verdict.")
        print("  floor_spread %.5f   floor_ci %.5f" % (own_spread, max(
            abs(ci_lo - 1.0), abs(ci_hi - 1.0))))
    elif reportable:
        print("REPORTABLE")
    else:
        print("NOT REPORTABLE: no difference resolvable at N=%d with a noise floor of %s"
              % (len(pairs), ("%.5f" % w_null if args.w_null is not None else "unknown")))
        for reason in reasons:
            print("  reason: %s" % reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
