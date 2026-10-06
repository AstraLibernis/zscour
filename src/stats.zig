// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M7 — more per-column statistics: skewness, excess kurtosis, share of
//! zeros and negatives, imbalance score, monotonicity, lag autocorrelation
//! (docs/PLAN.md). Definitions from ydata-profiling (docs/prior-art.md).
//! STUB.

const std = @import("std");
const an = @import("analyze.zig");

pub const Extra = struct {
    column: usize,
    skew: f64,
    kurtosis: f64,
    zeros: f64,
    negatives: f64,
    /// 1 − H(levels)/log2(k): 0 = balanced, 1 = one level.
    imbalance: f64,
    /// +2/−2 strictly increasing/decreasing in file order, ±1 non-strict, 0 neither.
    monotonic: i8,
    lag1: f64,
};

/// Fill `cx.a.column_stats` and add skew / imbalance / ordering findings. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

test "M7: moments and imbalance against a hand computation" {
    return error.SkipZigTest;
}
