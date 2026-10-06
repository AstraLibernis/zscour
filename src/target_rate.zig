// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M1 — target rate per categorical level and per numeric bin, train and
//! test side by side (docs/PLAN.md).
//!
//! From sweetviz (MIT; docs/prior-art.md), re-read at 4697e18:
//! `series_analyzer_cat.py:38-134` — per level, rate = sum(target)/count for
//! a boolean target, mean(target) for a numeric one, plus an ALL row;
//! `utils.py:6-61` — top levels by train count, the rest pooled into one
//! "Others" row that test is matched against.
//!
//! Where zscour differs, and why:
//! - Numeric bins hold equal shares of train's rows and never split a run of
//!   equal values (`binEdges`), not sweetviz's equal-width bins
//!   (`graph_numeric.py`). Equal width puts a skewed column into one bin;
//!   plain quantile edges, merged where they repeat, do the same to a spike
//!   (91% zero delays in the airline data gave a single bin [0, 489]).
//! - Few-valued numerics get a row per value, not bins.
//! - Missing values are a row of their own. sweetviz drops them from the
//!   bars; its `fillna(num_bins - 1)` only rescues the column maximum that
//!   `pd.cut(right=False)` leaves outside every bin (and on the compare
//!   side refills train's series, `graph_numeric.py:146`, so test's maximum
//!   is lost).

const std = @import("std");
const an = @import("analyze.zig");
const bars = @import("bars.zig");
const Role = an.Role;

/// Rows per feature before the tail is pooled into "other", and the most
/// distinct values a numeric may have to get a row per value.
pub const max_rows = 10;

/// A level or bin covering at least this share of train, with a binary
/// target rate of exactly 0 or 1, is reported as a pure rule.
const pure_min_share = 0.01;
/// …and at least this many train rows, so a pure rate is not just a small
/// sample.
const pure_min_rows = 30;

pub const RowKind = enum { value, other, missing };

/// One level, value or bin of one feature.
pub const Row = struct {
    kind: RowKind,
    /// Level name, value, or bin range "[a, b)". Arena-owned.
    label: []const u8,
    train_count: usize,
    train_share: f64,
    /// Null when there is no test file.
    test_share: ?f64,
    /// Train target rate; null when the row has no labelled train rows or
    /// the target is multiclass.
    rate: ?f64,
    /// The same rate in the extra file, when it has a target.
    extra_rate: ?f64,
};

pub const Feature = struct {
    column: usize,
    rows: []const Row,
    /// Bins instead of a row per level/value.
    binned: bool,
    /// Correlation ratio η² of the target over this feature's rows: the
    /// share of the target's train variance explained by the row means.
    /// The section is ranked by it. Null for a multiclass target.
    eta2: ?f64,
};

/// What "rate" means for this target.
pub const TargetMode = union(enum) {
    /// Share of rows in the positive class, named by `label`.
    binary: struct { label: []const u8 },
    /// Mean of a numeric target.
    mean,
    /// Multiclass: shares are shown, no rate.
    none,
};

/// Per-row target as a number: 1/0 for a binary target, the value for a
/// numeric one; NaN when missing. Null for a multiclass target.
fn targetValues(cx: an.Ctx, role: Role, mode: TargetMode, positive: f64) !?[]const f64 {
    const a = cx.a;
    const c = &a.columns[a.target orelse return null];
    const p = c.at(role) orelse return null;
    if (mode == .none) return null;
    const y = try cx.arena.alloc(f64, p.n);
    switch (c.kind) {
        .numeric => for (y, p.num) |*v, x| {
            v.* = if (std.math.isNan(x)) x else if (mode == .binary) @floatFromInt(@intFromBool(x == positive)) else x;
        },
        .categorical => for (y, p.cat) |*v, id| {
            v.* = if (id == an.no_level) std.math.nan(f64) else @floatFromInt(@intFromBool(@as(f64, @floatFromInt(id)) == positive));
        },
        .empty => return null,
    }
    return y;
}

/// Decide the rate's meaning. `positive` is the positive class: a level id
/// (categorical) or a value (numeric).
fn targetMode(a: *const an.Analysis) struct { TargetMode, f64 } {
    const c = &a.columns[a.target orelse return .{ .none, 0 }];
    const train = c.at(.train) orelse return .{ .none, 0 };
    switch (c.kind) {
        .categorical => {
            if (c.levels.len != 2) return .{ .none, 0 };
            // A boolean spelling names its positive class; otherwise the
            // minority class is the one worth a rate.
            const pos: u32 = a.target_positive orelse
                if (train.level_counts[1] <= train.level_counts[0]) 1 else 0;
            return .{ .{ .binary = .{ .label = c.levels[pos] } }, @floatFromInt(pos) };
        },
        .numeric => {
            const s = train.sorted;
            if (s.len == 0) return .{ .none, 0 };
            const lo = s[0];
            const hi = s[s.len - 1];
            var two = lo != hi;
            for (s) |x| two = two and (x == lo or x == hi);
            if (two) return .{ .{ .binary = .{ .label = "" } }, hi }; // label set in run
            return .{ .mean, 0 };
        },
        .empty => return .{ .none, 0 },
    }
}

/// How rows of one feature map to table rows.
const Layout = struct {
    labels: std.ArrayList([]const u8) = .empty,
    kinds: std.ArrayList(RowKind) = .empty,
    binned: bool = false,
    /// Categorical: level id → row.
    level_row: []u32 = &.{},
    /// Numeric per value: the values, ascending. Binned: the bin edges.
    points: []const f64 = &.{},
    other_row: ?u32 = null,
    missing_row: u32 = 0,

    fn add(l: *Layout, arena: std.mem.Allocator, kind: RowKind, label: []const u8) !u32 {
        try l.labels.append(arena, label);
        try l.kinds.append(arena, kind);
        return @intCast(l.labels.items.len - 1);
    }

    fn rowOf(l: *const Layout, c: *const an.Column, p: *const an.PerTable, r: usize) u32 {
        switch (c.kind) {
            .categorical => {
                const id = p.cat[r];
                return if (id == an.no_level) l.missing_row else l.level_row[id];
            },
            .numeric => {
                const x = p.num[r];
                if (std.math.isNan(x)) return l.missing_row;
                if (l.binned) {
                    // Bin i is [e_i, e_{i+1}); the last bin also takes its
                    // upper edge, and values beyond the train range clamp to
                    // the end bins.
                    const n_bins = l.points.len - 1;
                    const i = std.sort.upperBound(f64, l.points, x, orderF64);
                    return @intCast(std.math.clamp(i, 1, n_bins) - 1);
                }
                const i = std.sort.lowerBound(f64, l.points, x, orderF64);
                if (i < l.points.len and l.points[i] == x) return @intCast(i);
                return l.other_row.?;
            },
            .empty => return l.missing_row,
        }
    }
};

fn orderF64(a: f64, b: f64) std.math.Order {
    return std.math.order(a, b);
}

/// Shortest text for a number: integers without a fraction, others to four
/// decimals with trailing zeros dropped.
fn fmtNum(arena: std.mem.Allocator, x: f64) ![]const u8 {
    if (@floor(x) == x and @abs(x) < 1e15) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(x))});
    const s = try std.fmt.allocPrint(arena, "{d:.4}", .{x});
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
}

const Edges = struct {
    /// Bin i is [edges[i], edges[i+1]); the last bin also holds its upper
    /// edge. Starts are strictly increasing; the final upper edge may equal
    /// the last start when the last bin is a single value.
    edges: []const f64,
    /// Bin i holds one distinct value.
    single: []const bool,
};

/// Equal-count bins over ascending `s` that never split a run of equal
/// values: each cut aims at an equal share of the rows still unbinned, then
/// moves forward to the end of the value it landed in. A spike (91% zeros)
/// becomes one bin and the rest is still divided into the remaining bins;
/// plain quantile edges would merge it all into one.
fn binEdges(arena: std.mem.Allocator, s: []const f64, max_bins: usize) !Edges {
    var edges: std.ArrayList(f64) = .empty;
    var single: std.ArrayList(bool) = .empty;
    var pos: usize = 0;
    var bins_left = max_bins;
    while (pos < s.len) : (bins_left -= 1) {
        try edges.append(arena, s[pos]);
        var cut = s.len;
        if (bins_left > 1) {
            const target = @max(1, (s.len - pos) / bins_left);
            cut = @min(s.len, pos + target);
            cut = std.sort.upperBound(f64, s, s[cut - 1], orderF64);
        }
        try single.append(arena, s[pos] == s[cut - 1]);
        pos = cut;
    }
    try edges.append(arena, s[s.len - 1]);
    return .{ .edges = edges.items, .single = single.items };
}

fn layout(cx: an.Ctx, c: *const an.Column, train: *const an.PerTable) !Layout {
    const arena = cx.arena;
    var l: Layout = .{};
    switch (c.kind) {
        .categorical => {
            const order = try arena.alloc(u32, c.levels.len);
            for (order, 0..) |*o, i| o.* = @intCast(i);
            const Ctx = struct {
                counts: []const usize,
                fn more(ctx: @This(), x: u32, y: u32) bool {
                    return ctx.counts[x] > ctx.counts[y];
                }
            };
            std.mem.sort(u32, order, Ctx{ .counts = train.level_counts }, Ctx.more);
            const shown = if (order.len <= max_rows) order.len else max_rows - 1;
            l.level_row = try arena.alloc(u32, c.levels.len);
            for (order[0..shown]) |id| l.level_row[id] = try l.add(arena, .value, c.levels[id]);
            if (shown < order.len) {
                const other = try l.add(arena, .other, try std.fmt.allocPrint(arena, "other ({d} levels)", .{order.len - shown}));
                for (order[shown..]) |id| l.level_row[id] = other;
                l.other_row = other;
            }
        },
        .numeric => {
            const s = train.sorted;
            var distinct: std.ArrayList(f64) = .empty;
            for (s, 0..) |x, i| {
                if (i > 0 and x == s[i - 1]) continue;
                if (distinct.items.len == max_rows) break;
                try distinct.append(arena, x);
            }
            const few = distinct.items.len < max_rows or s.len == 0 or s[s.len - 1] == distinct.items[distinct.items.len - 1];
            if (few) {
                l.points = distinct.items;
                for (distinct.items) |x| _ = try l.add(arena, .value, try fmtNum(arena, x));
                // Test values train never had.
                l.other_row = try l.add(arena, .other, "other values");
            } else {
                l.binned = true;
                const edges = try binEdges(arena, s, max_rows);
                l.points = edges.edges;
                for (edges.edges[0 .. edges.edges.len - 1], edges.edges[1..], edges.single, 0..) |lo, hi, one, i| {
                    const last = i == edges.edges.len - 2;
                    _ = try l.add(arena, .value, if (one)
                        try fmtNum(arena, lo)
                    else
                        try std.fmt.allocPrint(arena, "[{s}, {s}{s}", .{ try fmtNum(arena, lo), try fmtNum(arena, hi), if (last) "]" else ")" }));
                }
            }
        },
        .empty => {},
    }
    l.missing_row = try l.add(arena, .missing, "(missing)");
    return l;
}

/// Fill `cx.a.target_rates`, one entry per feature, and add the pure-rate
/// findings.
///
/// Rows are built for every feature and for the target column itself, with or
/// without a target: the HTML report draws every column's distribution from
/// them. Rates exist only for features of a dataset with a target.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    var mode, const positive = targetMode(a);
    if (mode == .binary and mode.binary.label.len == 0) mode.binary.label = try fmtNum(cx.arena, positive);
    const y_train = try targetValues(cx, .train, mode, positive);
    const y_extra = try targetValues(cx, .extra, mode, positive);
    // Total sum of squares of the train target, for η².
    var y_mean: f64 = 0;
    var y_ss: f64 = 0;
    if (y_train) |y| {
        var k: f64 = 0;
        for (y) |v| if (!std.math.isNan(v)) {
            k += 1;
            const d = v - y_mean;
            y_mean += d / k;
            y_ss += d * (v - y_mean);
        };
    }

    var out: std.ArrayList(Feature) = .empty;
    for (a.columns, 0..) |*c, ci| {
        if (c.use == .id or c.kind == .empty) continue;
        const train = c.at(.train) orelse continue;
        var l = try layout(cx, c, train);
        const n_rows = l.labels.items.len;

        const counts = try cx.arena.alloc([3]usize, n_rows); // train, test, extra
        const sums = try cx.arena.alloc([2]f64, n_rows); // train, extra
        const labelled = try cx.arena.alloc([2]usize, n_rows);
        @memset(counts, .{ 0, 0, 0 });
        @memset(sums, .{ 0, 0 });
        @memset(labelled, .{ 0, 0 });
        for ([_]Role{ .train, .@"test", .extra }, 0..) |role, k| {
            const p = c.at(role) orelse continue;
            const y = if (c.use == .target) null else switch (role) {
                .train => y_train,
                .extra => y_extra,
                else => null,
            };
            for (0..p.n) |r| {
                const row = l.rowOf(c, p, r);
                counts[row][k] += 1;
                const yv = (y orelse continue)[r];
                if (std.math.isNan(yv)) continue;
                const j: usize = if (role == .train) 0 else 1;
                sums[row][j] += yv;
                labelled[row][j] += 1;
            }
        }

        const tst = c.at(.@"test");
        // Between-row sum of squares; η² = between / total (sweetviz's
        // correlation ratio, `from_dython.py:189-247`, squared).
        var between: f64 = 0;
        for (sums, labelled) |sm, k| if (k[0] > 0) {
            const nk: f64 = @floatFromInt(k[0]);
            const d = sm[0] / nk - y_mean;
            between += nk * d * d;
        };
        const eta2: ?f64 = if (y_train == null or c.use == .target) null else if (y_ss > 0) between / y_ss else 0;
        var rows: std.ArrayList(Row) = .empty;
        for (0..n_rows) |i| {
            const kind = l.kinds.items[i];
            // Empty "other"/"missing" rows are noise; empty value rows are not
            // possible for train, and a level only test has is still shown.
            if (kind != .value and counts[i][0] == 0 and counts[i][1] == 0) continue;
            const row: Row = .{
                .kind = kind,
                .label = l.labels.items[i],
                .train_count = counts[i][0],
                .train_share = share(counts[i][0], train.n),
                .test_share = if (tst) |t| share(counts[i][1], t.n) else null,
                .rate = if (y_train != null and labelled[i][0] > 0) sums[i][0] / @as(f64, @floatFromInt(labelled[i][0])) else null,
                .extra_rate = if (y_extra != null and labelled[i][1] > 0) sums[i][1] / @as(f64, @floatFromInt(labelled[i][1])) else null,
            };
            try rows.append(cx.arena, row);
            if (mode == .binary and kind != .other) if (row.rate) |rate| {
                if ((rate == 0 or rate == 1) and row.train_share >= pure_min_share and row.train_count >= pure_min_rows)
                    try cx.add(.info, .pure_rate, .train, c.name, "{s} = {s} ({d} rows, {d:.1}% of train) is {d:.0}% {s}", .{ c.name, row.label, row.train_count, 100 * row.train_share, 100 * rate, mode.binary.label });
            };
        }
        try out.append(cx.arena, .{ .column = ci, .rows = rows.items, .binned = l.binned, .eta2 = eta2 });
    }
    if (y_train != null) std.mem.sort(Feature, out.items, {}, moreExplained);
    a.target_rates = out.items;
    a.target_mode = mode;
}

/// Highest η² first; columns without one (the target) after, in file order.
fn moreExplained(_: void, x: Feature, y: Feature) bool {
    return (x.eta2 orelse -1) > (y.eta2 orelse -1);
}

fn share(k: usize, n: usize) f64 {
    if (n == 0) return 0;
    return @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
}

const bar_width = 10;

/// `limit`: features shown, highest η² first; 0 shows all.
pub fn write(w: *std.Io.Writer, a: *const an.Analysis, limit: usize) std.Io.Writer.Error!void {
    if (a.target == null) return;
    var features: usize = 0;
    for (a.target_rates) |f| features += @intFromBool(a.columns[f.column].use == .feature);
    if (features == 0) return;
    const shown = if (limit == 0) features else @min(limit, features);
    const target = a.columns[a.target.?].name;
    try w.writeAll("\nTARGET RATE BY LEVEL / BIN");
    switch (a.target_mode) {
        .binary => |b| try w.print("   rate = share of {s} = {s}", .{ target, if (b.label.len > 0) b.label else "the larger value" }),
        .mean => try w.print("   rate = mean {s}", .{target}),
        .none => try w.print("   ({s} is multiclass: shares only)", .{target}),
    }
    try w.writeAll("\n   share bars are scaled to the largest row of each feature; rate bars to 0–100%");
    if (a.target_mode != .none) try w.writeAll("\n   features ranked by η², the share of the target's variance their rows explain");
    try w.writeAll("\n");
    var have_extra = false;
    for (a.target_rates) |f| for (f.rows) |r| {
        have_extra = have_extra or r.extra_rate != null;
    };

    var printed: usize = 0;
    for (a.target_rates) |f| {
        if (a.columns[f.column].use != .feature) continue;
        if (printed == shown) break;
        printed += 1;
        const name = a.columns[f.column].name;
        var label_w: usize = 12;
        var top: f64 = 0;
        for (f.rows) |r| {
            label_w = @max(label_w, @min(r.label.len, 24));
            top = @max(top, @max(r.train_share, r.test_share orelse 0));
        }
        try w.print("\n  {s}", .{name});
        if (f.eta2) |e| try w.print("   η² {d:.4}", .{e});
        try w.print("{s}\n", .{if (f.binned) "   (equal-count train bins)" else ""});
        for (f.rows) |r| {
            const label = if (r.label.len > 24) r.label[0..23] else r.label;
            try w.print("    {s}{s}", .{ label, if (r.label.len > 24) "…" else "" });
            try w.splatByteAll(' ', label_w - @min(r.label.len, 24) + 2);
            try w.print("train {d:>5.1}% ", .{100 * r.train_share});
            try bars.bar(w, if (top > 0) r.train_share / top else 0, bar_width);
            if (r.test_share) |ts| {
                try w.print("  test {d:>5.1}% ", .{100 * ts});
                try bars.bar(w, if (top > 0) ts / top else 0, bar_width);
            }
            if (r.rate) |rate| {
                switch (a.target_mode) {
                    .binary => {
                        try w.print("  rate {d:>5.1}% ", .{100 * rate});
                        try bars.bar(w, rate, bar_width);
                    },
                    else => try w.print("  mean {d:.4}", .{rate}),
                }
            }
            if (have_extra) if (r.extra_rate) |er| switch (a.target_mode) {
                .binary => try w.print("  extra {d:>5.1}%", .{100 * er}),
                else => try w.print("  extra {d:.4}", .{er}),
            };
            try w.writeAll("\n");
        }
    }
    if (shown < features)
        try w.print("\n  … {d} more features (--rates 0 shows all)\n", .{features - shown});
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

fn feature(a: *const an.Analysis, name: []const u8) *const Feature {
    for (a.target_rates) |*f| if (std.mem.eql(u8, a.columns[f.column].name, name)) return f;
    unreachable; // zsnag:ok test helper: the fixture has the column
}

fn rowByLabel(f: *const Feature, label: []const u8) *const Row {
    for (f.rows) |*r| if (std.mem.eql(u8, r.label, label)) return r;
    unreachable; // zsnag:ok test helper: the fixture has the row
}

test "categorical: rates per level, shares per file, missing row, boolean target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(),
        "id,c,y\n0,a,True\n1,a,False\n2,a,True\n3,b,False\n4,,True\n",
        "id,c\n5,a\n6,b\n7,b\n8,b\n");
    try testing.expectEqualStrings("True", a.target_mode.binary.label);
    const f = feature(&a, "c");
    const ra = rowByLabel(f, "a");
    try testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), ra.rate.?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.6), ra.train_share, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.25), ra.test_share.?, 1e-12);
    try testing.expectEqual(@as(f64, 0), rowByLabel(f, "b").rate.?);
    const miss = rowByLabel(f, "(missing)");
    try testing.expectEqual(@as(f64, 1), miss.rate.?);
    try testing.expectEqual(@as(?f64, 0), miss.test_share);
}

test "categorical: levels past max_rows pool into other, test matched against it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,c,y\n");
    // Level Lk appears 20 − k times: L0 most common. 12 levels > max_rows.
    var id: usize = 0;
    for (0..12) |k| for (0..20 - k) |_| {
        try csv.print(arena, "{d},L{d},{d}\n", .{ id, k, @intFromBool(k >= 9) });
        id += 1;
    };
    const a = try analyzed(arena, csv.items, "id,c\n900,L0\n901,L11\n");
    const f = feature(&a, "c");
    try testing.expectEqual(@as(usize, max_rows - 1 + 1 + 0), f.rows.len); // 9 shown + other; no missing
    try testing.expectEqualStrings("L0", f.rows[0].label);
    const other = rowByLabel(f, "other (3 levels)");
    try testing.expectEqual(@as(usize, 11 + 10 + 9), other.train_count);
    try testing.expectEqual(@as(f64, 1), other.rate.?);
    try testing.expectApproxEqAbs(@as(f64, 0.5), other.test_share.?, 1e-12);
}

test "numeric: few values get a row each; test-only values go to other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(),
        "id,x,y\n0,1,1\n1,1,1\n2,2,0\n3,3,0\n4,3,1\n",
        "id,x\n5,1\n6,7\n");
    const f = feature(&a, "x");
    try testing.expect(!f.binned);
    try testing.expectEqual(@as(f64, 1), rowByLabel(f, "1").rate.?);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rowByLabel(f, "3").rate.?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rowByLabel(f, "other values").test_share.?, 1e-12);
}

test "numeric: equal-count bins, a run is never split, end bins take out-of-range test values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,x,y\n");
    // 50 zeros then 1..50: the low quantiles all equal 0 and must merge.
    for (0..100) |i| {
        const x: usize = if (i < 50) 0 else i - 49;
        try csv.print(arena, "{d},{d},{d}\n", .{ i, x, @intFromBool(x > 25) });
    }
    const a = try analyzed(arena, csv.items, "id,x\n200,-5\n201,999\n");
    const f = feature(&a, "x");
    try testing.expect(f.binned);
    // The zeros are one bin, labelled by their value.
    try testing.expectEqualStrings("0", f.rows[0].label);
    try testing.expectEqual(@as(usize, 50), f.rows[0].train_count);
    try testing.expectEqual(@as(f64, 0), f.rows[0].rate.?);
    var total: usize = 0;
    for (f.rows) |r| total += r.train_count;
    try testing.expectEqual(@as(usize, 100), total);
    const last = f.rows[f.rows.len - 1]; // no (missing) row: none missing
    try testing.expect(last.kind == .value);
    try testing.expect(std.mem.endsWith(u8, last.label, ", 50]"));
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.rows[0].test_share.?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), last.test_share.?, 1e-12);
}

test "numeric target: rate is the mean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(), "id,c,y\n0,a,1.5\n1,a,2.5\n2,b,10\n", null);
    try testing.expect(a.target_mode == .mean);
    try testing.expectApproxEqAbs(@as(f64, 2), rowByLabel(feature(&a, "c"), "a").rate.?, 1e-12);
}

test "pure rate: found when big enough, not for small groups" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,c,y\n");
    // "p": 40 rows all positive (pure, big). "q": 5 rows all negative
    // (pure, too small). "m": 100 mixed.
    var id: usize = 0;
    for (0..40) |_| {
        try csv.print(arena, "{d},p,1\n", .{id});
        id += 1;
    }
    for (0..5) |_| {
        try csv.print(arena, "{d},q,0\n", .{id});
        id += 1;
    }
    for (0..100) |i| {
        try csv.print(arena, "{d},m,{d}\n", .{ id, i % 2 });
        id += 1;
    }
    const a = try analyzed(arena, csv.items, null);
    var pure: usize = 0;
    var msg: []const u8 = "";
    for (a.findings.items) |fd| if (fd.code == .pure_rate) {
        pure += 1;
        msg = fd.msg;
    };
    try testing.expectEqual(@as(usize, 1), pure);
    try testing.expect(std.mem.startsWith(u8, msg, "c = p (40 rows"));
}

test "report section renders bars and the rate header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a = try analyzed(arena, "id,c,y\n0,a,True\n1,b,False\n", "id,c\n2,a\n");
    var buf: std.Io.Writer.Allocating = .init(arena);
    try write(&buf.writer, &a, 0);
    const text = buf.written();
    try testing.expect(std.mem.find(u8, text, "rate = share of y = True") != null);
    try testing.expect(std.mem.find(u8, text, "train  50.0% █████       test 100.0% ██████████  rate 100.0% ██████████") != null);
}

test "bins: a 91% spike is one bin and the rest is still split" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s: [1000]f64 = undefined;
    for (&s, 0..) |*x, i| x.* = if (i < 910) 0 else @floatFromInt(i);
    const e = try binEdges(arena, &s, 10);
    try testing.expectEqual(@as(usize, 10), e.single.len);
    try testing.expect(e.single[0]);
    try testing.expectEqual(@as(f64, 0), e.edges[0]);
    try testing.expectEqual(@as(f64, 910), e.edges[1]);
    try testing.expectEqual(@as(f64, 999), e.edges[e.edges.len - 1]);
    for (e.edges[1 .. e.edges.len - 1], e.edges[2..]) |a, b| try testing.expect(a < b);
}

test "bins: runs stay whole, and every value lands in the bin whose range holds it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = [_]f64{ 1, 1, 1, 2, 2, 3, 4, 4, 4, 4, 5, 6, 7, 7, 8, 9, 9, 9, 9, 9 };
    const e = try binEdges(arena, &s, 4);
    var l: Layout = .{ .binned = true, .points = e.edges };
    const c: an.Column = .{ .name = "x", .use = .feature, .kind = .numeric };
    var p: an.PerTable = .{ .src = 0, .n = s.len, .num = @constCast(&s) };
    _ = &p;
    _ = &l;
    for (s, 0..) |x, r| {
        const b = l.rowOf(&c, &p, r);
        try testing.expect(x >= e.edges[b]);
        if (b + 2 < e.edges.len) try testing.expect(x < e.edges[b + 1]) else try testing.expect(x <= e.edges[b + 1]);
    }
    // No run is split: equal values share a bin.
    for (s[1..], s[0 .. s.len - 1], 1..) |x, prev, r| if (x == prev)
        try testing.expectEqual(l.rowOf(&c, &p, r - 1), l.rowOf(&c, &p, r));
}

test "rows with a missing target are left out of the rate, not counted as 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(), "id,c,y\n0,a,1\n1,a,\n2,a,1\n3,b,0\n", null);
    try testing.expectEqual(@as(f64, 1), rowByLabel(feature(&a, "c"), "a").rate.?);
}

test "a two-class target that is not boolean rates its minority class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(), "id,c,y\n0,a,cat\n1,a,cat\n2,b,dog\n3,b,cat\n", null);
    try testing.expectEqualStrings("dog", a.target_mode.binary.label);
    try testing.expectApproxEqAbs(@as(f64, 0.5), rowByLabel(feature(&a, "c"), "b").rate.?, 1e-12);
}

test "features rank by η², the section honours its limit, a 0/1 target is named by its value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `strong` decides y; `weak` is noise.
    const a = try analyzed(arena, "id,weak,strong,y\n0,a,p,1\n1,b,p,1\n2,a,q,0\n3,b,q,0\n4,a,p,1\n5,b,q,0\n", null);
    try testing.expectEqualStrings("strong", a.columns[a.target_rates[0].column].name);
    try testing.expectApproxEqAbs(@as(f64, 1), a.target_rates[0].eta2.?, 1e-12);
    try testing.expect(a.target_rates[1].eta2.? < 0.2);
    try testing.expectEqualStrings("1", a.target_mode.binary.label);
    var buf: std.Io.Writer.Allocating = .init(arena);
    try write(&buf.writer, &a, 1);
    try testing.expect(std.mem.find(u8, buf.written(), "weak") == null);
    try testing.expect(std.mem.find(u8, buf.written(), "1 more features") != null);
}
