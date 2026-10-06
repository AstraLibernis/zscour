# zscour plan

What zscour is for: before modelling a Kaggle-style tabular competition,
answer four questions from the CSVs alone — **is the data well-formed, what
predicts the target, is anything leaking, and does test look like train.**
M0 answers the first; M1–M9 the rest. Ideas lifted from ydata-profiling,
sweetviz and deepchecks are credited in [prior-art.md](prior-art.md).

Decided 2026-10-06 with the owner: build order **M1, M2, M3, M4, M5**, then
**M6, M7**; M8–M10 after. zarbor may be a dependency (M5 only). The HTML
report moved up from M10 to **M1.5** at the owner's request, so every later
milestone ships its text and HTML sections together.

## Working rules

- Each milestone fills its stub module (listed below), adds its finding codes'
  checks, its report section, and tests. The stubs exist already: no new files
  without updating this plan.
- **Done** means: `zig build test` green; every new test mutation-checked with
  `tools/mutate.sh` (break, watch it fail, restore); the airline data
  (`~/workspace/kaggle/airline-satisfaction`) run in ReleaseFast and the
  output read; time and peak RSS recorded in [measurements.md](measurements.md).
- Thresholds borrowed from another tool are quoted with their source file and
  line, **re-read from the source when implementing** — the survey notes in
  prior-art.md are a reading list, not verified facts.
- Missing values are never silently replaced by 0 (sweetviz and deepchecks
  both do this before computing associations; it biases them). Missing is its
  own level, or the pair is dropped — say which.
- The report stays one screen per section on a 20-column dataset. Detail goes
  behind a flag, not into the default output.
- **Every milestone with a report section also adds it to `html.zig`**, from
  the same computed fields: text and HTML never compute separately.
- HTML charts follow the dataviz rules recorded under M1.5. Render the page
  and look at it (headless chromium, desktop and 390 px, light and dark)
  before calling a section done — reading the code missed every layout bug
  M1.5 found.

## Status

| | Milestone | Module | State |
|---|---|---|---|
| M0 | Well-formed data: bytes, records, header, schema, values, ids, target, duplicates, shift (KS/TV), submission; `--out` cleaning | `table` `analyze` `clean` `report` | **done** (78deabd) |
| M1 | Target rate per level / per numeric bin, train vs test side by side | `target_rate` `bars` | **done** |
| M1.5 | HTML report: self-contained page, charts per column, drift overview, findings | `html` | **done** |
| M2 | Single-feature predictive power; id and row-order leak checks | `signal` | **done** |
| M3 | Base-form spelling match, punctuation-only values, null spellings | `strings` | **done** |
| M4 | Numeric columns that are really discrete/ordinal | `discrete` | **done** |
| M5 | Adversarial validation (train-vs-test classifier) via zarbor | `adversarial` | **done** |
| M6 | Associations: Spearman, Cramér's V, correlation ratio | `assoc` | **done** |
| M7 | Column stats: skew, kurtosis, zeros, imbalance, monotonicity, lag autocorrelation; sparklines | `stats` `bars` | stub |
| M8 | Columns that go missing together | `missingness` | stub |
| M9 | More drift scores: PSI, Wasserstein, Cramér's V; rare-level pooling; min-sample guard | `drift` | stub (KS/TV done) |
| M10 | Later: LoOP outliers, Unicode script mixing, date leakage | — | not started |

## M1 — target rate by level and by bin  ✓

*Question: which values of a feature go with the target?*

As built (differences from the first draft of this plan in **bold**):

- Categorical feature: per level, train share, test share, target rate in
  train; **and in extra, when it has a target**. Levels sorted by train count;
  top 9 shown, the rest pooled as "other (k levels)"; missing is its own row.
- Numeric feature with ≤ 10 distinct train values: a row per value, test-only
  values pooled as "other values". Otherwise **equal-count bins that never
  split a run of equal values** (`binEdges`), not equal-width or plain
  quantile bins: a 91% spike at one value made quantile edges collapse into a
  single bin. A bin holding one value is labelled by that value.
- Rate: a boolean or 0/1 target → share of the positive class (named in the
  header); any other two-class target → share of its minority class;
  numeric target → mean; **multiclass → shares only, no rate** (gap, below).
- **Features are ranked by η²** (correlation ratio squared: between-row
  variance of the target over its total variance), and the section shows the
  top 20; `--rates N` changes that, `--rates 0` shows all. Without the cap a
  300-feature table printed 3 937 lines.
- Bars: share bars scaled to the feature's largest row; rate bars 0–100%; any
  nonzero share draws at least 1/8 cell.
- Finding `pure_rate` (info): a non-"other" row with ≥ 1% of train and ≥ 30
  rows whose binary rate is exactly 0% or 100%.
- Tests: 14 in `target_rate.zig` + 2 in `bars.zig`; 21 mutations, all killed
  except one equivalent mutant (`clamp(i,1,n)−1` ≡ `min(i,n) −| 1`).

Added after M3, prompted by the owner's question about a 16%-missing column:
- **Missing share sets severity**: a feature's missing values are a note up
  to 5% of a file and a warning past it (deepchecks' `percent_of_nulls`
  default; ydata-profiling alerts from 1%).
- **Informative missingness** (`informative_missing`, note): the rows missing
  a feature differ in target from the rest by ≥ 0.05 standard deviations of
  the target at |z| ≥ 5, with ≥ 30 rows each side → "keep a missing
  indicator rather than imputing it away". Random missingness stays quiet
  (tested, and on the generated messy dataset).

Known gaps, for later milestones:
- Multiclass targets get no rate. Per-class rates (one column per class, or
  the majority class per row) would fit here.
- η² is biased upward when a row holds few labelled examples; with ≤ 11 rows
  per feature this is small on any real train size, but a tiny train file
  will over-rank many-level features.
- The COLUMNS table (M0) still prints one line per column: 300 lines for a
  300-column file. Needs a cap or a compact mode.

## M1.5 — HTML report  ✓

`--html FILE`, and `report.html` beside `report.txt` with `--out`. One file:
inline CSS and SVG, ~15 lines of script (theme toggle, findings filter,
column search), nothing fetched — works offline. 169 KB for 23 columns;
2.4 MB for 300.

- Sections: file tiles and finding counts; findings with severity filters
  (notes start collapsed past 10); per-file drift vs train (KS / total
  variation, sorted, threshold line, largest 40); a card per column — badges,
  missing counts, min/median/max, the column's own findings, and M1's rows.
- Card chart: **two panels sharing the row axis** — share of rows per file
  (grouped bars) and, when there is a target, the target rate or mean (dots,
  joined for ordered numeric rows; overall rate as a reference line). Never a
  second y-axis over the distribution, which is what sweetviz draws.
- Colours: train / test / extra = the reference palette's first three
  categorical slots, the only three that validate all-pairs for colour
  blindness in both themes (dataviz `validate_palette.js`: worst CVD ΔE 9.2
  light / 9.4 dark). Aqua is under 3:1 on the light surface, so every chart
  has a table view. Drift bars are one neutral colour — a file's colour must
  not also mean "flagged"; flagged values are bold beside the threshold line.
  Severity is always icon + word, never colour alone.
- Safety: every string from a data file is escaped (`esc`); the script only
  toggles classes. Tested with a column named `<script>…` and a level
  `<img onerror=…>`.
- Phone: charts keep a 540 px minimum and scroll inside their card; the page
  itself never scrolls sideways (checked at 390 px).
- Bugs found only by rendering: tiles wrapping, tick labels of neighbouring
  panels overprinting, notes pushing charts off screen, unreadable charts on
  a phone, ▲ drawn as a missing glyph, full-precision numbers, axes at twice
  the data.
- Tests: 8 in `html.zig`; 9 mutations, all killed.

## M2 — single-feature signal and leaks  ✓

*Question: what predicts the target on its own, and does anything that
should not?*

As built:

- Per column, out-of-fold power in [0, 1] from a lookup model: each train
  row is predicted from the other 3 folds' rows in the same level, value or
  bin (M1's layout at 1 024 levels / 64 equal-count bins; folds by a hash of
  the row number). Computed from per-(group, fold) totals in one pass.
  - binary target: 2·AUC − 1 (AUC from tie-aware group sums; z against 0.5)
  - numeric target: out-of-fold R²
  - multiclass (≤ 64 classes): (accuracy − majority share) / (1 − majority
    share), ppscore's normalisation
- Leak checks, the same score on: the **id column** (deepchecks'
  identifier–label idea), **row position** (64 equal blocks of the file),
  and the target's **lag-1 autocorrelation** in file order (multiclass:
  same-class excess over Σp², z by normal approximation). A leak needs power
  ≥ 0.01 *and*, where a null is known, z ≥ 5.
- Findings: a feature at power ≥ 0.8 → warn (deepchecks' PPS threshold);
  any leak → warn. Nothing is reported below 100 labelled train rows (a
  3-row file "predicted the target almost alone").
- M1's tables now follow this ranking instead of in-sample η², which closes
  M1's known gap: a 1-level-per-2-rows column scores ~0 here.
- Text section (`--top N`, shared with M1) and an HTML section: ranked bars,
  the leak checks under their own label, the autocorrelation line, a table.
- Checked at scale: the airline train sorted by its target flags row position
  (power 0.9998) and the autocorrelation (z 836); its ids, moved with the
  rows, are correctly not flagged.
- Tests: 9 in `signal.zig`; 13 mutations, all killed after three fixture
  fixes (a zero-mean target hid a wrong R² denominator; no fixture punished
  in-fold multiclass scoring; none separated power from z in the leak rule).
- Cost: +0.16 s on the airline run (1.82 → 1.98 s).

## M3 — spelling variants beyond case  ✓

As built:

- **Base form** (deepchecks' rule): alphanumerics only, ASCII-lowercased;
  the value itself when nothing is left. Non-ASCII letters count as letters;
  Latin-1 punctuation/NBSP, General Punctuation, CJK punctuation and the
  fullwidth/small-form punctuation blocks count as punctuation. Case folding
  stays ASCII only (gap, M10).
- **Spelling variants**: spellings that share a base form but are separate
  levels → warn, with rows per file; test spellings train never uses for a
  value train has → warn on test. **Reported, not merged**: punctuation can
  matter ("A-1"/"A1", "C++"/"C"). `--fold spelling` makes base-form groups one
  level (clean writes the most common spelling); default `--fold case`.
  Values that parse as numbers never join a base-form group ("-5"/"5",
  "1.5"/"15").
- **Punctuation-only values** ("-", "***", "—") in categorical columns, per
  file, not counting missing markers: warn above 0.1% of rows (deepchecks'
  `special_chars` default), note below.
- **Missing markers on base form**: "N/A", "n.a.", "#N/A", "(null)", "<NA>",
  "NULL" now count. **Mixed missing** now fires on two marker spellings even
  with no empty fields, and lists the spellings.
- **Invisible characters are shown**: NBSP, zero-width, BOM, control and
  Unicode spaces print as `<U+00A0>` in findings, the text tables and every
  data string on the HTML page — "New York" and "New<U+00A0>York" no longer
  look identical anywhere.
- HTML: a "Spelling variants" table in each affected column's card.
- Performance: the M3 check works from the distinct spellings `analyze`
  already collected and scans rows only for a column with something to
  report. Marker matching on base form first cost +19% (1.98 → 2.36 s,
  every field passes through it while sniffing types); a first-letter reject
  ("n" or "N") brought it to 1.95 s.
- A borrowed-slice bug was caught by a test before commit: the base form
  lived in a buffer the next key computation overwrote.
- Tests: 11 in `strings.zig` + 2 in `html.zig`; every mutation killed
  (one, "merged groups re-reported", needed a new fixture after the
  row-scan shortcut masked it).

## M4 — numeric but really discrete  ✓

As built:

- **Discrete** = a numeric feature with ≤ 10 distinct values over all files
  (sweetviz's rule; ydata's ≤ 5 misses a 0–5 rating and 1–10 scales), as one
  of four kinds: **binary** (2 values), **integer scale** (consecutive whole
  numbers), **integer codes** (whole numbers with gaps — categories more than
  a scale?), **few decimals**. One summary note per kind lists the columns;
  the column table shows `bin`/`scale`/`codes`/`few`, the HTML badge "integer
  scale · 6 values 0–5".
- **Does the target follow the scale in order?** Pearson's linearity test
  over M1's per-value rows: the weighted straight line's r² against the
  values' η². Reported (note) when η² ≥ 0.01 and the line explains < 80% of
  it, naming the value farthest from the line: an **end** value gets "check
  whether it is a special code such as 'not applicable'", a **middle** value
  "the relation bends there — treat it as categories".
- M1 and M2 already used a row per value at ≤ 10 / ≤ 64 distinct values, so
  M4 changes no grouping. M1's rows now carry the numeric value and labelled
  count; the analysis keeps the target's total sum of squares.
- Tests: 7 in `discrete.zig`; 8 mutations, all killed after adding a fixture
  for a bend too small to matter (η² ≈ 0.0001).
- Cost: none measurable (1.964 s vs 1.948 s).

## M5 — adversarial validation  ✓

*Question: can a model tell train rows from test rows?*

As built:

- zarbor is a `build.zig.zon` dependency pinned to commit a9ee25b (LGPL-3.0+,
  fetched into `zig-pkg/`, which is gitignored). Train vs test, and train vs
  extra; `--no-adversarial` skips it.
- Per comparison: up to 10 000 rows a side (fixed-seed sample), categoricals
  cut to the 254 most frequent levels over both files plus "(other)",
  a 70/30 split by hash, zarbor GBDT depth 3 × 50 rounds, held-out AUC,
  drift = max(2·AUC − 1, 0), z against 0.5. **Drift** (warn for test, note
  for extra) needs drift ≥ 0.1 **and** z ≥ 5; z ≥ 5 below 0.1 is "slightly";
  otherwise "consistent with one distribution".
- Which features give the file away: permutation importance on the held-out
  rows, 3 shuffles of one column of `bins_rm` (what prediction reads), AUC
  lost, restored after. Shown **only when the files can be told apart** — at
  chance the importances are noise.
- Threads: zarbor's pool; everything zarbor allocates comes from
  `Options.zarbor_gpa` (thread-safe; `testing.allocator` in tests, which
  checks for leaks). Results are bit-identical on 1, 3 and 16 threads
  (tested). `zig build test-tsan` runs every test under ThreadSanitizer with
  zarbor instrumented: clean.
- A crash found only on the real data: `@min(10_000, …)` typed the sample
  size as u14, so `2 * m` overflowed at 10 000 rows a side — silently in
  ReleaseFast (segfault), a panic in Debug. Fixed with `usize`, regression
  test at the full sample size, and every `@min` against a constant audited.
- HTML: a card per comparison — AUC, drift, z tiles, the verdict, and the
  importance bars in that file's colour, with a table.
- Tests: 10 in `adversarial.zig`; 10 mutations, all killed after two more
  fixtures (a large gap at low z; frequent levels with ids past 254).
- Cost on the airline files: +0.33 s wall (2.03 → 2.36 s), 5.3 s CPU.

## M6 — associations  ✓

As built:

- Every pair of features on ≤ 100 000 train rows (fixed-seed sample):
  Spearman ρ (numeric × numeric, ties averaged), Cramér's V with Bergsma's
  bias correction (categorical × categorical, ydata's formula without
  scipy's 2×2 Yates correction), correlation ratio η (mixed, sweetviz).
  All in [0, 1] by absolute value; ranked by it.
- Missing values are dropped pair by pair, never replaced by 0. Spearman is
  exact: a pair where either column has missing values is re-ranked on the
  shared rows (ranks over each column alone left gaps — a test caught ρ =
  −0.9988 for an exactly opposite pair).
- A constant column has V = 0 (ydata returns 1). Categoricals with more than
  100 levels are skipped and listed. Theil's U is **not** computed: it is
  asymmetric and V already answers "are these two redundant?".
- Pairs at |value| ≥ 0.9 (ydata's HIGH_CORRELATION) → warning.
- Text: strongest pairs (`--top`). HTML: a heatmap of up to 40 columns (the
  most associated), one hue at opacity = strength so it reads in both themes,
  pairs ≥ 0.9 outlined, a legend ramp, tooltips, a table of the 30 strongest.
- Speed: complete numeric columns keep standardised ranks, so their ρ is one
  dot product; the 300-column file went from 2.68 s to 1.54 s
  (`--no-adversarial`). Airline: +0.13 s.
- Tests: 10 in `assoc.zig`; 13 mutations, all killed after three fixtures
  (missing categories, a moderate pair, a strong negative pair).

## M7 — column statistics

- Skewness and excess kurtosis (bias-corrected, as pandas), share of zeros and
  negatives, imbalance score `1 − H/log2(k)`, monotonicity, lag
  autocorrelation; 8-level sparkline histograms in the column table.
- Tests: moments against a hand computation; sparkline on known counts.

## M8 — missing together

- Pearson correlation of the 0/1 missing indicators for columns that are
  partly missing; report pairs ≥ 0.9 and rows missing in several columns.

## M9 — drift scores

- PSI, Wasserstein (min-max scaled), Cramér's V drift beside KS/TV; rare
  levels (< 1% of train) pooled; no score below 10 values a side.

## M10 — later

- LoOP outlier rows (Gower distance), mixed Unicode scripts and zero-width
  characters, date columns and date leakage, an HTML report.
