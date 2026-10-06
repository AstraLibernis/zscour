// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M2 — single-feature predictive power, and leak checks on the id column
//! and on row order (docs/PLAN.md). Ideas from deepchecks' predictive power
//! score and identifier-label check, ydata's lag autocorrelation
//! (docs/prior-art.md). STUB: `run` computes nothing yet.

const std = @import("std");
const an = @import("analyze.zig");

pub const Score = struct {
    /// Column index, or null for row position in the file.
    column: ?usize,
    /// Out-of-fold improvement over the baseline, in [0, 1].
    power: f64,
    /// Univariate AUC for a binary target, else null.
    auc: ?f64,
};

/// Fill `cx.a.signal` (features ranked by power) and add leak findings. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

/// Area under the ROC curve of `score` for `positive`, by Mann–Whitney rank
/// sum with ties averaged. STUB.
pub fn auc(score: []const f64, positive: []const bool) error{NotImplemented}!f64 {
    _ = score;
    _ = positive;
    return error.NotImplemented;
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.signal.len == 0) return;
    try w.writeAll("\nSINGLE-FEATURE SIGNAL\n");
}

test "M2: planted id leak caught, shuffled not; AUC 0.5 on noise, 1 on a perfect split" {
    return error.SkipZigTest;
}
