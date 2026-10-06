// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Terminal drawing for the report: horizontal share bars (M1) and 8-level
//! sparkline histograms (M7). Block characters, so a bar resolves to an
//! eighth of a cell.

const std = @import("std");

/// Partial cells, 1/8 to 7/8 wide.
const eighths = [_][]const u8{ "▏", "▎", "▍", "▌", "▋", "▊", "▉" };
const full = "█";
/// Sparkline levels, lowest to highest.
const levels = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };

/// A bar `share` (clamped to 0–1) of `width` cells, padded with spaces to
/// exactly `width` cells. A nonzero share always shows at least 1/8 cell, so
/// "small" is never drawn as "none".
pub fn bar(w: *std.Io.Writer, share: f64, width: usize) std.Io.Writer.Error!void {
    const s = if (std.math.isNan(share)) 0 else std.math.clamp(share, 0, 1);
    const total_eighths: usize = @intFromFloat(@round(s * @as(f64, @floatFromInt(width * 8))));
    const shown = if (s > 0 and total_eighths == 0) 1 else total_eighths;
    const cells = shown / 8;
    const rest = shown % 8;
    for (0..cells) |_| try w.writeAll(full);
    if (rest > 0) try w.writeAll(eighths[rest - 1]);
    const used = cells + @intFromBool(rest > 0);
    try w.splatByteAll(' ', width - used);
}

/// One character per count, ▁ to █, scaled to the largest; a zero count is
/// a space so empty bins stay visible as gaps.
pub fn sparkline(w: *std.Io.Writer, counts: []const usize) std.Io.Writer.Error!void {
    var top: usize = 0;
    for (counts) |k| top = @max(top, k);
    for (counts) |k| {
        if (k == 0) {
            try w.writeByte(' ');
            continue;
        }
        // ceil(k·8/top) − 1: the largest count is █, any nonzero count ≥ ▁.
        const level = (k * levels.len + top - 1) / top - 1;
        try w.writeAll(levels[level]);
    }
}

const testing = std.testing;

fn drawn(comptime f: anytype, args: anytype) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer buf.deinit();
    try @call(.auto, f, .{&buf.writer} ++ args);
    return buf.toOwnedSlice();
}

test "bar: full, empty, eighths, tiny shares still show, always `width` cells" {
    const cases = [_]struct { share: f64, want: []const u8 }{
        .{ .share = 1, .want = "████" },
        .{ .share = 0, .want = "    " },
        .{ .share = 0.5, .want = "██  " },
        .{ .share = 0.5 + 1.0 / 32.0, .want = "██▏ " },
        .{ .share = 0.001, .want = "▏   " },
        .{ .share = 7.0 / 32.0, .want = "▉   " },
        .{ .share = 2, .want = "████" },
        .{ .share = std.math.nan(f64), .want = "    " },
    };
    for (cases) |c| {
        const got = try drawn(bar, .{ c.share, 4 });
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "sparkline: zero is a gap, max is a full block, small nonzero is the lowest level" {
    const got = try drawn(sparkline, .{@as([]const usize, &.{ 0, 1, 50, 100, 13 })});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(" ▁▄█▂", got);
}
