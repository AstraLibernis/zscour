// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M8 — columns that go missing together: Pearson correlation of the 0/1
//! missing indicators of partly-missing columns (docs/PLAN.md). Idea from
//! ydata-profiling (docs/prior-art.md). STUB.

const std = @import("std");
const an = @import("analyze.zig");

pub const Pair = struct { a: usize, b: usize, r: f64 };

/// Fill `cx.a.missing_together` with pairs at r ≥ 0.9. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

test "M8: perfectly co-missing columns pair at r = 1" {
    return error.SkipZigTest;
}
