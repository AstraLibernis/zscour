// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M2 — single-feature predictive power, and leak checks on the id column and
//! on row order (docs/PLAN.md).
//!
//! The score follows the predictive power score of ppscore (8080 Labs, MIT;
//! as vendored in deepchecks, `ppscore.py`, re-read at 98475d1): predict the
//! target from one column alone, out of fold, and normalise against a naive
//! baseline into [0, 1]. Differences, and why:
//! - The one-column model is a lookup, not a decision tree: each row is
//!   predicted from the other folds' rows in the same level, value or bin
//!   (M1's layout at a finer resolution). It needs no training, so all rows
//!   are used instead of ppscore's 5 000-row sample, and the whole score is
//!   computed from per-(row group, fold) totals in one pass.
//! - Binary target: 2·AUC − 1 instead of weighted F1 over a baseline; AUC
//!   needs no threshold and is not moved by class imbalance. Numeric target:
//!   out-of-fold R² instead of MAE over the median's MAE (row means minimise
//!   squared error). Multiclass: accuracy gain over always guessing the
//!   majority class, (acc − base) / (1 − base), ppscore's normalisation.
//! - Folds: 4, as ppscore's default; assignment is a hash of the row number,
//!   so runs are reproducible.
//! The id-column leak check is deepchecks' identifier–label correlation
//! (`identifier_label_correlation.py`): the same score with the id as the
//! predictor. Row position and the target's lag-1 autocorrelation in file
//! order extend it to files without an id.

const std = @import("std");
const an = @import("analyze.zig");
const tr = @import("target_rate.zig");
const bars = @import("bars.zig");
const Role = an.Role;

pub const folds = 4;

/// Finer than M1's one-screen layout: enough levels that an id-like column
/// can show its signal, enough bins that a smooth numeric is not flattened.
pub const resolution: tr.Resolution = .{ .levels = 1024, .bins = 64 };

/// Multiclass targets with more classes are not scored.
const max_classes = 64;

/// A single feature at or above this power is reported as suspiciously
/// strong (deepchecks warns at PPS ≥ 0.8).
pub const strong = 0.8;

/// The id, row position or autocorrelation is a leak when its signal is
/// both large enough to matter and too large for chance: at least `leak_min`
/// and, where a null distribution is known, `leak_z` standard errors.
pub const leak_min = 0.01;
pub const leak_z = 5;

/// Fewer labelled train rows than this: scores are shown, but nothing is
/// reported from them — a power estimated from a handful of rows means
/// nothing.
pub const min_rows = 100;

pub const Subject = enum { feature, id, order };

pub const Score = struct {
    subject: Subject,
    /// Column index; null for row position.
    column: ?usize,
    /// Out-of-fold predictive power in [0, 1].
    power: f64,
    /// Binary target: out-of-fold AUC, and its z against 0.5.
    auc: ?f64 = null,
    z: ?f64 = null,
};

pub const Task = enum { binary, regression, multiclass };

/// The target's lag-1 dependence in file order.
pub const Order = struct {
    /// Binary/numeric: lag-1 autocorrelation. Multiclass: share of
    /// consecutive rows with the same class minus its expectation.
    stat: f64,
    z: f64,
};

const Cell = struct { n: f64 = 0, sum: f64 = 0, sumsq: f64 = 0 };

fn fold(r: usize) usize {
    var h = std.hash.Wyhash.init(0x5eed);
    h.update(std.mem.asBytes(&r));
    return @intCast(h.final() % folds);
}

/// Per-row training data for the score.
const Target = struct {
    task: Task,
    /// Binary 1/0 or numeric value; NaN when missing. Empty for multiclass.
    y: []const f64 = &.{},
    /// Multiclass class id; `an.no_level` when missing.
    class: []const u32 = &.{},
    n_classes: usize = 0,
    fold: []const u8,
    n: usize,
};

/// Group index of every train row, plus the number of groups.
const Groups = struct { of: []const u32, n: usize };

fn score(arena: std.mem.Allocator, t: *const Target, g: Groups) !Score {
    var out: Score = .{ .subject = .feature, .column = null, .power = 0 };
    switch (t.task) {
        .binary, .regression => {
            const cells = try arena.alloc([folds]Cell, g.n);
            @memset(cells, [_]Cell{.{}} ** folds);
            var all: Cell = .{};
            for (t.y, g.of, t.fold) |y, gi, f| {
                if (std.math.isNan(y)) continue;
                const c = &cells[gi][f];
                c.n += 1;
                c.sum += y;
                c.sumsq += y * y;
                all.n += 1;
                all.sum += y;
                all.sumsq += y * y;
            }
            if (all.n < 2) return out;
            const mean = all.sum / all.n;
            // Prediction for each (group, fold): the group's mean over the
            // other folds, or the overall mean when they hold none.
            var preds: std.ArrayList(PredGroup) = .empty;
            var sse: f64 = 0;
            for (cells) |gc| {
                var tot: Cell = .{};
                for (gc) |c| {
                    tot.n += c.n;
                    tot.sum += c.sum;
                }
                for (gc) |c| {
                    if (c.n == 0) continue;
                    const on = tot.n - c.n;
                    const p = if (on > 0) (tot.sum - c.sum) / on else mean;
                    sse += c.sumsq - 2 * p * c.sum + c.n * p * p;
                    if (t.task == .binary) try preds.append(arena, .{ .p = p, .pos = c.sum, .neg = c.n - c.sum });
                }
            }
            if (t.task == .regression) {
                const sst = all.sumsq - all.n * mean * mean;
                out.power = if (sst > 0) @max(0, 1 - sse / sst) else 0;
                return out;
            }
            const S = struct {
                fn less(_: void, x: PredGroup, y: PredGroup) bool {
                    return x.p < y.p;
                }
            };
            std.mem.sort(PredGroup, preds.items, {}, S.less);
            const auc_v = aucFromGroups(preds.items);
            const pos = all.sum;
            const neg = all.n - all.sum;
            out.auc = auc_v;
            out.power = @max(0, 2 * auc_v - 1);
            const se = @sqrt((pos + neg + 1) / (12 * pos * neg));
            out.z = if (pos > 0 and neg > 0) (auc_v - 0.5) / se else 0;
        },
        .multiclass => {
            const k = t.n_classes;
            const counts = try arena.alloc(f64, g.n * folds * k);
            @memset(counts, 0);
            const totals = try arena.alloc(f64, k);
            @memset(totals, 0);
            var labelled: f64 = 0;
            for (t.class, g.of, t.fold) |cl, gi, f| {
                if (cl == an.no_level) continue;
                counts[(gi * folds + f) * k + cl] += 1;
                totals[cl] += 1;
                labelled += 1;
            }
            if (labelled == 0) return out;
            const majority = std.mem.indexOfMax(f64, totals);
            const base = totals[majority] / labelled;
            const other = try arena.alloc(f64, k);
            var correct: f64 = 0;
            for (0..g.n) |gi| for (0..folds) |f| {
                const cell = counts[(gi * folds + f) * k ..][0..k];
                @memset(other, 0);
                var on: f64 = 0;
                for (0..folds) |f2| if (f2 != f) for (counts[(gi * folds + f2) * k ..][0..k], other) |x, *o| {
                    o.* += x;
                    on += x;
                };
                const pred = if (on > 0) std.mem.indexOfMax(f64, other) else majority;
                correct += cell[pred];
            };
            const acc = correct / labelled;
            out.power = if (base < 1) @max(0, (acc - base) / (1 - base)) else 0;
        },
    }
    return out;
}

const PredGroup = struct { p: f64, pos: f64, neg: f64 };

/// AUC from prediction groups sorted by prediction: groups with equal
/// predictions are ties and count half.
fn aucFromGroups(sorted: []const PredGroup) f64 {
    var neg_below: f64 = 0;
    var pos_total: f64 = 0;
    var neg_total: f64 = 0;
    var area: f64 = 0;
    var i: usize = 0;
    while (i < sorted.len) {
        var j = i;
        var pos: f64 = 0;
        var neg: f64 = 0;
        while (j < sorted.len and sorted[j].p == sorted[i].p) : (j += 1) {
            pos += sorted[j].pos;
            neg += sorted[j].neg;
        }
        area += pos * (neg_below + neg / 2);
        neg_below += neg;
        pos_total += pos;
        neg_total += neg;
        i = j;
    }
    if (pos_total == 0 or neg_total == 0) return 0.5;
    return area / (pos_total * neg_total);
}

fn groupsOf(arena: std.mem.Allocator, l: *const tr.Layout, c: *const an.Column, p: *const an.PerTable) !Groups {
    const of = try arena.alloc(u32, p.n);
    for (of, 0..) |*g, r| g.* = l.rowOf(c, p, r);
    return .{ .of = of, .n = l.labels.items.len };
}

/// Row position as a predictor: `resolution.bins` equal blocks of the file.
fn positionGroups(arena: std.mem.Allocator, n: usize) !Groups {
    const of = try arena.alloc(u32, n);
    const b = resolution.bins;
    for (of, 0..) |*g, r| g.* = @intCast(r * b / @max(n, 1));
    return .{ .of = of, .n = b };
}

fn orderStat(arena: std.mem.Allocator, t: *const Target) !?Order {
    switch (t.task) {
        .binary, .regression => {
            var n: f64 = 0;
            var mean: f64 = 0;
            for (t.y) |y| if (!std.math.isNan(y)) {
                n += 1;
                mean += (y - mean) / n;
            };
            if (n < 3) return null;
            var num: f64 = 0;
            var den: f64 = 0;
            var prev: ?f64 = null;
            for (t.y) |y| {
                if (std.math.isNan(y)) continue;
                den += (y - mean) * (y - mean);
                if (prev) |p| num += (p - mean) * (y - mean);
                prev = y;
            }
            if (den == 0) return null;
            const r = num / den;
            return .{ .stat = r, .z = r * @sqrt(n) };
        },
        .multiclass => {
            const counts = try arena.alloc(f64, t.n_classes);
            @memset(counts, 0);
            var n: f64 = 0;
            var same: f64 = 0;
            var prev: ?u32 = null;
            for (t.class) |cl| {
                if (cl == an.no_level) continue;
                counts[cl] += 1;
                n += 1;
                if (prev) |p| same += @floatFromInt(@intFromBool(p == cl));
                prev = cl;
            }
            if (n < 3) return null;
            var e: f64 = 0;
            for (counts) |k| e += (k / n) * (k / n);
            const share = same / (n - 1);
            const sd = @sqrt(e * (1 - e) / (n - 1));
            return .{ .stat = share - e, .z = if (sd > 0) (share - e) / sd else 0 };
        },
    }
}

/// Fill `cx.a.signal` (features ranked by power, then the id and row-order
/// scores), add leak and strong-feature findings, and re-rank M1's tables by
/// this out-of-fold power instead of in-sample η².
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    const ti = a.target orelse return;
    const tc = &a.columns[ti];
    const train = tc.at(.train) orelse return;
    const arena = cx.arena;

    const mode, const positive = tr.targetMode(a);
    var t: Target = .{ .task = undefined, .fold = undefined, .n = train.n };
    switch (mode) {
        .binary => t.task = .binary,
        .mean => t.task = .regression,
        .none => {
            if (tc.kind != .categorical or tc.levels.len > max_classes) return;
            t.task = .multiclass;
        },
    }
    if (t.task == .multiclass) {
        t.class = train.cat;
        t.n_classes = tc.levels.len;
    } else {
        t.y = (try tr.targetValues(cx, .train, mode, positive)) orelse return;
    }
    const fo = try arena.alloc(u8, train.n);
    for (fo, 0..) |*f, r| f.* = @intCast(fold(r));
    t.fold = fo;
    a.signal_task = t.task;

    var scores: std.ArrayList(Score) = .empty;
    for (a.columns, 0..) |*c, ci| {
        if (c.use == .target or c.kind == .empty) continue;
        const p = c.at(.train) orelse continue;
        const l = try tr.layout(cx, c, p, resolution);
        var s = try score(arena, &t, try groupsOf(arena, &l, c, p));
        s.column = ci;
        s.subject = if (c.use == .id) .id else .feature;
        try scores.append(arena, s);
    }
    var pos = try score(arena, &t, try positionGroups(arena, train.n));
    pos.subject = .order;
    try scores.append(arena, pos);

    const S = struct {
        fn rank(_: void, x: Score, y: Score) bool {
            const kx = @intFromBool(x.subject != .feature);
            const ky = @intFromBool(y.subject != .feature);
            if (kx != ky) return kx < ky;
            return x.power > y.power;
        }
    };
    std.mem.sort(Score, scores.items, {}, S.rank);
    a.signal = scores.items;
    a.order = try orderStat(arena, &t);

    // Findings.
    var labelled: usize = 0;
    switch (t.task) {
        .multiclass => for (t.class) |cl| {
            labelled += @intFromBool(cl != an.no_level);
        },
        else => for (t.y) |y| {
            labelled += @intFromBool(!std.math.isNan(y));
        },
    }
    if (labelled < min_rows) {
        rerank(a);
        return;
    }
    for (scores.items) |s| {
        const name = if (s.column) |ci| a.columns[ci].name else "row position";
        switch (s.subject) {
            .feature => if (s.power >= strong)
                try cx.add(.warn, .signal, .train, name, "predicts the target almost alone (power {d:.3}): check that it is not derived from the target", .{s.power}),
            .id, .order => if (isLeak(s)) {
                const what = if (s.subject == .id) "the id column" else "row position in the file";
                if (s.auc) |auc_v|
                    try cx.add(.warn, .leak, .train, name, "the target is predictable from {s}: power {d:.4}, AUC {d:.4}, z {d:.1}", .{ what, s.power, auc_v, s.z.? })
                else
                    try cx.add(.warn, .leak, .train, name, "the target is predictable from {s}: power {d:.4}", .{ what, s.power });
            },
        }
    }
    if (a.order) |o| if (@abs(o.stat) >= leak_min and o.z >= leak_z)
        try cx.add(.warn, .leak, .train, null, "neighbouring rows share their target more than chance: lag-1 {s} {d:.4}, z {d:.1} — the file is sorted or grouped by something related to the target", .{ if (t.task == .multiclass) "same-class excess" else "autocorrelation", o.stat, o.z });

    rerank(a);
}

pub fn isLeak(s: Score) bool {
    if (s.power < leak_min) return false;
    if (s.z) |z| return z >= leak_z;
    return true;
}

/// M1's tables in the order of this power (features only).
fn rerank(a: *an.Analysis) void {
    const Ctx = struct {
        a: *const an.Analysis,
        fn powerOf(ctx: @This(), ci: usize) f64 {
            for (ctx.a.signal) |s| if (s.column == ci) return s.power;
            return -1;
        }
        fn less(ctx: @This(), x: tr.Feature, y: tr.Feature) bool {
            return ctx.powerOf(x.column) > ctx.powerOf(y.column);
        }
    };
    const rates: []tr.Feature = @constCast(a.target_rates);
    std.mem.sort(tr.Feature, rates, Ctx{ .a = a }, Ctx.less);
}

fn powerHeader(task: Task) []const u8 {
    return switch (task) {
        .binary => "power = 2·AUC − 1",
        .regression => "power = out-of-fold R²",
        .multiclass => "power = accuracy gain over the majority class",
    };
}

/// `limit`: features shown; 0 = all.
pub fn write(w: *std.Io.Writer, a: *const an.Analysis, limit: usize) std.Io.Writer.Error!void {
    if (a.signal.len == 0) return;
    try w.print("\nSINGLE-FEATURE SIGNAL   out of fold ({d} folds) · {s}\n", .{ folds, powerHeader(a.signal_task) });
    var width: usize = 12;
    for (a.signal) |s| width = @max(width, @min(32, nameOf(a, s).len));
    var shown: usize = 0;
    var features: usize = 0;
    for (a.signal) |s| features += @intFromBool(s.subject == .feature);
    for (a.signal) |s| {
        if (s.subject != .feature) continue;
        if (limit != 0 and shown == limit) break;
        shown += 1;
        try line(w, a, s, width);
    }
    if (shown < features) try w.print("  … {d} more features (--top 0 shows all)\n", .{features - shown});
    try w.writeAll("  leak checks — these should score 0:\n");
    for (a.signal) |s| if (s.subject != .feature) try line(w, a, s, width);
    if (a.order) |o| try w.print("  {s: <12} lag-1 {s} {d:.4} (z {d:.1}){s}\n", .{ "file order", if (a.signal_task == .multiclass) "same-class excess" else "autocorrelation", o.stat, o.z, if (@abs(o.stat) >= leak_min and o.z >= leak_z) "   LEAK?" else "" });
}

fn nameOf(a: *const an.Analysis, s: Score) []const u8 {
    return if (s.column) |ci| a.columns[ci].name else "row position";
}

fn line(w: *std.Io.Writer, a: *const an.Analysis, s: Score, width: usize) std.Io.Writer.Error!void {
    const name = nameOf(a, s);
    const cut = name.len > 32;
    var end = @min(name.len, 31);
    while (cut and end > 0 and (name[end] & 0xC0) == 0x80) end -= 1; // UTF-8 boundary
    const shown = if (cut) name[0..end] else name;
    try w.print("  {s}{s}", .{ shown, if (cut) "…" else "" });
    try w.splatByteAll(' ', width - shown.len - @intFromBool(cut) + 2);
    try w.print("{d:.4} ", .{s.power});
    try bars.bar(w, s.power, 20);
    if (s.auc) |auc_v| try w.print("  AUC {d:.4}", .{auc_v});
    switch (s.subject) {
        .feature => {},
        .id => try w.writeAll(if (isLeak(s)) "   id column — LEAK?" else "   id column"),
        .order => try w.writeAll(if (isLeak(s)) "   LEAK?" else ""),
    }
    try w.writeAll("\n");
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

fn analyzed(arena: std.mem.Allocator, csv: []const u8) !an.Analysis {
    var tables = [_]tbl.Table{try tbl.parse(arena, .train, "train", csv)};
    return an.analyze(arena, try arena.dupe(tbl.Table, &tables), .{ .target = "y", .shift_warn = 1 });
}

fn scoreOf(a: *const an.Analysis, name: []const u8) Score {
    for (a.signal) |s| if (std.mem.eql(u8, nameOf(a, s), name)) return s;
    unreachable; // zsnag:ok test helper: the fixture has the column
}

/// Deterministic noise in [0, 1).
fn noise(i: usize, salt: u64) f64 {
    var h = std.hash.Wyhash.init(salt);
    h.update(std.mem.asBytes(&i));
    return @as(f64, @floatFromInt(h.final() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

test "AUC from groups: perfect, inverse, ties, chance" {
    const P = PredGroup;
    try testing.expectEqual(@as(f64, 1), aucFromGroups(&[_]P{ .{ .p = 0, .pos = 0, .neg = 5 }, .{ .p = 1, .pos = 5, .neg = 0 } }));
    try testing.expectEqual(@as(f64, 0), aucFromGroups(&[_]P{ .{ .p = 0, .pos = 5, .neg = 0 }, .{ .p = 1, .pos = 0, .neg = 5 } }));
    try testing.expectEqual(@as(f64, 0.5), aucFromGroups(&[_]P{.{ .p = 0.3, .pos = 4, .neg = 6 }}));
    // Two groups with equal predictions are one tie group.
    try testing.expectEqual(@as(f64, 0.5), aucFromGroups(&[_]P{ .{ .p = 0.3, .pos = 4, .neg = 0 }, .{ .p = 0.3, .pos = 0, .neg = 6 } }));
    // Positives: one beats both negatives below it and ties the one beside
    // it (2.5), one beats all three (3): (2.5 + 3) / (2 pos · 3 neg).
    try testing.expectApproxEqAbs(@as(f64, 5.5 / 6.0), aucFromGroups(&[_]P{ .{ .p = 0, .pos = 0, .neg = 2 }, .{ .p = 1, .pos = 1, .neg = 1 }, .{ .p = 2, .pos = 1, .neg = 0 } }), 1e-12);
}

test "binary: a deciding feature scores ~1, noise ~0, ranked first; strong-feature warning" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,noise,decides,y\n");
    for (0..4000) |i| {
        const d = noise(i, 1) < 0.5;
        try csv.print(arena, "{d},{d:.6},{s},{d}\n", .{ i, noise(i, 2), if (d) "p" else "q", @intFromBool(d) });
    }
    const a = try analyzed(arena, csv.items);
    try testing.expectEqual(Task.binary, a.signal_task);
    try testing.expectEqualStrings("decides", nameOf(&a, a.signal[0]));
    try testing.expectApproxEqAbs(@as(f64, 1), scoreOf(&a, "decides").power, 1e-9);
    try testing.expect(scoreOf(&a, "noise").power < 0.05);
    try testing.expect(a.has(.signal));
    try testing.expect(!a.has(.leak));
}

test "leaks: target sorted by id is caught on id, row position and autocorrelation; shuffled is not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]bool{ true, false }) |sorted| {
        var csv: std.ArrayList(u8) = .empty;
        try csv.appendSlice(arena, "id,x,y\n");
        for (0..4000) |i| {
            // Sorted: the first 40% are 1. Shuffled: noise, same base rate.
            const y = if (sorted) i < 1600 else noise(i, 3) < 0.4;
            try csv.print(arena, "{d},{d:.6},{d}\n", .{ i, noise(i, 4), @intFromBool(y) });
        }
        const a = try analyzed(arena, csv.items);
        var leaks: usize = 0;
        for (a.findings.items) |f| leaks += @intFromBool(f.code == .leak);
        if (sorted) {
            try testing.expect(isLeak(scoreOf(&a, "id")));
            try testing.expect(isLeak(scoreOf(&a, "row position")));
            try testing.expect(a.order.?.z >= leak_z);
            try testing.expectEqual(@as(usize, 3), leaks);
        } else {
            try testing.expectEqual(@as(usize, 0), leaks);
            try testing.expect(scoreOf(&a, "id").power < leak_min);
        }
    }
}

test "regression: out-of-fold R² near the true share of explained variance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,g,y\n");
    // y = group effect (±1) + uniform noise of variance 1/3·(√3)²/… :
    // noise ∈ [−√3, √3) has variance 1, effect variance 1 → R² ≈ 0.5.
    for (0..8000) |i| {
        const g = noise(i, 5) < 0.5;
        const e = (noise(i, 6) * 2 - 1) * @sqrt(3.0);
        // +10: a target far from zero, so Σy² and the total sum of squares
        // differ and R² must use the latter.
        try csv.print(arena, "{d},{s},{d:.6}\n", .{ i, if (g) "a" else "b", 10 + (if (g) @as(f64, 1) else -1) + e });
    }
    const a = try analyzed(arena, csv.items);
    try testing.expectEqual(Task.regression, a.signal_task);
    try testing.expectApproxEqAbs(@as(f64, 0.5), scoreOf(&a, "g").power, 0.03);
}

test "multiclass: accuracy gain over the majority class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,f,junk,pairs,y\n");
    // f names the class exactly; junk is unrelated; pairs has a level per
    // two rows, which scored in-fold would look predictive.
    const classes = [_][]const u8{ "lo", "mid", "hi" };
    for (0..3000) |i| {
        const k: usize = @intFromFloat(noise(i, 7) * 3);
        try csv.print(arena, "{d},f{d},j{d},p{d},{s}\n", .{ i, k, @as(usize, @intFromFloat(noise(i, 8) * 5)), i / 2, classes[k] });
    }
    const a = try analyzed(arena, csv.items);
    try testing.expectEqual(Task.multiclass, a.signal_task);
    try testing.expectApproxEqAbs(@as(f64, 1), scoreOf(&a, "f").power, 1e-9);
    try testing.expect(scoreOf(&a, "junk").power < 0.05);
    try testing.expect(scoreOf(&a, "pairs").power < 0.05);
}

test "isLeak: large enough and beyond chance, both" {
    try testing.expect(isLeak(.{ .subject = .id, .column = 0, .power = 0.05, .z = 6 }));
    try testing.expect(!isLeak(.{ .subject = .id, .column = 0, .power = 0.05, .z = 2 }));
    try testing.expect(!isLeak(.{ .subject = .id, .column = 0, .power = 0.005, .z = 10 }));
    try testing.expect(isLeak(.{ .subject = .order, .column = null, .power = 0.05 }));
}

test "M1's tables follow this ranking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,weak,many,strong,y\n");
    // `many` has a level per 2 rows: in-sample η² is high, out-of-fold
    // power is ~0. `strong` decides y 90% of the time.
    for (0..2000) |i| {
        const y = noise(i, 9) < 0.5;
        const s = if (noise(i, 10) < 0.9) y else !y;
        try csv.print(arena, "{d},{s},m{d},{s},{d}\n", .{ i, if (noise(i, 11) < 0.5) "a" else "b", i / 2, if (s) "s1" else "s0", @intFromBool(y) });
    }
    const a = try analyzed(arena, csv.items);
    try testing.expectEqualStrings("strong", a.columns[a.target_rates[0].column].name);
    try testing.expect(scoreOf(&a, "many").power < 0.1);
}

test "too few labelled rows: scores computed, nothing reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,x,y\n");
    for (0..min_rows - 1) |i| try csv.print(arena, "{d},{s},{d}\n", .{ i, if (i < 50) "a" else "b", @intFromBool(i < 50) });
    const a = try analyzed(arena, csv.items);
    try testing.expect(scoreOf(&a, "x").power > 0.9);
    try testing.expect(!a.has(.signal) and !a.has(.leak));
}
