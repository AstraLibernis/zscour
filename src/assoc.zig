// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M6 — associations between columns: Spearman (numeric × numeric),
//! bias-corrected Cramér's V and Theil's U (categorical × categorical),
//! correlation ratio η (numeric × categorical) (docs/PLAN.md). Formulas
//! from sweetviz, ydata-profiling, deepchecks (docs/prior-art.md). STUB.

const std = @import("std");
const an = @import("analyze.zig");

pub const Method = enum { spearman, cramers_v, theils_u, correlation_ratio };

pub const Pair = struct {
    a: usize,
    b: usize,
    method: Method,
    value: f64,
};

/// Fill `cx.a.associations` (feature ↔ target, and pairs ≥ 0.9). STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.associations.len == 0) return;
    try w.writeAll("\nASSOCIATIONS\n");
}

test "M6: each measure against a hand-computed example" {
    return error.SkipZigTest;
}
