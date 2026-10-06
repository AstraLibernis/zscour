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
| M3 | Base-form spelling match, punctuation-only values, null spellings | `strings` | stub |
| M4 | Numeric columns that are really discrete/ordinal | `discrete` | stub |
| M5 | Adversarial validation (train-vs-test classifier) via zarbor | `adversarial` | stub |
| M6 | Associations: Spearman, Cramér's V, Theil's U, correlation ratio | `assoc` | stub |
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

## M3 — spelling variants beyond case

- Base form = drop every non-alphanumeric character, lowercase; if that
  leaves nothing, keep the original (deepchecks' rule). Group levels by base
  form; more than one spelling is a variant group. Replaces the case-only
  check and feeds `clean`'s folding.
- Values whose base form is empty (`?`, `-`, `***`): punctuation-only,
  probably placeholders.
- Missing markers matched on base form too (`N/A`, `n.a.`, `NULL`).
- Train/test: base forms whose test spellings train never uses.
- Tests: grouping, empty-base fallback, clean output uses one spelling.

## M4 — numeric but really discrete

- A numeric column with few distinct values (≤ 10 in sweetviz, ≤ 5 in
  ydata — pick one and say why) is reported as discrete: per-value table
  instead of quantiles, and M1/M2 treat it per value.
- Note whether the values are consecutive integers (an ordinal scale such as
  a 0–5 rating) or arbitrary codes.
- Tests: the airline ratings are flagged; Age is not.

## M5 — adversarial validation

*Question: can a model tell train rows from test rows?*

- Label train 0 and test 1, sample equal sizes, fit zarbor's GBDT
  (shallow, few rounds), score held-out AUC; report `max(2·AUC − 1, 0)` and
  the features the model leans on most. Deepchecks' defaults are the starting
  point (see prior-art.md).
- zarbor comes in as a `build.zig.zon` dependency pinned to a commit, not
  vendored. Option `--no-adversarial` to skip.
- Also run with `--extra` vs train: how different is the original data.
- Tests: identical distributions score ≈ 0; a planted shifted feature is
  detected and named.

## M6 — associations

- Numeric × numeric Spearman; categorical × categorical bias-corrected
  Cramér's V (and Theil's U, asymmetric); numeric × categorical correlation
  ratio η. Missing handled per the working rules.
- Report: feature ↔ target ranking and feature pairs ≥ 0.9.
- Tests: each formula against a hand-computed example.

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
