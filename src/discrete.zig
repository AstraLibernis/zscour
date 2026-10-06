// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M4 — numeric columns that are really discrete: few distinct values,
//! often a consecutive-integer scale such as a 0–5 rating (docs/PLAN.md).
//! Rule from sweetviz / ydata-profiling (docs/prior-art.md). STUB.

const std = @import("std");
const an = @import("analyze.zig");

/// Mark discrete numeric columns (`Column.discrete`) and add findings. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

test "M4: the airline ratings are discrete, Age is not" {
    return error.SkipZigTest;
}
