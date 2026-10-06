# Prior art and attribution

zscour reimplements ideas from these projects. No code is copied from any of
them; where a formula or a default threshold is taken over, the zscour source
names the project and the original file, and this page lists it.

| Project | Licence | Revision read | What we take |
|---|---|---|---|
| [ydata-profiling](https://github.com/ydataai/ydata-profiling) | MIT, © 2016 Jos Polfliet, 2019–2021 Simon Brugman, 2022– YData Labs Inc | `98b1aba` (2026-09-11) | alert thresholds, column statistics, imbalance score, nullity correlation, Cramér's V, histogram binning |
| [sweetviz](https://github.com/fbdesignpro/sweetviz) | MIT, © 2020 fbdesignpro | `4697e18` (2026-04-11) | target rate per level/bin, side-by-side train/test layout, correlation ratio, Theil's U, discrete-numeric rule |
| [deepchecks](https://github.com/deepchecks/deepchecks) | **AGPL-3.0**, © 2021–2023 Deepchecks | `98475d1` (2025-11-24) | ideas and published formulas only: adversarial validation, predictive power score, string base form, drift scores and binning |

deepchecks is AGPL-3.0. zscour (GPL-3.0-or-later) takes from it only what is
not copyrightable — which checks to run, the mathematics, default numbers —
written fresh in Zig. Nothing is translated line by line from its source.

## Reading list, by milestone

These pointers come from a survey of the three source trees on 2026-10-06
(paths relative to each repo). They are **unverified notes**: re-read the
cited file before relying on a formula or a number, and record what you
actually found next to the code that uses it.

**M1 target rate** — sweetviz `series_analyzer_cat.py:38-134`,
`graph_cat.py:73-226`, `graph_numeric.py:62-177`, `utils.py:6-61`.
Noted: per-level `sum(target)/count`; shared bin edges over the union range,
each file normalised by its own n; top-N levels plus "Others"; the test-side
`fillna` in `graph_numeric.py:146,207` applies to train's bins (a bug — don't
copy it).

**M2 predictive power** — deepchecks `ppscore.py`,
`core/check_utils/feature_label_correlation_utils.py:79-149`,
`tabular/checks/data_integrity/identifier_label_correlation.py:70-149`.
Noted: per-feature single-feature tree, 4-fold CV, weighted F1 vs
max(mode, shuffled) baseline, `(score − base)/(1 − base)`; regression uses
MAE vs median; warn ≥ 0.8; any id/date signal > 0 fails. ydata
`typeset.py:314-322` lag autocorrelation ≥ 0.7 at lags {1, 7, 12, 24, 30}.

**M3 strings** — deepchecks `utils/strings.py:62-63,279-303`,
`tabular/checks/data_integrity/string_mismatch.py:85-100`,
`special_chars.py:110-143`, `mixed_nulls.py:32,123`,
`train_test_validation/string_mismatch_comparison.py:99-121`.

**M4 discrete numerics** — sweetviz `type_detection.py:30-41`
(`max_numeric_distinct_to_be_categorical = 10`, code uses ≤);
ydata `typeset_relations.py:44-47` (`low_categorical_threshold = 5`).

**M5 adversarial validation** — deepchecks
`core/check_utils/multivariate_drift_utils.py:39-139`,
`tabular/checks/train_test_validation/multivariate_drift.py:137`.
Noted: ≤ 10 000 rows a side, top 254 categories, 70/30 stratified split,
gradient boosting depth 2 × 10 iterations, score `max(2·AUC − 1, 0)`,
fail ≥ 0.25, permutation importance to name features.

**M6 associations** — sweetviz `from_dython.py:101-247`,
`dataframe_report.py:418-517`; ydata `correlations_pandas.py:38-68,154-207`;
deepchecks `utils/correlation_methods.py`,
`tabular/checks/data_integrity/feature_feature_correlation.py:84-101`.
Noted: sweetviz and deepchecks replace NaN with 0 first (`from_dython.py:49`)
— don't. ydata HIGH_CORRELATION ≥ 0.9.

**M7 column stats** — ydata `model/pandas/describe_numeric_pandas.py:23-163`,
`imbalance_pandas.py:30-35`, `model/alerts.py:583-688,764`,
`summary_algorithms.py:64-143`, `config_default.yaml`.

**M8 missing together** — ydata `model/pandas/missing_pandas.py:31-41`,
`model/missing.py:84-104`.

**M9 drift** — deepchecks `utils/distribution/drift.py:39-466`,
`utils/distribution/preprocessing.py:117-199`,
`utils/abstracts/feature_drift.py:165-169`.

**M10** — deepchecks `outlier_sample_detection.py:83-145`,
`utils/gower_distance.py:59-180`, `date_train_test_leakage_*.py`;
ydata `describe_categorical_pandas.py:56-150` (Unicode categories/scripts).
