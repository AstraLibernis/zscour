// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M5 — adversarial validation: can a classifier tell train rows from test
//! rows? Fits zarbor's GBDT on train-vs-test labels and scores held-out AUC
//! as max(2·AUC − 1, 0) (docs/PLAN.md). Idea from deepchecks' multivariate
//! drift (docs/prior-art.md). STUB: zarbor is not a dependency yet.

const std = @import("std");
const an = @import("analyze.zig");

pub const Result = struct {
    /// The two files compared, e.g. train vs test.
    a: an.Role,
    b: an.Role,
    auc: f64,
    /// max(2·AUC − 1, 0): 0 = indistinguishable, 1 = fully separable.
    drift: f64,
    /// Features the classifier leans on, strongest first.
    top: []const struct { column: usize, importance: f64 },
};

/// Fill `cx.a.adversarial` for train vs test, and train vs extra. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.adversarial.len == 0) return;
    try w.writeAll("\nADVERSARIAL VALIDATION\n");
}

test "M5: identical files score ~0, a planted shifted feature is found and named" {
    return error.SkipZigTest;
}
