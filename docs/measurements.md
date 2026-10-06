# Measurements

ReleaseFast, Ryzen 7 9800X3D, data on NVMe. Timings by hyperfine unless
noted; peak RSS by GNU time.

## Airline satisfaction (Playground S6E10)

train 699,635 × 23 · test 299,844 × 22 · original 129,880 × 22 · sample
submission 299,844 × 2.

| Date | Commit | Command | Wall | Peak RSS | Note |
|---|---|---|---|---|---|
| 2026-10-06 | 78deabd | `zscour data --extra original/data.csv --out clean` | 1.98 s | 897 MB | GNU time, single run, not hyperfine |
