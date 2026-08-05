# Canonical result bundle

These are the raw artifacts behind the numbers the report defends. The full
`results/` directory is not tracked; this directory holds a curated copy of the
final sessions only: manifest, summary, path proof, per-pair samples, and the
printed report for each.

Sessions from 2026-08-05, one measurement session and its own null session per row:

| Sessions (UTC time) | What they carry |
|---|---|
| 1011xx | The seven microbenchmark rows at HEAD `05ba04b3`. |
| 1014xx to 1015xx | The same rows with the pre-fix byte-granular table rebuilt, for the before and after comparison. |
| 1052xx to 1054xx | `u32u8` end to end, `-bench-generic-shift2` and `-bench-generic-shift4`. |
| 110500 | The first `nfc` wall-time runs (printed reports and summary only; the first driver did not persist raw samples). |
| 121107 | The `nfc` wall-time rerun with the integrated driver: full manifest, raw per-pair samples, path proof. Effect 1.0181, floor 0.0073, fails the three-floor gate. Across four sessions the nfc effect is consistent in direction but certified in only one; treat it as indicated, about 1.8%, not certified. |

The gate rules these sessions were judged by are in `../README.md`. The compress
64 and expand 64 microbenchmark rows fail gate S7 and are point estimates, not
certified results.
