// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M4 — numeric columns that are really discrete, and whether the target
//! follows them in order (docs/PLAN.md).
//!
//! The size rule is sweetviz's (`from_profiling_pandas.py:70`, re-read at
//! 4697e18, MIT): a numeric column with at most 10 distinct values is
//! categorical. ydata-profiling's 5 (`typeset_relations.py:44-47`,
//! `low_categorical_threshold`) misses a 0–5 rating (6 values) and 1–10
//! scales. Both tools stop at re-typing the column; zscour also says what
//! kind of discrete it is, and tests whether the target moves along it in
//! order — Pearson's comparison of the linear fit (r²) with the correlation
//! ratio (η²) over the column's values. A straight line that explains much
//! less than the values themselves means a model that treats the column as a
//! number loses signal, often to one value that is really a code.

const std = @import("std");
const an = @import("analyze.zig");
const tr = @import("target_rate.zig");

/// At most this many distinct values (all files together) is discrete.
pub const max_values = 10;

/// The linearity test runs when the values explain at least this share of
/// the target's variance — below it there is nothing to lose.
const min_eta2 = 0.01;
/// A straight line explaining less than this share of what the values
/// explain is reported.
const linear_share = 0.8;

pub const Kind = enum {
    /// Two values.
    binary,
    /// Consecutive whole numbers: an ordered scale such as a 0–5 rating.
    scale,
    /// Whole numbers with gaps: probably codes for categories.
    codes,
    /// A few non-whole values.
    decimals,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .binary => "binary",
            .scale => "integer scale",
            .codes => "integer codes",
            .decimals => "few decimals",
        };
    }
};

pub const Info = struct {
    kind: Kind,
    /// The distinct values over every file, ascending.
    values: []const f64,
};

/// Distinct values over the sorted samples of every file.
fn distinctUnion(arena: std.mem.Allocator, c: *const an.Column, limit: usize) !?[]const f64 {
    var out: std.ArrayList(f64) = .empty;
    for (c.per) |maybe| {
        const p = maybe orelse continue;
        var prev: ?f64 = null;
        for (p.sorted) |x| {
            if (prev != null and prev.? == x) continue;
            prev = x;
            const i = std.sort.lowerBound(f64, out.items, x, order);
            if (i < out.items.len and out.items[i] == x) continue;
            if (out.items.len == limit) return null;
            try out.insert(arena, i, x);
        }
    }
    return out.items;
}

fn order(a: f64, b: f64) std.math.Order {
    return std.math.order(a, b);
}

pub fn classify(values: []const f64) Kind {
    if (values.len <= 2) return .binary;
    for (values) |v| if (@floor(v) != v) return .decimals;
    const span = values[values.len - 1] - values[0] + 1;
    return if (span == @as(f64, @floatFromInt(values.len))) .scale else .codes;
}

pub const Linearity = struct {
    /// r² of the weighted straight line over η² of the values: 1 = the
    /// target moves along the column in order.
    share: f64,
    eta2: f64,
    /// The value farthest from the line, and its share of the gap.
    worst: f64,
    worst_share: f64,
};

/// Pearson's test of linearity over M1's per-value rows (value, labelled
/// count, target mean). Null when there are fewer than three values.
pub fn linearity(rows: []const tr.Row, ss_total: f64) ?Linearity {
    var n: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var k: usize = 0;
    for (rows) |r| {
        const x = r.value orelse continue;
        const m = r.rate orelse continue;
        if (r.labelled == 0) continue;
        const w: f64 = @floatFromInt(r.labelled);
        n += w;
        sx += w * x;
        sy += w * m;
        k += 1;
    }
    if (k < 3 or n == 0 or ss_total <= 0) return null;
    const mx = sx / n;
    const my = sy / n;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    var between: f64 = 0;
    for (rows) |r| {
        const x = r.value orelse continue;
        const m = r.rate orelse continue;
        if (r.labelled == 0) continue;
        const w: f64 = @floatFromInt(r.labelled);
        sxx += w * (x - mx) * (x - mx);
        sxy += w * (x - mx) * (m - my);
        between += w * (m - my) * (m - my);
    }
    if (between <= 0 or sxx <= 0) return null;
    const slope = sxy / sxx;
    const linear = slope * slope * sxx;
    var worst: f64 = 0;
    var worst_dev: f64 = -1;
    var gap: f64 = 0;
    for (rows) |r| {
        const x = r.value orelse continue;
        const m = r.rate orelse continue;
        if (r.labelled == 0) continue;
        const w: f64 = @floatFromInt(r.labelled);
        const fit = my + slope * (x - mx);
        const dev = w * (m - fit) * (m - fit);
        gap += dev;
        if (dev > worst_dev) {
            worst_dev = dev;
            worst = x;
        }
    }
    return .{
        .share = linear / between,
        .eta2 = between / ss_total,
        .worst = worst,
        .worst_share = if (gap > 0) worst_dev / gap else 0,
    };
}

fn featureOf(a: *const an.Analysis, ci: usize) ?*const tr.Feature {
    for (a.target_rates) |*f| if (f.column == ci) return f;
    return null;
}

/// Mark discrete numeric features (`Column.discrete`), add one summary note
/// per kind, and a note for each scale or code column the target does not
/// follow in order.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    var names: [4]std.ArrayList(u8) = .{ .empty, .empty, .empty, .empty };
    var counts = [4]usize{ 0, 0, 0, 0 };
    for (a.columns, 0..) |*c, ci| {
        if (c.kind != .numeric or c.use != .feature) continue;
        const values = (try distinctUnion(cx.arena, c, max_values)) orelse continue;
        if (values.len == 0) continue;
        const kind = classify(values);
        c.discrete = .{ .kind = kind, .values = values };
        const k = @intFromEnum(kind);
        counts[k] += 1;
        if (counts[k] <= 12) try names[k].print(cx.arena, "{s}{s} ({d}–{d})", .{ if (counts[k] > 1) ", " else "", c.name, values[0], values[values.len - 1] });

        if (kind == .binary or kind == .decimals or a.target_mode == .none) continue;
        const f = featureOf(a, ci) orelse continue;
        const lin = linearity(f.rows, a.target_ss) orelse continue;
        if (lin.eta2 < min_eta2 or lin.share >= linear_share) continue;
        // An end value that breaks the order is often a code ("0 = not
        // applicable"); a middle value means the relation bends.
        const at_end = lin.worst == values[0] or lin.worst == values[values.len - 1];
        if (at_end)
            try cx.add(.info, .discrete_numeric, .train, c.name, "the target does not follow this {s} in order: a straight line through its values explains {d:.0}% of what the values explain as categories (η² {d:.3}); the end value {d} departs most ({d:.0}% of the gap) — check whether {d} is a special code such as \"not applicable\", or treat the column as categories", .{ kind.label(), 100 * lin.share, lin.eta2, lin.worst, 100 * lin.worst_share, lin.worst })
        else
            try cx.add(.info, .discrete_numeric, .train, c.name, "the target does not follow this {s} in order: a straight line through its values explains {d:.0}% of what the values explain as categories (η² {d:.3}); the relation bends most at {d} ({d:.0}% of the gap) — treat the column as categories rather than a number", .{ kind.label(), 100 * lin.share, lin.eta2, lin.worst, 100 * lin.worst_share });
    }
    for (counts, names, 0..) |n, list, k| {
        if (n == 0) continue;
        const kind: Kind = @enumFromInt(k);
        try cx.add(.info, .discrete_numeric, null, null, "{d} numeric column{s} {s} {s} — at most {d} distinct values: {s}{s}", .{
            n,                          if (n > 1) "s" else "",
            if (n > 1) "are" else "is",
            switch (kind) {
                .binary => "binary",
                .scale => "integer scales (consecutive whole numbers, ordered)",
                .codes => "integer codes (whole numbers with gaps: categories more than a scale?)",
                .decimals => "a few decimal values",
            },
            max_values,                 list.items,
            if (n > 12) ", …" else "",
        });
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

fn analyzed(arena: std.mem.Allocator, train: []const u8, tst: ?[]const u8) !an.Analysis {
    var tables: std.ArrayList(tbl.Table) = .empty;
    try tables.append(arena, try tbl.parse(arena, .train, "train", train));
    if (tst) |t| try tables.append(arena, try tbl.parse(arena, .@"test", "test", t));
    return an.analyze(arena, tables.items, .{ .target = "y", .shift_warn = 1 });
}

test "classify" {
    try testing.expectEqual(Kind.binary, classify(&.{ 0, 1 }));
    try testing.expectEqual(Kind.scale, classify(&.{ 0, 1, 2, 3, 4, 5 }));
    try testing.expectEqual(Kind.codes, classify(&.{ 1, 2, 5, 9 }));
    try testing.expectEqual(Kind.decimals, classify(&.{ 0.5, 1, 1.5 }));
}

test "kinds over every file; more than 10 values is not discrete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var train: std.ArrayList(u8) = .empty;
    try train.appendSlice(arena, "id,rating,code,many,y\n");
    const codes = [_]u8{ 1, 3, 7 };
    for (0..60) |i| try train.print(arena, "{d},{d},{d},{d},{d}\n", .{ i, i % 5, codes[i % 3], i % 11, i % 2 });
    // Test adds rating 5: the scale is 0–5 over both files.
    const a = try analyzed(arena, train.items, "id,rating,code,many\n100,5,1,0\n");
    try testing.expectEqual(Kind.scale, a.columns[1].discrete.?.kind);
    try testing.expectEqual(@as(usize, 6), a.columns[1].discrete.?.values.len);
    try testing.expectEqual(Kind.codes, a.columns[2].discrete.?.kind);
    try testing.expect(a.columns[3].discrete == null);
    var notes: usize = 0;
    for (a.findings.items) |f| notes += @intFromBool(f.code == .discrete_numeric and f.column == null);
    try testing.expectEqual(@as(usize, 2), notes); // one per kind present
}

test "linearity: an in-order scale passes; a special end value is named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ false, true }) |special_zero| {
        var csv: std.ArrayList(u8) = .empty;
        try csv.appendSlice(arena, "id,r,y\n");
        // Rate rises 10% per step from 1 to 5. With `special_zero`, the
        // value 0 behaves like the top of the scale ("not applicable" rows
        // that are mostly satisfied); without, 0 continues the line.
        var id: usize = 0;
        for (0..6) |v| for (0..400) |j| {
            const rate: usize = if (v == 0 and special_zero) 90 else 10 + 10 * v;
            try csv.print(arena, "{d},{d},{d}\n", .{ id, v, @intFromBool(j % 100 < rate) });
            id += 1;
        };
        const a = try analyzed(arena, csv.items, null);
        var msg: ?[]const u8 = null;
        for (a.findings.items) |f| if (f.code == .discrete_numeric and f.column != null) {
            msg = f.msg;
        };
        if (special_zero) {
            try testing.expect(std.mem.find(u8, msg.?, "the end value 0 departs most") != null);
        } else {
            try testing.expect(msg == null);
        }
    }
}

test "linearity numbers on a hand-checked case" {
    // Values 0, 1, 2 with equal weight and means 0, 1, 0: the best line is
    // flat (slope 0), so it explains nothing; the middle value departs most.
    const rows = [_]tr.Row{
        .{ .kind = .value, .label = "0", .train_count = 10, .train_share = 0, .test_share = null, .rate = 0, .extra_rate = null, .labelled = 10, .value = 0 },
        .{ .kind = .value, .label = "1", .train_count = 10, .train_share = 0, .test_share = null, .rate = 1, .extra_rate = null, .labelled = 10, .value = 1 },
        .{ .kind = .value, .label = "2", .train_count = 10, .train_share = 0, .test_share = null, .rate = 0, .extra_rate = null, .labelled = 10, .value = 2 },
    };
    const lin = linearity(&rows, 10).?;
    try testing.expectApproxEqAbs(@as(f64, 0), lin.share, 1e-12);
    try testing.expectEqual(@as(f64, 1), lin.worst);
    // between = 10·(1/3)² + 10·(2/3)² + 10·(1/3)² = 60/9; η² = (60/9)/10.
    try testing.expectApproxEqAbs(@as(f64, 6.0 / 9.0), lin.eta2, 1e-12);
}

test "a middle value that breaks the order is a bend, not a special code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,r,y\n");
    // Rate 20% at 1, 2, 4, 5 but 80% at 3: a peak in the middle.
    var id: usize = 0;
    for (1..6) |v| for (0..400) |j| {
        const rate: usize = if (v == 3) 80 else 20;
        try csv.print(arena, "{d},{d},{d}\n", .{ id, v, @intFromBool(j % 100 < rate) });
        id += 1;
    };
    const a = try analyzed(arena, csv.items, null);
    var msg: ?[]const u8 = null;
    for (a.findings.items) |f| if (f.code == .discrete_numeric and f.column != null) {
        msg = f.msg;
    };
    try testing.expect(std.mem.find(u8, msg.?, "bends most at 3") != null);
    try testing.expect(std.mem.find(u8, msg.?, "special code") == null);
}

test "a bend that explains almost nothing is not reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,r,y\n");
    // Rates zig-zag 50% / 51%: far from a line, but η² ≈ 0.0001.
    var id: usize = 0;
    for (1..6) |v| for (0..1000) |j| {
        const rate: usize = if (v % 2 == 0) 51 else 50;
        try csv.print(arena, "{d},{d},{d}\n", .{ id, v, @intFromBool(j % 100 < rate) });
        id += 1;
    };
    const a = try analyzed(arena, csv.items, null);
    for (a.findings.items) |f| try testing.expect(!(f.code == .discrete_numeric and f.column != null));
}
