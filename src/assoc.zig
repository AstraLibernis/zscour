// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M6 — associations between feature columns (docs/PLAN.md): which pairs
//! carry the same information.
//!
//! Measures, all in [0, 1] by absolute value:
//! - numeric × numeric: Spearman ρ (Pearson on ranks, ties averaged), as
//!   ydata-profiling's `auto` mode and deepchecks use;
//! - categorical × categorical: Cramér's V with Bergsma's bias correction —
//!   ydata-profiling `correlations_pandas.py:38-68` (MIT, re-read at
//!   98b1aba), without scipy's Yates correction on 2×2 tables;
//! - numeric × categorical: the correlation ratio η, sweetviz
//!   `from_dython.py:189-247` (MIT, 4697e18).
//! Differences, and why:
//! - Missing values are dropped pair by pair. sweetviz and deepchecks
//!   replace them with 0 first (`from_dython.py:49`), which invents a value.
//!   Spearman is exact: a pair where either column has missing values is
//!   re-ranked on the rows both have (ranks taken over each column alone
//!   leave gaps there); pairs without missing values reuse the column ranks.
//! - A constant column has V = 0 here; ydata returns 1 when the corrected
//!   denominator is 0, calling a constant "perfectly associated".
//! - Theil's U is not computed: it is asymmetric (two numbers per pair) and
//!   V answers the question asked here, "are these two redundant?".
//! - Categoricals with more than 100 levels are skipped and listed (ydata's
//!   `categorical_maximum_correlation_distinct`): V on an id-like column says
//!   nothing.
//! - At most 100 000 train rows, a fixed-seed sample, so wide files stay fast.

const std = @import("std");
const an = @import("analyze.zig");

pub const Method = enum {
    spearman,
    cramers_v,
    correlation_ratio,

    pub fn symbol(m: Method) []const u8 {
        return switch (m) {
            .spearman => "ρ",
            .cramers_v => "V",
            .correlation_ratio => "η",
        };
    }
};

pub const Pair = struct {
    a: usize,
    b: usize,
    method: Method,
    /// Spearman keeps its sign; V and η are in [0, 1].
    value: f64,

    pub fn strength(p: Pair) f64 {
        return @abs(p.value);
    }
};

/// ydata-profiling's HIGH_CORRELATION threshold.
pub const high = 0.9;
pub const max_rows = 100_000;
pub const max_levels = 100;
/// Fewer rows in common than this: no value for the pair.
const min_rows = 10;
const seed = 0xa550c;

const Col = struct {
    index: usize,
    kind: an.Kind,
    /// Numeric: rank per sampled row (NaN = missing). Raw value in `raw`.
    rank: []const f64 = &.{},
    raw: []const f64 = &.{},
    missing: usize = 0,
    /// Ranks standardised (mean 0, Σz² = n) when nothing is missing, so ρ of
    /// two complete columns is one dot product; empty otherwise or when the
    /// column is constant.
    z: []const f64 = &.{},
    /// Categorical: level id per sampled row.
    cat: []const u32 = &.{},
    levels: usize = 0,
};

/// Average ranks (1-based) of the non-NaN values; NaN stays NaN.
pub fn ranks(arena: std.mem.Allocator, x: []const f64) ![]f64 {
    const out = try arena.alloc(f64, x.len);
    var idx: std.ArrayList(u32) = .empty;
    for (x, 0..) |v, i| {
        out[i] = std.math.nan(f64);
        if (!std.math.isNan(v)) try idx.append(arena, @intCast(i));
    }
    const Ctx = struct {
        x: []const f64,
        fn less(c: @This(), p: u32, q: u32) bool {
            return c.x[p] < c.x[q];
        }
    };
    std.mem.sort(u32, idx.items, Ctx{ .x = x }, Ctx.less);
    var i: usize = 0;
    while (i < idx.items.len) {
        var j = i;
        while (j + 1 < idx.items.len and x[idx.items[j + 1]] == x[idx.items[i]]) j += 1;
        const avg = @as(f64, @floatFromInt(i + j)) / 2 + 1;
        for (idx.items[i .. j + 1]) |k| out[k] = avg;
        i = j + 1;
    }
    return out;
}

/// Pearson correlation over rows where both are present.
pub fn pearson(x: []const f64, y: []const f64) ?f64 {
    var n: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (x, y) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        n += 1;
        sx += a;
        sy += b;
    }
    if (n < min_rows) return null;
    const mx = sx / n;
    const my = sy / n;
    var sxy: f64 = 0;
    var sxx: f64 = 0;
    var syy: f64 = 0;
    for (x, y) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        sxy += (a - mx) * (b - my);
        sxx += (a - mx) * (a - mx);
        syy += (b - my) * (b - my);
    }
    if (sxx == 0 or syy == 0) return 0;
    return sxy / @sqrt(sxx * syy);
}

/// (x − mean) / sd with sd over n, so Σ z_x·z_y / n is Pearson's r.
/// Empty for a constant column.
fn standardise(arena: std.mem.Allocator, x: []const f64) ![]const f64 {
    var mean: f64 = 0;
    for (x) |v| mean += v;
    mean /= @floatFromInt(x.len);
    var ss: f64 = 0;
    for (x) |v| ss += (v - mean) * (v - mean);
    if (ss == 0) return &.{};
    const sd = @sqrt(ss / @as(f64, @floatFromInt(x.len)));
    const z = try arena.alloc(f64, x.len);
    for (z, x) |*o, v| o.* = (v - mean) / sd;
    return z;
}

/// Spearman's ρ of two numeric columns over the rows both have.
fn spearman(arena: std.mem.Allocator, x: Col, y: Col) !?f64 {
    if (x.missing == 0 and y.missing == 0) {
        if (x.rank.len < min_rows) return null;
        if (x.z.len == 0 or y.z.len == 0) return 0; // a constant column
        var dot: f64 = 0;
        for (x.z, y.z) |a, b| dot += a * b;
        return std.math.clamp(dot / @as(f64, @floatFromInt(x.z.len)), -1, 1);
    }
    const xs = try arena.alloc(f64, x.raw.len);
    const ys = try arena.alloc(f64, x.raw.len);
    var k: usize = 0;
    for (x.raw, y.raw) |a, b| {
        if (std.math.isNan(a) or std.math.isNan(b)) continue;
        xs[k] = a;
        ys[k] = b;
        k += 1;
    }
    return pearson(try ranks(arena, xs[0..k]), try ranks(arena, ys[0..k]));
}

/// Bias-corrected Cramér's V of two categorical columns.
pub fn cramersV(arena: std.mem.Allocator, x: []const u32, kx: usize, y: []const u32, ky: usize) !?f64 {
    const table = try arena.alloc(f64, kx * ky);
    @memset(table, 0);
    const rows = try arena.alloc(f64, kx);
    const cols = try arena.alloc(f64, ky);
    @memset(rows, 0);
    @memset(cols, 0);
    var n: f64 = 0;
    for (x, y) |a, b| {
        if (a == an.no_level or b == an.no_level) continue;
        table[a * ky + b] += 1;
        rows[a] += 1;
        cols[b] += 1;
        n += 1;
    }
    if (n < min_rows) return null;
    var r: f64 = 0;
    var k: f64 = 0;
    for (rows) |v| r += @floatFromInt(@intFromBool(v > 0));
    for (cols) |v| k += @floatFromInt(@intFromBool(v > 0));
    if (r < 2 or k < 2) return 0; // a constant says nothing
    var chi2: f64 = 0;
    for (0..kx) |i| {
        if (rows[i] == 0) continue;
        for (0..ky) |j| {
            if (cols[j] == 0) continue;
            const e = rows[i] * cols[j] / n;
            const d = table[i * ky + j] - e;
            chi2 += d * d / e;
        }
    }
    const phi2 = chi2 / n;
    const phi2c = @max(0, phi2 - (k - 1) * (r - 1) / (n - 1));
    const rc = r - (r - 1) * (r - 1) / (n - 1);
    const kc = k - (k - 1) * (k - 1) / (n - 1);
    const den = @min(kc - 1, rc - 1);
    if (den <= 0) return 0;
    return @sqrt(phi2c / den);
}

/// Correlation ratio η of a numeric column over a categorical one.
pub fn correlationRatio(arena: std.mem.Allocator, v: []const f64, g: []const u32, k: usize) !?f64 {
    const sum = try arena.alloc(f64, k);
    const cnt = try arena.alloc(f64, k);
    @memset(sum, 0);
    @memset(cnt, 0);
    var n: f64 = 0;
    var total: f64 = 0;
    for (v, g) |x, l| {
        if (std.math.isNan(x) or l == an.no_level) continue;
        sum[l] += x;
        cnt[l] += 1;
        n += 1;
        total += x;
    }
    if (n < min_rows) return null;
    const mean = total / n;
    var ss_total: f64 = 0;
    for (v, g) |x, l| {
        if (std.math.isNan(x) or l == an.no_level) continue;
        ss_total += (x - mean) * (x - mean);
    }
    if (ss_total == 0) return 0;
    var between: f64 = 0;
    for (sum, cnt) |s, c| if (c > 0) {
        const d = s / c - mean;
        between += c * d * d;
    };
    return @sqrt(@min(1, between / ss_total));
}

/// Fill `cx.a.associations` for every pair of included features, and warn
/// on pairs at or above `high`.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    const arena = cx.arena;
    const train = a.table(.train) orelse return;
    const n = train.n_rows;
    const m = @min(n, @as(usize, max_rows));
    if (m < min_rows) return;

    // The sampled rows, in file order (the order does not matter here).
    var rows: []u32 = try arena.alloc(u32, n);
    for (rows, 0..) |*r, i| r.* = @intCast(i);
    if (m < n) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        for (0..m) |i| std.mem.swap(u32, &rows[i], &rows[i + rnd.uintLessThan(usize, n - i)]);
        rows = rows[0..m];
        std.mem.sort(u32, rows, {}, std.sort.asc(u32));
    }

    var cols: std.ArrayList(Col) = .empty;
    var skipped: std.ArrayList(usize) = .empty;
    for (a.columns, 0..) |*c, ci| {
        if (c.use != .feature) continue;
        const p = c.at(.train) orelse continue;
        switch (c.kind) {
            .numeric => {
                const raw = try arena.alloc(f64, m);
                var missing: usize = 0;
                for (raw, rows) |*v, r| {
                    v.* = p.num[r];
                    missing += @intFromBool(std.math.isNan(v.*));
                }
                const rk = try ranks(arena, raw);
                try cols.append(arena, .{ .index = ci, .kind = .numeric, .raw = raw, .rank = rk, .missing = missing, .z = if (missing == 0) try standardise(arena, rk) else &.{} });
            },
            .categorical => {
                if (c.levels.len > max_levels) {
                    try skipped.append(arena, ci);
                    continue;
                }
                const ids = try arena.alloc(u32, m);
                for (ids, rows) |*v, r| v.* = p.cat[r];
                try cols.append(arena, .{ .index = ci, .kind = .categorical, .cat = ids, .levels = c.levels.len });
            },
            .empty => {},
        }
    }

    var pairs: std.ArrayList(Pair) = .empty;
    for (cols.items, 0..) |x, i| for (cols.items[i + 1 ..]) |y| {
        const pair: ?Pair = switch (x.kind) {
            .numeric => switch (y.kind) {
                .numeric => if (try spearman(arena, x, y)) |v| .{ .a = x.index, .b = y.index, .method = .spearman, .value = v } else null,
                .categorical => if (try correlationRatio(arena, x.raw, y.cat, y.levels)) |v| .{ .a = x.index, .b = y.index, .method = .correlation_ratio, .value = v } else null,
                .empty => null,
            },
            .categorical => switch (y.kind) {
                .numeric => if (try correlationRatio(arena, y.raw, x.cat, x.levels)) |v| .{ .a = x.index, .b = y.index, .method = .correlation_ratio, .value = v } else null,
                .categorical => if (try cramersV(arena, x.cat, x.levels, y.cat, y.levels)) |v| .{ .a = x.index, .b = y.index, .method = .cramers_v, .value = v } else null,
                .empty => null,
            },
            .empty => null,
        };
        if (pair) |p| try pairs.append(arena, p);
    };
    const S = struct {
        fn stronger(_: void, p: Pair, q: Pair) bool {
            return p.strength() > q.strength();
        }
    };
    std.mem.sort(Pair, pairs.items, {}, S.stronger);
    a.associations = pairs.items;
    a.assoc_skipped = skipped.items;
    a.assoc_rows = m;

    for (pairs.items) |p| {
        if (p.strength() < high) break;
        try cx.add(.warn, .association, .train, null, "{s} and {s} carry nearly the same information ({s} = {d:.3}): one may be redundant, or derived from the other", .{ a.columns[p.a].name, a.columns[p.b].name, p.method.symbol(), p.value });
    }
    if (skipped.items.len > 0) {
        var list: std.ArrayList(u8) = .empty;
        for (skipped.items[0..@min(skipped.items.len, 8)], 0..) |ci, i| try list.print(arena, "{s}{s}", .{ if (i > 0) ", " else "", a.columns[ci].name });
        try cx.add(.info, .association, .train, null, "not compared with other columns: more than {d} levels ({s}{s})", .{ max_levels, list.items, if (skipped.items.len > 8) ", …" else "" });
    }
}

/// `limit`: pairs listed; 0 = all.
pub fn write(w: *std.Io.Writer, a: *const an.Analysis, limit: usize) std.Io.Writer.Error!void {
    if (a.associations.len == 0) return;
    try w.print("\nASSOCIATIONS   ρ Spearman (numeric pairs) · V Cramér (categorical pairs) · η correlation ratio (mixed) — {d} train rows\n", .{a.assoc_rows});
    var high_n: usize = 0;
    for (a.associations) |p| high_n += @intFromBool(p.strength() >= high);
    const shown = if (limit == 0) a.associations.len else @min(limit, a.associations.len);
    for (a.associations[0..shown]) |p| {
        const na = a.columns[p.a].name;
        const nb = a.columns[p.b].name;
        try w.print("  {s} {d: >6.3}  ", .{ p.method.symbol(), p.value });
        try @import("bars.zig").bar(w, p.strength(), 10);
        try w.print("  {s} · {s}{s}\n", .{ na, nb, if (p.strength() >= high) "   HIGH" else "" });
    }
    if (shown < a.associations.len) try w.print("  … {d} more pairs (--top 0 shows all); {d} at or above {d}\n", .{ a.associations.len - shown, high_n, high });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

test "ranks: ties averaged, missing kept missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const r = try ranks(arena_state.allocator(), &.{ 10, std.math.nan(f64), 30, 10, 20 });
    try testing.expectEqual(@as(f64, 1.5), r[0]);
    try testing.expect(std.math.isNan(r[1]));
    try testing.expectEqual(@as(f64, 4), r[2]);
    try testing.expectEqual(@as(f64, 1.5), r[3]);
    try testing.expectEqual(@as(f64, 3), r[4]);
}

test "pearson on ranks: monotone is ±1, pairwise missing dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var x: [20]f64 = undefined;
    var y: [20]f64 = undefined;
    for (&x, &y, 0..) |*a, *b, i| {
        a.* = @floatFromInt(i);
        b.* = -@as(f64, @floatFromInt(i * i));
    }
    y[3] = std.math.nan(f64);
    // i and −i² are not linear, but their ranks are exactly opposite —
    // also when y misses a value and the pair is re-ranked without it.
    try testing.expect(pearson(&x, &y).? > -0.99);
    const cx: Col = .{ .index = 0, .kind = .numeric, .raw = &x, .rank = try ranks(arena, &x), .missing = 0 };
    const cy: Col = .{ .index = 1, .kind = .numeric, .raw = &y, .rank = try ranks(arena, &y), .missing = 1 };
    try testing.expectApproxEqAbs(@as(f64, -1), (try spearman(arena, cx, cy)).?, 1e-12);
    try testing.expectEqual(@as(?f64, null), pearson(cx.rank[0..5], cy.rank[0..5]));
}

test "Cramér's V: identical columns ~1, independent ~0, constant 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var x: [400]u32 = undefined;
    var y: [400]u32 = undefined;
    var z: [400]u32 = undefined;
    for (&x, &y, &z, 0..) |*a, *b, *c, i| {
        a.* = @intCast(i % 4);
        b.* = @intCast((i / 4) % 3); // balanced and independent of x
        c.* = 0;
    }
    try testing.expect((try cramersV(arena, &x, 4, &x, 4)).? > 0.99);
    try testing.expect((try cramersV(arena, &x, 4, &y, 3)).? < 0.05);
    try testing.expectEqual(@as(f64, 0), (try cramersV(arena, &x, 4, &z, 1)).?);
}

test "Cramér's V by hand on a 2×2 table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Table [[30, 10], [10, 30]], n = 80: χ² = 20, φ² = 0.25,
    // φ²c = 0.25 − 1/79, rc = kc = 2 − 1/79, V = √(φ²c / (1 − 1/79)).
    var x: [80]u32 = undefined;
    var y: [80]u32 = undefined;
    for (&x, &y, 0..) |*a, *b, i| {
        a.* = if (i < 40) 0 else 1;
        b.* = if (i < 30 or (i >= 40 and i < 50)) 0 else 1;
    }
    const want = @sqrt((0.25 - 1.0 / 79.0) / (1 - 1.0 / 79.0));
    try testing.expectApproxEqAbs(want, (try cramersV(arena_state.allocator(), &x, 2, &y, 2)).?, 1e-12);
}

test "correlation ratio: groups explain all, none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var v: [30]f64 = undefined;
    var g: [30]u32 = undefined;
    for (&v, &g, 0..) |*x, *l, i| {
        l.* = @intCast(i % 3);
        x.* = @floatFromInt(i % 3);
    }
    try testing.expectApproxEqAbs(@as(f64, 1), (try correlationRatio(arena, &v, &g, 3)).?, 1e-12);
    for (&v, 0..) |*x, i| x.* = @floatFromInt(i / 3 % 2); // same mean in every group
    try testing.expectApproxEqAbs(@as(f64, 0), (try correlationRatio(arena, &v, &g, 3)).?, 1e-12);
}

test "a derived column is flagged; wide categoricals are skipped and listed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,x,x_squared,noise,user,y\n");
    for (0..500) |i| {
        const x: f64 = @floatFromInt(i % 97);
        try csv.print(arena, "{d},{d},{d},{d},u{d},{d}\n", .{ i, x, x * x, (i * 7919) % 101, i % 150, i % 2 });
    }
    var tables = [_]tbl.Table{try tbl.parse(arena, .train, "train", csv.items)};
    const a = try an.analyze(arena, &tables, .{ .shift_warn = 1 });
    const top = a.associations[0];
    try testing.expectEqualStrings("x", a.columns[top.a].name);
    try testing.expectEqualStrings("x_squared", a.columns[top.b].name);
    try testing.expectApproxEqAbs(@as(f64, 1), top.value, 1e-12);
    var high_n: usize = 0;
    var skipped_note = false;
    for (a.findings.items) |f| if (f.code == .association) {
        high_n += @intFromBool(f.sev == .warn);
        skipped_note = skipped_note or std.mem.find(u8, f.msg, "user") != null;
    };
    try testing.expectEqual(@as(usize, 1), high_n);
    try testing.expect(skipped_note);
    for (a.associations) |p| try testing.expect(!std.mem.eql(u8, a.columns[p.a].name, "user") and !std.mem.eql(u8, a.columns[p.b].name, "user"));
}

test "spearman: the one-pass path agrees with the two-pass one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var x: [300]f64 = undefined;
    var y: [300]f64 = undefined;
    for (&x, &y, 0..) |*a, *b, i| {
        a.* = @floatFromInt((i * 37) % 101);
        b.* = @floatFromInt((i * 53) % 89 + (i % 7));
    }
    const rx = try ranks(arena, &x);
    const ry = try ranks(arena, &y);
    const cx: Col = .{ .index = 0, .kind = .numeric, .raw = &x, .rank = rx, .z = try standardise(arena, rx) };
    const cy: Col = .{ .index = 1, .kind = .numeric, .raw = &y, .rank = ry, .z = try standardise(arena, ry) };
    try testing.expectApproxEqAbs(pearson(rx, ry).?, (try spearman(arena, cx, cy)).?, 1e-12);
}

test "Cramér's V leaves missing levels out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var x: [200]u32 = undefined;
    var y: [200]u32 = undefined;
    for (&x, &y, 0..) |*a, *b, i| {
        a.* = @intCast(i % 2);
        // Identical to x where present; every 5th row missing.
        b.* = if (i % 5 == 0) an.no_level else @intCast(i % 2);
    }
    try testing.expect((try cramersV(arena, &x, 2, &y, 2)).? > 0.99);
}

test "strong negative pairs rank with strong positive ones; moderate pairs are not flagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,x,neg_x,half,y\n");
    for (0..600) |i| {
        const x: f64 = @floatFromInt(i % 97);
        // `half` follows x about 70% of the way: ρ ≈ 0.7.
        const half = x + @as(f64, @floatFromInt((i * 7919) % 61));
        try csv.print(arena, "{d},{d},{d},{d},{d}\n", .{ i, x, -x, half, i % 2 });
    }
    var tables = [_]tbl.Table{try tbl.parse(arena, .train, "train", csv.items)};
    const a = try an.analyze(arena, &tables, .{ .shift_warn = 1 });
    try testing.expectApproxEqAbs(@as(f64, -1), a.associations[0].value, 1e-12);
    const moderate = a.associations[1].strength();
    try testing.expect(moderate > 0.5 and moderate < high);
    var flagged: usize = 0;
    for (a.findings.items) |f| flagged += @intFromBool(f.code == .association and f.sev == .warn);
    try testing.expectEqual(@as(usize, 1), flagged);
}
