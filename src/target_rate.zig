// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M1 — target rate per categorical level and per numeric bin, train and
//! test side by side (docs/PLAN.md). Idea from sweetviz (docs/prior-art.md).
//! STUB: `run` computes nothing yet.

const std = @import("std");
const an = @import("analyze.zig");
const bars = @import("bars.zig");

/// One level or bin of one feature.
pub const Row = struct {
    /// Level name, or the bin's range rendered as text. Arena-owned.
    label: []const u8,
    train_share: f64,
    /// Null when there is no test file.
    test_share: ?f64,
    /// Target rate in train (binary: share positive; numeric: mean).
    rate: f64,
};

pub const Feature = struct {
    column: usize,
    rows: []const Row,
    /// The ALL row: overall target rate in train.
    overall: f64,
};

/// Fill `cx.a.target_rates`, one entry per feature, and add the pure-rate
/// findings. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.target_rates.len == 0) return;
    try w.writeAll("\nTARGET RATE BY LEVEL / BIN\n");
    _ = bars;
}

test "M1: rates, shared bin edges, missing row, other pooling, pure-rate finding" {
    return error.SkipZigTest;
}
