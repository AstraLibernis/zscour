# zscour

Audit a tabular dataset's CSV files before you model them, and optionally write
cleaned copies. Single static binary, no dependencies, no Python.

    zscour data/                                   # train.csv, test.csv, sample_submission.csv
    zscour data/ --extra original.csv --out clean/ # also check the source data; write cleaned files
    zscour --train a.csv --test b.csv --target y --id row_id

Exit status: **0** no errors · **1** errors found · **2** usage or I/O failure,
so it can gate a pipeline.

## What it checks

| Level | Checks |
|---|---|
| bytes | UTF-8 validity, BOM, NUL bytes, CRLF / bare CR / mixed line endings, final newline |
| records | CSV quoting errors (with record number), blank lines, records with the wrong field count |
| header | empty, duplicate and whitespace-padded column names |
| schema | test missing a train feature (or having an extra one), extra data's columns, column order |
| values | missing counts by kind (empty, `NA`/`NaN`/`null`/… markers, junk text in a numeric column, ±inf), two missing spellings in one column, whitespace padding, a few fractions in a whole-number column, case variants of one level (`Eco`/`eco`), mixed numeric/text columns, constant and very high-cardinality columns, missing markers used as categorical levels |
| across files | test levels never seen in train, test values outside train's range, train-vs-test shift (KS for numeric, total variation for categorical) — also for `--extra` |
| id | missing, duplicated, shared between train and test, unsorted, non-contiguous |
| target | inferred as the one train column test lacks; class balance; boolean spellings; extra-data levels absent from train |
| rows | rows whose features repeat an earlier row's, and those among them with a *different* target (irreducible error); test or train rows that exactly copy a train or extra row |
| submission | header is `id,<target>`, row count and ids match test row for row |

Values are compared typed, not as text: `4`, `4.0` and ` 4 ` are one value;
`Eco` and `ECO` one level. A column is numeric if ≥ 99 % of its non-missing
fields parse as numbers in every file combined, so a column cannot be numeric
in train and text in test. As in zarbor, `NA`-style markers mean missing only in
numeric columns; in a text column they may be real categories, so they are
kept and reported.

## What `--out` writes

`train.csv`, `test.csv`, `extra.csv` and `report.txt`. Only what the report
flagged is rewritten: whitespace trimmed, every missing value written as an
empty field, case variants folded to the most frequent spelling, a boolean
target written as `1`/`0`, rows sorted by id, columns in train's order, UTF-8
without BOM, LF line endings, RFC 4180 quoting. Malformed records are dropped.
Numbers keep their original text — nothing is re-formatted or rounded — and a
file with nothing to fix comes back byte-identical. The report ends with how
many values each column had rewritten.

Nothing is imputed, deduplicated or dropped for being an outlier: those are
modelling decisions, and the report gives you the counts to make them.

## Build

    zig build --release=fast      # zig 0.16; binary at zig-out/bin/zscour
    zig build test

The CSV parser is [zsift](https://github.com/AstraLibernis/zsift), vendored
(see `src/vendor/zsift/VENDORED.md`).

## Licence

GPL-3.0-or-later (`COPYING`). The vendored zsift is LGPL-3.0-or-later.
