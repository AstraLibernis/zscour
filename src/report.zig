// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The text report: files, one line per column, then findings by severity.

const std = @import("std");
const an = @import("analyze.zig");
const Analysis = an.Analysis;
const Column = an.Column;
const Role = @import("table.zig").Role;

const Writer = std.Io.Writer;

pub fn write(w: *Writer, a: *const Analysis) Writer.Error!void {
    try w.print("zscour · {d} files · {d} errors · {d} warnings · {d} notes\n\n", .{ a.tables.len, a.count(.err), a.count(.warn), a.count(.info) });

    try w.writeAll("FILES\n");
    for (a.tables) |t| {
        try w.print("  {s: <6} {s}  {d} rows × {d} columns\n", .{ t.role.label(), t.path, t.n_rows, t.names.len });
    }

    try w.writeAll("\nCOLUMNS   (missing counts per file: train / test / extra)\n");
    var width: usize = 6;
    for (a.columns) |c| width = @max(width, c.name.len);
    for (a.columns) |*c| try columnLine(w, c, width);

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

fn columnLine(w: *Writer, c: *const Column, width: usize) Writer.Error!void {
    try w.print("  {s}", .{c.name});
    try w.splatByteAll(' ', width - c.name.len + 2);
    const tag: []const u8 = switch (c.use) {
        .id => "id ",
        .target => "tgt",
        .feature => "   ",
    };
    switch (c.kind) {
        .numeric => try w.print("{s} {s: <5}", .{ tag, if (c.integral) "int" else "float" }),
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
            for (c.levels, p.level_counts, 0..) |lvl, k, i| {
                if (i == 4) {
                    try w.print(" · … {d} more", .{c.levels.len - 4});
                    break;
                }
                const share = if (total == 0) 0 else 100.0 * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(total));
                try w.print("{s}{s} {d:.1}%", .{ if (i > 0) " · " else "", lvl, share });
            }
        },
        .empty => {},
    }
    // Shift against train, always shown so "small" can be seen, not assumed.
    if (c.use != .id) if (c.at(.train)) |train| for ([_]Role{ .@"test", .extra }) |r| {
        const o = c.at(r) orelse continue;
        const d = switch (c.kind) {
            .numeric => an.ks(train.sorted, o.sorted),
            .categorical => an.tvd(train.level_counts, o.level_counts),
            .empty => continue,
        };
        try w.print("   {s} {s} {d:.4}", .{ if (c.kind == .numeric) "KS" else "TV", r.label(), d });
    };
    try w.writeAll("\n");
}
