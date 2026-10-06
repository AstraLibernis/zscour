// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Terminal drawing for the report: horizontal share bars (M1) and 8-level
//! sparkline histograms (M7). STUB: both draw nothing yet.

const std = @import("std");

/// A bar `share` (0–1) of `width` cells, eighth-cell resolution. STUB.
pub fn bar(w: *std.Io.Writer, share: f64, width: usize) std.Io.Writer.Error!void {
    _ = w;
    _ = share;
    _ = width;
}

/// One character per count, ▁ to █, scaled to the largest. STUB.
pub fn sparkline(w: *std.Io.Writer, counts: []const usize) std.Io.Writer.Error!void {
    _ = w;
    _ = counts;
}

test "bars: widths and sparkline levels" {
    return error.SkipZigTest;
}
