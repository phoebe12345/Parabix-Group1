# Canonical result bundle

This directory contains the benchmark sessions used in the final report. The full
`results/` directory is ignored, so only the relevant manifests, summaries, path
proofs, samples, and printed reports are kept here.

Sessions from 2026-08-05, one measurement session and its own null session per row:

| Sessions (UTC time) | What they carry |
|---|---|
| 1011xx | Seven microbenchmark measurements. |
| 1014xx to 1015xx | The same measurements before the byte-table fix. |
| 1052xx to 1054xx | `u32u8` runs for the field-width 2 and 4 shift switches. |
| 110500 | Initial `nfc` runs. This version of the driver did not save raw samples. |
| 121107 | Full `nfc` rerun. Ratio 1.0181, floor 0.0073, S2 failed. |
| 122719 | A second full `nfc` run on the same 1.3 GB input. Ratio 1.0193, floor 0.0102, S2 failed. |

The five `nfc` sessions gave ratios from 1.0166 to 1.0193, all in the same
direction. Only one passed every gate, so the report describes the result as an
indication of about 1.8%, not a confirmed improvement.

The gate definitions are in `../README.md`. The field-width 64 compress and expand
rows fail S7 and are kept as point estimates only.

The manifests keep the commit IDs recorded when each run started. Commit messages
were cleaned up later, but the source trees did not change: `05ba04b3` maps to
`e6d93058`, `98b38560` maps to `0e203079`, and `d017d6d7` maps to `de6395f9`.

`nfc_cycle_attribution_20260805.txt` is one `-EnableCycleCounter` run on the 614 MB
corpus. In that run, `elemFilter_8` accounts for 1.8% of pipeline time. This file is
used for attribution, not as a benchmark result.
