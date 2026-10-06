# zscour plan

What zscour is for: before modelling a Kaggle-style tabular competition,
answer four questions from the CSVs alone — **is the data well-formed, what
predicts the target, is anything leaking, and does test look like train.**
M0 answers the first; M1–M9 the rest. Ideas lifted from ydata-profiling,
sweetviz and deepchecks are credited in [prior-art.md](prior-art.md).

Decided 2026-10-06 with the owner: build order **M1, M2, M3, M4, M5**, then
**M6, M7**; M8–M10 after. zarbor may be a dependency (M5 only).

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

## Status

| | Milestone | Module | State |
|---|---|---|---|
| M0 | Well-formed data: bytes, records, header, schema, values, ids, target, duplicates, shift (KS/TV), submission; `--out` cleaning | `table` `analyze` `clean` `report` | **done** (78deabd) |
| M1 | Target rate per level / per numeric bin, train vs test side by side | `target_rate` `bars` | **done** |
| M2 | Single-feature predictive power; id and row-order leak checks | `signal` | stub |
| M3 | Base-form spelling match, punctuation-only values, null spellings | `strings` | stub |
| M4 | Numeric columns that are really discrete/ordinal | `discrete` | stub |
| M5 | Adversarial validation (train-vs-test classifier) via zarbor | `adversarial` | stub |
| M6 | Associations: Spearman, Cramér's V, Theil's U, correlation ratio | `assoc` | stub |
| M7 | Column stats: skew, kurtosis, zeros, imbalance, monotonicity, lag autocorrelation; sparklines | `stats` `bars` | stub |
| M8 | Columns that go missing together | `missingness` | stub |
| M9 | More drift scores: PSI, Wasserstein, Cramér's V; rare-level pooling; min-sample guard | `drift` | stub (KS/TV done) |
| M10 | Later: LoOP outliers, Unicode script mixing, date leakage, HTML report | — | not started |

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

## M2 — single-feature signal and leaks

*Question: what predicts the target on its own, and does anything that
should not?*

- Per feature, a model-free predictive score in [0, 1]: predict the target
  from that feature alone with a per-level (categorical) or per-quantile-bin
  (numeric) majority class / mean, scored out-of-fold against the baseline
  of always predicting the overall majority / mean. Binary targets also get
  the feature's univariate AUC (Mann–Whitney rank sum). Ranked table.
- The same score on the **id column** and on **row position** in train: any
  real signal means the label leaks through ordering. Also the target's lag-1
  autocorrelation in file order.
- Findings: id/order signal above noise → err-level leak warning; a single
  feature scoring ≥ 0.8 → warn (suspiciously strong).
- Tests: planted leak (target sorted by id) is caught; shuffled is not;
  scores match a hand computation; AUC = 0.5 on noise, 1 on a perfect split.

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
