// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M8 — the structure of missing values (docs/PLAN.md).
//!
//! - **Missing together**: the Pearson correlation of two columns' missing
//!   indicators (the φ coefficient), over columns that are partly missing —
//!   ydata-profiling's nullity heatmap (`model/pandas/missing_pandas.py:31-41`,
//!   `model/missing.py:84-104`, MIT, re-read at 98b1aba), which drops columns
//!   with no or only missing values and needs at least two columns left.
//!   zscour reports pairs at φ ≥ 0.9 instead of drawing every pair.
//! - **Missing in test, never in train** (added here): a model never saw a
//!   missing value in that column, so how it treats one in test is an
//!   accident of the library. Also missing shares that differ a lot between
//!   train and test.
//! - **Near-empty rows** (added here): rows missing at least half their
//!   features.
//! Indicators are bitsets: a pair costs a popcount per 64 rows.

const std = @import("std");
const an = @import("analyze.zig");
const Role = an.Role;

pub const together = 0.9;
/// Missing shares differing between train and test by at least this many
/// times, and `share_gap` percentage points, at z ≥ `share_z`.
const share_ratio = 2.0;
const share_gap = 0.01;
const share_z = 5;

pub const Pair = struct {
    a: usize,
    b: usize,
    /// φ: Pearson correlation of the two missing indicators.
    r: f64,
    /// Rows where both are missing.
    both: usize,
};

const Bits = struct {
    words: []u64,
    count: usize,
};

fn indicator(arena: std.mem.Allocator, c: *const an.Column, p: *const an.PerTable) !Bits {
    const words = try arena.alloc(u64, (p.n + 63) / 64);
    @memset(words, 0);
    var count: usize = 0;
    for (0..p.n) |r| {
        const missing = switch (c.kind) {
            .numeric => std.math.isNan(p.num[r]),
            .categorical => p.cat[r] == an.no_level,
            .empty => true,
        };
        if (missing) {
            words[r / 64] |= @as(u64, 1) << @intCast(r % 64);
            count += 1;
        }
    }
    return .{ .words = words, .count = count };
}

/// φ from the four cell counts, given both-missing and the margins.
pub fn phi(n: f64, both: f64, ma: f64, mb: f64) f64 {
    const den = ma * (n - ma) * mb * (n - mb);
    if (den <= 0) return 0;
    return (n * both - ma * mb) / @sqrt(den);
}

/// Fill `cx.a.missing_together` (train) and add findings: pairs going
/// missing together, missingness that differs from train to test, and
/// near-empty rows.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    const arena = cx.arena;
    const train = a.table(.train) orelse return;
    const n = train.n_rows;

    // Partly missing features in train.
    var cols: std.ArrayList(usize) = .empty;
    var bits: std.ArrayList(Bits) = .empty;
    var n_features: usize = 0;
    for (a.columns, 0..) |*c, ci| {
        if (c.use != .feature) continue;
        const p = c.at(.train) orelse continue;
        const b = try indicator(arena, c, p);
        // An entirely empty column is reported as such; it neither pairs
        // nor counts towards a row's "half its features missing".
        if (b.count == n) continue;
        n_features += 1;
        if (b.count == 0) continue;
        try cols.append(arena, ci);
        try bits.append(arena, b);
    }

    var pairs: std.ArrayList(Pair) = .empty;
    if (cols.items.len >= 2) {
        const nf: f64 = @floatFromInt(n);
        for (bits.items, 0..) |x, i| for (bits.items[i + 1 ..], i + 1..) |y, j| {
            var both: usize = 0;
            for (x.words, y.words) |wx, wy| both += @popCount(wx & wy);
            const r = phi(nf, @floatFromInt(both), @floatFromInt(x.count), @floatFromInt(y.count));
            if (r >= together) try pairs.append(arena, .{ .a = cols.items[i], .b = cols.items[j], .r = r, .both = both });
        };
    }
    const S = struct {
        fn stronger(_: void, p: Pair, q: Pair) bool {
            return p.r > q.r;
        }
    };
    std.mem.sort(Pair, pairs.items, {}, S.stronger);
    a.missing_together = pairs.items;
    for (pairs.items) |p|
        try cx.add(.info, .missing_together, .train, null, "{s} and {s} go missing together (φ {d:.3}, both missing in {d} rows): probably one cause — one indicator may cover both", .{ a.columns[p.a].name, a.columns[p.b].name, p.r, p.both });

    // Near-empty rows: missing at least half of the features.
    if (n_features >= 4 and cols.items.len >= 2) {
        const per_row = try arena.alloc(u16, n);
        @memset(per_row, 0);
        for (bits.items) |b| for (b.words, 0..) |word, wi| {
            var w = word;
            while (w != 0) : (w &= w - 1) per_row[wi * 64 + @ctz(w)] +|= 1;
        };
        var near_empty: usize = 0;
        for (per_row) |k| near_empty += @intFromBool(@as(usize, k) * 2 >= n_features);
        if (near_empty > 0)
            try cx.add(.info, .missing_together, .train, null, "{d} rows miss at least half of their {d} features: near-empty records — check how they came about before a model learns from them", .{ near_empty, n_features });
    }

    // Missingness from train to test.
    for (a.columns) |*c| {
        if (c.use != .feature) continue;
        const ptr = c.at(.train) orelse continue;
        const pte = c.at(.@"test") orelse continue;
        const mtr = ptr.missingCount(c.kind);
        const mte = pte.missingCount(c.kind);
        if (mte == 0) continue;
        if (mtr == 0) {
            try cx.add(.warn, .missing_together, .@"test", c.name, "{d} missing in test, never in train: a model never learned what a missing value here means", .{mte});
            continue;
        }
        const ptrain = @as(f64, @floatFromInt(mtr)) / @as(f64, @floatFromInt(ptr.n));
        const ptest = @as(f64, @floatFromInt(mte)) / @as(f64, @floatFromInt(pte.n));
        const hi = @max(ptrain, ptest);
        const lo = @min(ptrain, ptest);
        const pooled = @as(f64, @floatFromInt(mtr + mte)) / @as(f64, @floatFromInt(ptr.n + pte.n));
        const se = @sqrt(pooled * (1 - pooled) * (1 / @as(f64, @floatFromInt(ptr.n)) + 1 / @as(f64, @floatFromInt(pte.n))));
        if (hi >= share_ratio * lo and hi - lo >= share_gap and se > 0 and (hi - lo) / se >= share_z)
            try cx.add(.warn, .missing_together, .@"test", c.name, "missing in {d:.1}% of test rows against {d:.1}% of train: the missing values are not drawn like train's", .{ 100 * ptest, 100 * ptrain });
    }
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.missing_together.len == 0) return;
    try w.writeAll("\nMISSING TOGETHER   φ = correlation of the two columns' missing indicators (train)\n");
    for (a.missing_together) |p|
        try w.print("  φ {d:.3}   {s} · {s}   both missing in {d} rows\n", .{ p.r, a.columns[p.a].name, a.columns[p.b].name, p.both });
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

test "phi by hand" {
    // n = 100, a missing in 10, b in 10, both in 10: identical → 1.
    try testing.expectApproxEqAbs(@as(f64, 1), phi(100, 10, 10, 10), 1e-12);
    // Never together, 50/50 each: −1.
    try testing.expectApproxEqAbs(@as(f64, -1), phi(100, 0, 50, 50), 1e-12);
    // Independent: both = 10·20/100 = 2 → 0.
    try testing.expectApproxEqAbs(@as(f64, 0), phi(100, 2, 10, 20), 1e-12);
    try testing.expectEqual(@as(f64, 0), phi(100, 0, 0, 10));
}

fn analyzed(arena: std.mem.Allocator, train: []const u8, tst: ?[]const u8) !an.Analysis {
    var tables: std.ArrayList(tbl.Table) = .empty;
    try tables.append(arena, try tbl.parse(arena, .train, "train", train));
    if (tst) |t| try tables.append(arena, try tbl.parse(arena, .@"test", "test", t));
    return an.analyze(arena, tables.items, .{ .target = "y", .shift_warn = 1, .adversarial = false });
}

test "columns missing together are paired; independent ones are not; near-empty rows counted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,a,b,c,d,e,y\n");
    for (0..1000) |i| {
        // a and b: missing on the same 100 rows (a form section skipped).
        // c: missing on its own 100 rows, unrelated. d: never missing.
        const ab = i % 10 == 0;
        const c = (i * 7) % 10 == 3;
        // e: missing everywhere — must not make c's rows look near-empty.
        try csv.print(arena, "{d},{s},{s},{s},{d},,{d}\n", .{ i, if (ab) "" else "1", if (ab) "" else "2", if (c) "" else "x", i % 5, i % 2 });
    }
    const a = try analyzed(arena, csv.items, null);
    try testing.expectEqual(@as(usize, 1), a.missing_together.len);
    try testing.expectEqualStrings("a", a.columns[a.missing_together[0].a].name);
    try testing.expectEqualStrings("b", a.columns[a.missing_together[0].b].name);
    try testing.expectEqual(@as(usize, 100), a.missing_together[0].both);
    // Rows 0, 10, … miss a and b (2 of 4 features): near-empty. Where c is
    // also missing they miss 3. Rows missing only c miss 1 of 4: not counted.
    var near: ?[]const u8 = null;
    for (a.findings.items) |f| if (f.code == .missing_together and std.mem.find(u8, f.msg, "near-empty") != null) {
        near = f.msg;
    };
    try testing.expect(std.mem.startsWith(u8, near.?, "100 rows"));
}

test "missing in test but never in train is a warning; a shifted share too; similar shares are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var train: std.ArrayList(u8) = .empty;
    var tst: std.ArrayList(u8) = .empty;
    try train.appendSlice(arena, "id,never,shifted,same,mild,y\n");
    try tst.appendSlice(arena, "id,never,shifted,same,mild\n");
    for (0..4000) |i| {
        // shifted: 2% missing in train, 20% in test. same: 5% in both.
        // mild: 10% against 16% — real (z ≈ 8) but under twice.
        try train.print(arena, "{d},1,{s},{s},{s},{d}\n", .{ i, if (i % 50 == 0) "" else "1", if (i % 20 == 0) "" else "1", if (i % 10 == 0) "" else "1", i % 2 });
        try tst.print(arena, "{d},{s},{s},{s},{s}\n", .{ 9000 + i, if (i % 25 == 0) "" else "1", if (i % 5 == 0) "" else "1", if (i % 20 == 0) "" else "1", if (i % 50 < 8) "" else "1" });
    }
    const a = try analyzed(arena, train.items, tst.items);
    var warned = [4]bool{ false, false, false, false };
    var never_msg = false;
    for (a.findings.items) |f| if (f.code == .missing_together and f.sev == .warn) {
        for ([_][]const u8{ "never", "shifted", "same", "mild" }, 0..) |name, k| warned[k] = warned[k] or std.mem.eql(u8, f.column.?, name);
        never_msg = never_msg or std.mem.find(u8, f.msg, "never in train") != null;
    };
    try testing.expect(warned[0] and warned[1] and !warned[2] and !warned[3]);
    try testing.expect(never_msg);
}

test "a partial overlap is not 'missing together'" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,a,p,y\n");
    // p is missing on a's 100 rows and 100 more: φ = 2/3.
    for (0..1000) |i| try csv.print(arena, "{d},{s},{s},{d}\n", .{ i, if (i % 10 == 0) "" else "1", if (i % 10 == 0 or i % 10 == 5) "" else "1", i % 2 });
    const a = try analyzed(arena, csv.items, null);
    try testing.expectEqual(@as(usize, 0), a.missing_together.len);
}

test "an entirely empty column does not count as a feature for near-empty rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,a,b,c,empty,y\n");
    // Three real features (too few for the near-empty check) plus one empty
    // column: counted, it would make four and every row "half missing".
    for (0..400) |i| try csv.print(arena, "{d},{s},{s},1,,{d}\n", .{ i, if (i % 4 == 0) "" else "1", if (i % 4 == 1) "" else "1", i % 2 });
    const a = try analyzed(arena, csv.items, null);
    for (a.findings.items) |f| try testing.expect(std.mem.find(u8, f.msg, "near-empty") == null);
}
