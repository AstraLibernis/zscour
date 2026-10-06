// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M7 — per-column statistics and file-order checks (docs/PLAN.md).
//!
//! Definitions from ydata-profiling (MIT; re-read at 98b1aba):
//! `describe_numeric_pandas.py` — pandas' bias-corrected skewness G1 and
//! excess kurtosis G2, zero and negative shares, monotonicity (±2 strict,
//! ±1 non-strict, 0); `imbalance_pandas.py` — 1 − H(levels)/log2(k);
//! `typeset.py:314-322` — lag autocorrelation ≥ 0.7 as a sign of order.
//! Thresholds that differ from ydata's, and why:
//! - Skew is noted at |G1| ≥ 2, not ydata's 20: at 20 only freakish columns
//!   fire, while a linear model already suffers at 2.
//! - Zeros are noted at ≥ 50% (zero-inflated), not ydata's 1%, which fires
//!   on nearly every count column.
//! Imbalance > 0.5 and lag-1 ≥ 0.7 are ydata's own thresholds.

const std = @import("std");
const an = @import("analyze.zig");
const bars = @import("bars.zig");

pub const hist_bins = 16;
pub const skew_note = 2.0;
pub const zeros_note = 0.5;
pub const imbalance_note = 0.5;
pub const lag_note = 0.7;
/// Categorical grouping in file order: consecutive rows share a level this
/// much more often than chance, at z ≥ 5.
const grouped_excess = 0.2;
const grouped_z = 5;
/// Fewer values than this: no statistics.
const min_values = 4;

pub const Extra = struct {
    column: usize,
    n: usize = 0,
    mean: f64 = std.math.nan(f64),
    sd: f64 = std.math.nan(f64),
    skew: f64 = std.math.nan(f64),
    kurtosis: f64 = std.math.nan(f64),
    zeros: f64 = 0,
    negatives: f64 = 0,
    /// 1 − H(levels)/log2(k): 0 = balanced, 1 = one level.
    imbalance: f64 = std.math.nan(f64),
    /// +2/−2 strictly increasing/decreasing in file order, ±1 non-strict, 0 neither.
    monotonic: i8 = 0,
    /// Numeric: lag-1 autocorrelation in file order. Categorical: share of
    /// consecutive rows with the same level, minus its expectation.
    lag1: f64 = std.math.nan(f64),
    lag1_z: f64 = 0,
    /// Equal-width histogram over [min, max] (numeric), or per value for a
    /// discrete column.
    hist: []const usize = &.{},
};

/// Bias-corrected skewness and excess kurtosis, as pandas computes them.
pub fn moments(x: []const f64) struct { mean: f64, sd: f64, skew: f64, kurtosis: f64 } {
    const n: f64 = @floatFromInt(x.len);
    var mean: f64 = 0;
    for (x) |v| mean += v;
    mean /= n;
    var m2: f64 = 0;
    var m3: f64 = 0;
    var m4: f64 = 0;
    for (x) |v| {
        const d = v - mean;
        const d2 = d * d;
        m2 += d2;
        m3 += d2 * d;
        m4 += d2 * d2;
    }
    const sd = @sqrt(m2 / (n - 1));
    m2 /= n;
    m3 /= n;
    m4 /= n;
    if (m2 == 0) return .{ .mean = mean, .sd = 0, .skew = 0, .kurtosis = 0 };
    const g1 = m3 / std.math.pow(f64, m2, 1.5);
    const g2 = m4 / (m2 * m2) - 3;
    return .{
        .mean = mean,
        .sd = sd,
        .skew = @sqrt(n * (n - 1)) / (n - 2) * g1,
        .kurtosis = (n - 1) / ((n - 2) * (n - 3)) * ((n + 1) * g2 + 6),
    };
}

/// 1 − H/log2(k) over level counts (k = levels present); 0 for one level.
pub fn imbalance(counts: []const usize) f64 {
    var total: f64 = 0;
    var k: f64 = 0;
    for (counts) |c| if (c > 0) {
        total += @floatFromInt(c);
        k += 1;
    };
    if (k < 2) return 0;
    var h: f64 = 0;
    for (counts) |c| if (c > 0) {
        const p = @as(f64, @floatFromInt(c)) / total;
        h -= p * std.math.log2(p);
    };
    return 1 - h / std.math.log2(k);
}

/// Monotonicity over the non-missing values in file order (ydata's coding).
pub fn monotonic(x: []const f64) i8 {
    var up = true;
    var down = true;
    var strict = true;
    var prev: ?f64 = null;
    for (x) |v| {
        if (std.math.isNan(v)) continue;
        if (prev) |p| {
            if (v < p) up = false;
            if (v > p) down = false;
            if (v == p) strict = false;
        }
        prev = v;
    }
    if (!up and !down) return 0;
    if (up and down) return 0; // constant: neither
    const sign: i8 = if (up) 1 else -1;
    return if (strict) 2 * sign else sign;
}

/// Lag-1 autocorrelation over the non-missing values in file order.
pub fn lag1(x: []const f64) struct { r: f64, z: f64 } {
    var n: f64 = 0;
    var mean: f64 = 0;
    for (x) |v| if (!std.math.isNan(v)) {
        n += 1;
        mean += (v - mean) / n;
    };
    if (n < min_values) return .{ .r = std.math.nan(f64), .z = 0 };
    var num: f64 = 0;
    var den: f64 = 0;
    var prev: ?f64 = null;
    for (x) |v| {
        if (std.math.isNan(v)) continue;
        den += (v - mean) * (v - mean);
        if (prev) |p| num += (p - mean) * (v - mean);
        prev = v;
    }
    if (den == 0) return .{ .r = 0, .z = 0 };
    const r = num / den;
    return .{ .r = r, .z = r * @sqrt(n) };
}

fn histogram(arena: std.mem.Allocator, c: *const an.Column, p: *const an.PerTable) ![]const usize {
    const s = p.sorted;
    if (s.len == 0) return &.{};
    if (c.discrete) |d| {
        const h = try arena.alloc(usize, d.values.len);
        @memset(h, 0);
        for (s) |v| {
            const i = std.sort.lowerBound(f64, d.values, v, order);
            if (i < h.len and d.values[i] == v) h[i] += 1;
        }
        return h;
    }
    const lo = s[0];
    const hi = s[s.len - 1];
    const h = try arena.alloc(usize, hist_bins);
    @memset(h, 0);
    if (hi == lo) {
        h[0] = s.len;
        return h;
    }
    for (s) |v| {
        const f = (v - lo) / (hi - lo) * hist_bins;
        h[@min(hist_bins - 1, @as(usize, @intFromFloat(f)))] += 1;
    }
    return h;
}

fn order(a: f64, b: f64) std.math.Order {
    return std.math.order(a, b);
}

/// Fill `cx.a.column_stats` from train and add skew / zeros / imbalance /
/// order findings for features.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    const arena = cx.arena;
    var out: std.ArrayList(Extra) = .empty;
    for (a.columns, 0..) |*c, ci| {
        const p = c.at(.train) orelse continue;
        var e: Extra = .{ .column = ci };
        switch (c.kind) {
            .numeric => {
                e.n = p.sorted.len;
                if (e.n >= min_values) {
                    const mo = moments(p.sorted);
                    e.mean = mo.mean;
                    e.sd = mo.sd;
                    e.skew = mo.skew;
                    e.kurtosis = mo.kurtosis;
                    var zeros: f64 = 0;
                    var neg: f64 = 0;
                    for (p.sorted) |v| {
                        zeros += @floatFromInt(@intFromBool(v == 0));
                        neg += @floatFromInt(@intFromBool(v < 0));
                    }
                    e.zeros = zeros / @as(f64, @floatFromInt(e.n));
                    e.negatives = neg / @as(f64, @floatFromInt(e.n));
                    e.monotonic = monotonic(p.num);
                    const l = lag1(p.num);
                    e.lag1 = l.r;
                    e.lag1_z = l.z;
                    e.hist = try histogram(arena, c, p);
                }
            },
            .categorical => {
                e.n = p.n - p.empty;
                e.imbalance = imbalance(p.level_counts);
                // Consecutive rows with the same level, against Σp².
                var same: f64 = 0;
                var pairs: f64 = 0;
                var prev: ?u32 = null;
                for (p.cat) |id| {
                    if (id == an.no_level) continue;
                    if (prev) |q| {
                        pairs += 1;
                        same += @floatFromInt(@intFromBool(q == id));
                    }
                    prev = id;
                }
                if (pairs >= min_values) {
                    var expect: f64 = 0;
                    const total: f64 = @floatFromInt(e.n);
                    for (p.level_counts) |k| {
                        const q = @as(f64, @floatFromInt(k)) / total;
                        expect += q * q;
                    }
                    const share = same / pairs;
                    const sd = @sqrt(expect * (1 - expect) / pairs);
                    e.lag1 = share - expect;
                    e.lag1_z = if (sd > 0) e.lag1 / sd else 0;
                }
            },
            .empty => continue,
        }
        try out.append(arena, e);
        if (c.use != .feature or e.n < min_values) continue;

        // Findings.
        if (c.kind == .numeric) {
            // Discrete columns too: a 0/1 column that never decreases down
            // the file means the file is sorted by it.
            if (e.monotonic != 0) {
                try cx.add(.warn, .order, .train, c.name, "{s} in file order: the file is sorted by this column, or it is a row counter in disguise — check it is not a leak through order", .{switch (e.monotonic) {
                    2 => "strictly increasing",
                    -2 => "strictly decreasing",
                    1 => "never decreasing",
                    else => "never increasing",
                }});
            } else if (@abs(e.lag1) >= lag_note and e.lag1_z >= grouped_z) {
                try cx.add(.info, .order, .train, c.name, "neighbouring rows have similar values (lag-1 autocorrelation {d:.3}): the file is ordered by time, a group or this column", .{e.lag1});
            }
            if (@abs(e.skew) >= skew_note and c.discrete == null)
                try cx.add(.info, .skew, .train, c.name, "skewed (skewness {d:.2}, excess kurtosis {d:.1}): linear and distance-based models may want a log or rank transform; trees do not mind", .{ e.skew, e.kurtosis });
            if (e.zeros >= zeros_note and c.discrete == null)
                try cx.add(.info, .skew, .train, c.name, "{d:.1}% of values are exactly 0 (zero-inflated): a 'was zero' indicator can carry signal on its own", .{100 * e.zeros});
        } else {
            if (e.imbalance > imbalance_note)
                try cx.add(.info, .imbalance, .train, c.name, "imbalanced: one or a few levels dominate (imbalance {d:.2}, 0 = even, 1 = one level)", .{e.imbalance});
            if (e.lag1 >= grouped_excess and e.lag1_z >= grouped_z)
                try cx.add(.info, .order, .train, c.name, "rows come in runs of the same level ({d:.0} percentage points above chance): the file is grouped by this column", .{100 * e.lag1});
        }
    }
    a.column_stats = out.items;
}

pub fn statsOf(a: *const an.Analysis, ci: usize) ?*const Extra {
    for (a.column_stats) |*e| if (e.column == ci) return e;
    return null;
}

/// Sparkline and the headline numbers for the text column table.
pub fn writeShort(w: *std.Io.Writer, e: *const Extra) std.Io.Writer.Error!void {
    if (e.hist.len > 0) {
        try w.writeAll("   ");
        try bars.sparkline(w, e.hist);
    }
    if (!std.math.isNan(e.skew)) try w.print("   skew {d:.2}", .{e.skew});
    if (e.zeros >= 0.05) try w.print("   zeros {d:.0}%", .{100 * e.zeros});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

test "moments against pandas' formulas by hand" {
    // x = 1, 2, 3, 4, 10: mean 4, deviations −3 −2 −1 0 6.
    // m2 = 50/5 = 10, m3 = (−27 −8 −1 +216)/5 = 36, m4 = (81+16+1+1296)/5 = 278.8
    // g1 = 36 / 10^1.5, G1 = √(5·4)/3 · g1; g2 = 278.8/100 − 3,
    // G2 = 4/(3·2) · (6·g2 + 6).
    const m = moments(&.{ 1, 2, 3, 4, 10 });
    const g1 = 36.0 / std.math.pow(f64, 10, 1.5);
    try testing.expectApproxEqAbs(@as(f64, 4), m.mean, 1e-12);
    try testing.expectApproxEqAbs(@sqrt(50.0 / 4.0), m.sd, 1e-12);
    try testing.expectApproxEqAbs(@sqrt(20.0) / 3.0 * g1, m.skew, 1e-12);
    try testing.expectApproxEqAbs(4.0 / 6.0 * (6 * (2.788 - 3) + 6), m.kurtosis, 1e-9);
    // Symmetric: no skew.
    try testing.expectApproxEqAbs(@as(f64, 0), moments(&.{ 1, 2, 3, 4, 5 }).skew, 1e-12);
}

test "imbalance: even 0, one level 0, dominated near 1" {
    try testing.expectApproxEqAbs(@as(f64, 0), imbalance(&.{ 50, 50, 50 }), 1e-12);
    try testing.expectEqual(@as(f64, 0), imbalance(&.{ 100, 0 }));
    try testing.expect(imbalance(&.{ 990, 5, 5 }) > 0.9);
    // A level with no rows does not count: two even levels are balanced.
    try testing.expectApproxEqAbs(@as(f64, 0), imbalance(&.{ 50, 50, 0 }), 1e-12);
}

test "monotonic coding and lag-1" {
    const nan = std.math.nan(f64);
    try testing.expectEqual(@as(i8, 2), monotonic(&.{ 1, nan, 2, 3 }));
    try testing.expectEqual(@as(i8, 1), monotonic(&.{ 1, 1, 2 }));
    try testing.expectEqual(@as(i8, -2), monotonic(&.{ 3, 2, 1 }));
    try testing.expectEqual(@as(i8, 0), monotonic(&.{ 1, 3, 2 }));
    try testing.expectEqual(@as(i8, 0), monotonic(&.{ 5, 5, 5 }));
    // Alternating: lag-1 strongly negative.
    try testing.expect(lag1(&.{ 1, -1, 1, -1, 1, -1, 1, -1 }).r < -0.8);
}

fn analyzed(arena: std.mem.Allocator, csv: []const u8) !an.Analysis {
    var tables = [_]tbl.Table{try tbl.parse(arena, .train, "train", csv)};
    return an.analyze(arena, try arena.dupe(tbl.Table, &tables), .{ .target = "y", .shift_warn = 1, .adversarial = false });
}

fn has(a: *const an.Analysis, code: an.Code, column: []const u8) bool {
    for (a.findings.items) |f| if (f.code == code) if (f.column) |c| if (std.mem.eql(u8, c, column)) return true;
    return false;
}

test "findings: sorted column, skew, zero-inflation, imbalance, grouped rows — and none on a plain column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,stamp,heavy,mostly0,rare,group,plain,phase,mild,y\n");
    for (0..1000) |i| {
        const heavy = std.math.pow(f64, 1.01, @floatFromInt((i * 7919) % 1000)); // long right tail
        const mostly0: usize = if ((i * 31) % 10 < 7) 0 else (i * 13) % 50 + 1;
        const rare = if ((i * 17) % 100 < 97) "common" else if ((i * 17) % 100 < 99) "a" else "b";
        const group = i / 100; // runs of 100
        const plain = (i * 7919) % 1009;
        // phase: 0–3 in four blocks — a discrete column the file is sorted by.
        // mild: runs of three (aaabbb…): same-level neighbours 67% against
        // 50% by chance — real (z ≈ 10) but below the 20-point floor.
        const mild = if ((i / 3) % 2 == 0) "a" else "b";
        try csv.print(arena, "{d},{d},{d:.4},{d},{s},g{d},{d},{d},{s},{d}\n", .{ i, 5000 + i, heavy, mostly0, rare, group, plain, i / 250, mild, i % 2 });
    }
    const a = try analyzed(arena, csv.items);
    try testing.expect(has(&a, .order, "stamp"));
    try testing.expect(has(&a, .skew, "heavy"));
    try testing.expect(has(&a, .skew, "mostly0"));
    try testing.expect(has(&a, .imbalance, "rare"));
    try testing.expect(has(&a, .order, "group"));
    try testing.expect(!has(&a, .order, "plain") and !has(&a, .skew, "plain"));
    // Sorted by `phase`: a warning, not just the lag-1 note.
    var phase_warned = false;
    for (a.findings.items) |f| if (f.code == .order and f.sev == .warn) if (f.column) |c| {
        phase_warned = phase_warned or std.mem.eql(u8, c, "phase");
    };
    try testing.expect(phase_warned);
    try testing.expect(!has(&a, .order, "mild"));
    // The id is monotonic too, by nature: never reported.
    try testing.expect(!has(&a, .order, "id"));
}

test "histogram: equal width, every value counted, discrete per value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,x,r,y\n");
    for (0..320) |i| try csv.print(arena, "{d},{d},{d},{d}\n", .{ i, i % 160, i % 3, i % 2 });
    const a = try analyzed(arena, csv.items);
    const x = statsOf(&a, 1).?;
    try testing.expectEqual(@as(usize, hist_bins), x.hist.len);
    var total: usize = 0;
    for (x.hist) |k| total += k;
    try testing.expectEqual(@as(usize, 320), total);
    try testing.expectEqual(@as(usize, 20), x.hist[0]); // 0–9, twice
    const r = statsOf(&a, 2).?;
    try testing.expectEqualSlices(usize, &.{ 107, 107, 106 }, r.hist);
}
