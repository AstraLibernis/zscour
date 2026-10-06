// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M3 — spelling variants beyond case, punctuation-only values, missing
//! markers matched on base form (docs/PLAN.md). Base-form rule from
//! deepchecks (docs/prior-art.md). STUB: `run` adds nothing yet; the
//! case-only check in analyze.zig is still the live one.

const std = @import("std");
const an = @import("analyze.zig");

/// Base form of a value: alphanumerics only, lowercased; the value itself if
/// that leaves nothing. Written into `buf`. STUB: returns `s` unchanged.
pub fn baseForm(buf: []u8, s: []const u8) []const u8 {
    _ = buf;
    return s;
}

/// Add spelling-variant, punctuation-only and base-form missing-marker
/// findings for every categorical column. STUB.
pub fn run(cx: an.Ctx) !void {
    _ = cx;
}

test "M3: base-form grouping, empty-base fallback, clean uses one spelling" {
    return error.SkipZigTest;
}
