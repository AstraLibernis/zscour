// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The text report: files, one line per column, then findings by severity.

const std = @import("std");
const an = @import("analyze.zig");
const Analysis = an.Analysis;
const Column = an.Column;
const Role = @import("table.zig").Role;
const drift = @import("drift.zig");
const target_rate = @import("target_rate.zig");
const signal = @import("signal.zig");
const adversarial = @import("adversarial.zig");
const assoc = @import("assoc.zig");
const stats = @import("stats.zig");
const missingness = @import("missingness.zig");

const Writer = std.Io.Writer;

/// `limit`: features in the target-rate and signal sections; 0 = all.
pub fn write(w: *Writer, a: *const Analysis, limit: usize) Writer.Error!void {
    try w.print("zscour · {d} files · {d} errors · {d} warnings · {d} notes\n\n", .{ a.tables.len, a.count(.err), a.count(.warn), a.count(.info) });

    try w.writeAll("FILES\n");
    for (a.tables) |t| {
        try w.print("  {s: <6} {s}  {d} rows × {d} columns\n", .{ t.role.label(), t.path, t.n_rows, t.names.len });
    }

    try w.writeAll("\nCOLUMNS   (missing counts per file: train / test / extra)\n");
    var width: usize = 6;
    for (a.columns) |c| width = @max(width, c.name.len);
    for (a.columns, 0..) |*c, ci| try columnLine(w, c, width, a.column_stats, ci);

    // Milestone sections (docs/PLAN.md); each prints nothing until built.
    try signal.write(w, a, limit);
    try target_rate.write(w, a, limit);
    try adversarial.write(w, a);
    try assoc.write(w, a, limit);
    try missingness.write(w, a);

    for ([_]an.Severity{ .err, .warn, .info }) |sev| {
        const n = a.count(sev);
        if (n == 0) continue;
        try w.print("\n{s} ({d})\n", .{ switch (sev) {
            .err => "ERRORS",
            .warn => "WARNINGS",
            .info => "NOTES",
        }, n });
        for (a.findings.items) |f| {
            if (f.sev != sev) continue;
            try w.print("  {s} ", .{switch (sev) {
                .err => "✗",
                .warn => "!",
                .info => "·",
            }});
            if (f.table) |r| try w.print("[{s}] ", .{r.label()});
            if (f.column) |col| try w.print("{s}: ", .{col});
            try w.print("{s}\n", .{f.msg});
        }
    }
}

fn columnLine(w: *Writer, c: *const Column, width: usize, a_stats: []const stats.Extra, ci: usize) Writer.Error!void {
    try w.print("  {s}", .{c.name});
    try w.splatByteAll(' ', width - c.name.len + 2);
    const tag: []const u8 = switch (c.use) {
        .id => "id ",
        .target => "tgt",
        .feature => "   ",
    };
    switch (c.kind) {
        .numeric => try w.print("{s} {s: <5}", .{ tag, if (c.discrete) |d| switch (d.kind) {
            .binary => "bin",
            .scale => "scale",
            .codes => "codes",
            .decimals => "few",
        } else if (c.integral) "int" else "float" }),
        .categorical => try w.print("{s} cat{d: <2}", .{ tag, c.levels.len }),
        .empty => try w.print("{s} empty", .{tag}),
    }
    try w.writeAll("  miss ");
    for ([_]Role{ .train, .@"test", .extra }, 0..) |r, i| {
        if (i > 0) try w.writeAll(" / ");
        if (c.at(r)) |p| try w.print("{d}", .{p.missingCount(c.kind)}) else try w.writeAll("-");
    }
    const p = c.at(.train) orelse c.at(.@"test") orelse c.at(.extra) orelse {
        try w.writeAll("\n");
        return;
    };
    switch (c.kind) {
        .numeric => try w.print("   min {d} · p50 {d} · max {d}", .{ p.quantile(0), p.quantile(0.5), p.quantile(1) }),
        .categorical => {
            var total: usize = 0;
            for (p.level_counts) |k| total += k;
            try w.writeAll("   ");
            // The most frequent levels, found without allocating: repeated
            // passes for the next largest count below the previous one.
            const show = @min(c.levels.len, 4);
            var prev_count: usize = std.math.maxInt(usize);
            var prev_id: usize = 0;
            for (0..show) |i| {
                var best: ?usize = null;
                for (p.level_counts, 0..) |k, id| {
                    const after_prev = k < prev_count or (k == prev_count and id > prev_id);
                    if (!after_prev) continue;
                    if (best == null or k > p.level_counts[best.?]) best = id;
                }
                const id = best orelse break;
                prev_count = p.level_counts[id];
                prev_id = id;
                const share = if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(prev_count)) / @as(f64, @floatFromInt(total));
                try w.print("{s}{s} {d:.1}%", .{ if (i > 0) " · " else "", c.levels[id], share });
            }
            if (c.levels.len > show) try w.print(" · … {d} more", .{c.levels.len - show});
        },
        .empty => {},
    }
    // M7: the shape, as a sparkline, and skew.
    for (a_stats) |*e| if (e.column == ci) try stats.writeShort(w, e);
    // Shift against train, always shown so "small" can be seen, not assumed.
    if (c.use != .id) if (c.at(.train)) |train| for ([_]Role{ .@"test", .extra }) |r| {
        const o = c.at(r) orelse continue;
        const d = switch (c.kind) {
            .numeric => drift.ks(train.sorted, o.sorted),
            .categorical => drift.tvd(train.level_counts, o.level_counts),
            .empty => continue,
        };
        try w.print("   {s} {s} {d:.4}", .{ if (c.kind == .numeric) "KS" else "TV", r.label(), d });
    };
    try w.writeAll("\n");
}

test "column line lists categorical levels most frequent first" {
    const testing = std.testing;
    const tbl = @import("table.zig");
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tables = [_]tbl.Table{try tbl.parse(arena, .train, "train", "id,c\n0,rare\n1,top\n2,top\n3,top\n4,mid\n5,mid\n6,x\n7,y\n")};
    const a = try an.analyze(arena, &tables, .{});
    var buf: Writer.Allocating = .init(arena);
    try columnLine(&buf.writer, &a.columns[1], 4, a.column_stats, 1);
    try testing.expect(std.mem.find(u8, buf.written(), "top 37.5% · mid 25.0% · rare 12.5% · x 12.5% · … 1 more") != null);
}
