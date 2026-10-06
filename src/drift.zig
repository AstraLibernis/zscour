// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Distribution shift between two samples of one column. KS and total
//! variation are live (M0); PSI, Wasserstein and Cramér's V drift are M9
//! (docs/PLAN.md), formulas from deepchecks (docs/prior-art.md).

const std = @import("std");

/// Two-sample Kolmogorov–Smirnov statistic over ascending samples.
pub fn ks(a: []const f64, b: []const f64) f64 {
    if (a.len == 0 or b.len == 0) return 0;
    const na: f64 = @floatFromInt(a.len);
    const nb: f64 = @floatFromInt(b.len);
    var i: usize = 0;
    var j: usize = 0;
    var d: f64 = 0;
    while (i < a.len and j < b.len) {
        const x = @min(a[i], b[j]);
        while (i < a.len and a[i] <= x) i += 1;
        while (j < b.len and b[j] <= x) j += 1;
        const fi: f64 = @floatFromInt(i);
        const fj: f64 = @floatFromInt(j);
        d = @max(d, @abs(fi / na - fj / nb));
    }
    return d;
}

/// Total variation distance between two level-count vectors.
pub fn tvd(a: []const usize, b: []const usize) f64 {
    var sa: usize = 0;
    var sb: usize = 0;
    for (a) |x| sa += x;
    for (b) |x| sb += x;
    if (sa == 0 or sb == 0) return 0;
    var d: f64 = 0;
    for (a, b) |x, y| d += @abs(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(sa)) - @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(sb)));
    return d / 2;
}

/// Population stability index over shared bins, shares floored. M9 STUB.
pub fn psi(a: []const usize, b: []const usize) error{NotImplemented}!f64 {
    _ = a;
    _ = b;
    return error.NotImplemented;
}

/// 1-D Wasserstein distance of min-max scaled ascending samples. M9 STUB.
pub fn wasserstein(a: []const f64, b: []const f64) error{NotImplemented}!f64 {
    _ = a;
    _ = b;
    return error.NotImplemented;
}

/// Bias-corrected Cramér's V of a 2 × k count table. M9 STUB.
pub fn cramersV(a: []const usize, b: []const usize) error{NotImplemented}!f64 {
    _ = a;
    _ = b;
    return error.NotImplemented;
}

const testing = std.testing;

test "ks and tvd" {
    try testing.expectEqual(@as(f64, 0), ks(&.{ 1, 2, 3 }, &.{ 1, 2, 3 }));
    try testing.expectEqual(@as(f64, 1), ks(&.{ 1, 2 }, &.{ 3, 4 }));
    try testing.expectApproxEqAbs(@as(f64, 0.5), ks(&.{ 1, 2, 3, 4 }, &.{ 3, 4, 5, 6 }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), tvd(&.{ 1, 1 }, &.{ 1, 0 }), 1e-12);
}

test "M9: psi, wasserstein, cramersV against hand computations" {
    return error.SkipZigTest;
}
