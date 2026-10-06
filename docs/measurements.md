# Measurements

ReleaseFast, Ryzen 7 9800X3D, data on NVMe. Timings by hyperfine unless
noted; peak RSS by GNU time.

## Airline satisfaction (Playground S6E10)

train 699,635 × 23 · test 299,844 × 22 · original 129,880 × 22 · sample
submission 299,844 × 2.

| Date | Commit | Command | Wall | Peak RSS | Note |
|---|---|---|---|---|---|
| 2026-10-06 | 78deabd | `zscour data --extra original/data.csv --out clean` | 1.98 s | 897 MB | GNU time, single run, not hyperfine |
| 2026-10-06 | a3527e2 | `zscour data --extra original/data.csv` | 1.768 s ± 0.006 | 899 MB | hyperfine -N, 10 runs, 2 warm-up; User 1.633 s |
| 2026-10-06 | M1.5 | same, without / with `--html` | 1.812 / 1.819 s ± 0.008 | 899 MB | hyperfine -N, 10 runs; the page costs ~7 ms; 169 KB |
| 2026-10-06 | M2 | `zscour data --extra original/data.csv` | 1.976 s ± 0.004 | — | hyperfine -N, 5 runs; M2 adds 0.16 s |
| 2026-10-06 | M3 | `zscour data --extra original/data.csv` | 1.948 s ± 0.003 | — | hyperfine -N, 5 runs; first M3 draft 2.356 s (base-form markers on every field), fixed by a first-letter reject |
| 2026-10-06 | M4 | `zscour data --extra original/data.csv` | 1.964 s ± 0.004 | — | hyperfine -N, 5 runs |
