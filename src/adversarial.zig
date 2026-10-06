// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M5 — adversarial validation: can a classifier tell train rows from test
//! rows (and from extra rows)? (docs/PLAN.md)
//!
//! After deepchecks' multivariate drift (`multivariate_drift_utils.py:39-139`,
//! re-read at 98475d1; ideas only, AGPL): sample up to 10 000 rows a side,
//! keep the top 254 levels of a categorical and pool the rest, split 70/30,
//! fit gradient-boosted trees to the file label, score held-out AUC as
//! drift = max(2·AUC − 1, 0), and name the features the model leans on by
//! permutation importance (the AUC lost when one feature's values are
//! shuffled among the held-out rows). Differences, and why:
//! - The model is zarbor's GBDT at depth 3 × 50 rounds, not depth 2 × 10:
//!   it costs well under a second here and misses less.
//! - A drift is reported only when it is also beyond chance (z ≥ 5 against
//!   AUC 0.5), not on a bare threshold.
//! - Permutation importance uses 3 shuffles (deepchecks: 10) — the ranking,
//!   not the decimals, is the point.
//!
//! zarbor trains on a thread pool, and zscour's arena is not thread-safe, so
//! everything zarbor allocates comes from `Options.zarbor_gpa` (thread-safe)
//! and is freed here; only zscour's own scratch uses the arena.

const std = @import("std");
const zarbor = @import("zarbor");
const an = @import("analyze.zig");
const Role = an.Role;
const data = zarbor.data;
const booster = zarbor.booster;
const Pool = zarbor.pool.Pool;

/// Rows sampled from each file (deepchecks' default).
pub const max_rows_per_side = 10_000;
/// Fewer sampled rows a side than this: not run.
pub const min_rows_per_side = 100;
/// Levels kept per categorical; the rest share one. 254 + 1 = zarbor's
/// default categorical width limit (255).
pub const max_levels = 254;
/// Share of the sample held out for scoring.
const valid_tenths = 3;
const shuffles = 3;
const seed = 0x5c0e;

/// Drift (2·AUC − 1) at or above this, beyond chance, is a warning between
/// train and test.
pub const drift_warn = 0.1;
pub const z_min = 5;

const params: booster.Params = .{
    .n_rounds = 50,
    .verbose_eval = 0,
    .tree = .{ .max_depth = 3, .learning_rate = 0.1 },
};

pub const Importance = struct { column: usize, drop: f64 };

pub const Result = struct {
    /// The two files compared, e.g. train vs test.
    a: Role,
    b: Role,
    /// Rows sampled from each file.
    rows_per_side: usize,
    auc: f64,
    /// max(2·AUC − 1, 0): 0 = indistinguishable, 1 = fully separable.
    drift: f64,
    /// AUC's distance from 0.5 in standard errors.
    z: f64,
    /// Features the classifier leans on, strongest first (AUC lost when the
    /// feature is shuffled).
    top: []const Importance,
};

fn sampleRows(r: std.Random, arena: std.mem.Allocator, n: usize, m: usize) ![]u32 {
    const idx = try arena.alloc(u32, n);
    for (idx, 0..) |*x, i| x.* = @intCast(i);
    // Partial Fisher–Yates: the first `m` are a uniform sample.
    for (0..m) |i| {
        const j = i + r.uintLessThan(usize, n - i);
        std.mem.swap(u32, &idx[i], &idx[j]);
    }
    return idx[0..m];
}

/// zarbor needs ≤ 255 levels: the `max_levels` most common (both files
/// together) keep an id, the rest map to one "(other)" level.
const LevelMap = struct { map: []u32, names: [][]u8 };

fn levelMap(arena: std.mem.Allocator, c: *const an.Column, pa: *const an.PerTable, pb: *const an.PerTable) !LevelMap {
    const k = c.levels.len;
    const map = try arena.alloc(u32, k);
    if (k <= max_levels + 1) {
        const names = try arena.alloc([]u8, k);
        for (names, c.levels, map, 0..) |*n, l, *m, i| {
            n.* = try arena.dupe(u8, l);
            m.* = @intCast(i);
        }
        return .{ .map = map, .names = names };
    }
    const order = try arena.alloc(u32, k);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        a: []const usize,
        b: []const usize,
        fn more(ctx: @This(), x: u32, y: u32) bool {
            return ctx.a[x] + ctx.b[x] > ctx.a[y] + ctx.b[y];
        }
    };
    std.mem.sort(u32, order, Ctx{ .a = pa.level_counts, .b = pb.level_counts }, Ctx.more);
    const names = try arena.alloc([]u8, max_levels + 1);
    @memset(map, max_levels);
    for (order[0..max_levels], 0..) |id, rank| {
        map[id] = @intCast(rank);
        names[rank] = try arena.dupe(u8, c.levels[id]);
    }
    names[max_levels] = try arena.dupe(u8, "(other)");
    return .{ .map = map, .names = names };
}

fn aucZ(auc: f64, pos: f64, neg: f64) f64 {
    if (pos == 0 or neg == 0) return 0;
    return (auc - 0.5) / @sqrt((pos + neg + 1) / (12 * pos * neg));
}

fn compare(cx: an.Ctx, pool: *Pool, ra: Role, rb: Role) !?Result {
    const a = cx.a;
    const arena = cx.arena;
    const gpa = cx.opts.zarbor_gpa;
    const ta = a.table(ra) orelse return null;
    const tb = a.table(rb) orelse return null;

    var features: std.ArrayList(usize) = .empty;
    for (a.columns, 0..) |c, ci| {
        if (c.use != .feature or c.kind == .empty) continue;
        if (c.at(ra) == null or c.at(rb) == null) continue;
        try features.append(arena, ci);
    }
    if (features.items.len == 0) return null;

    // Typed: `@min` with the constant alone would pick u14 (10 000 fits),
    // and `2 * m` below would overflow it — which ReleaseFast does silently.
    const m: usize = @min(max_rows_per_side, @min(ta.n_rows, tb.n_rows));
    if (m < min_rows_per_side) return null;
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const rows_a = try sampleRows(rnd, arena, ta.n_rows, m);
    const rows_b = try sampleRows(rnd, arena, tb.n_rows, m);
    const n = 2 * m;

    // An in-memory frame: the features, then the file label (0 = a, 1 = b).
    const width = features.items.len + 1;
    const names = try arena.alloc([]u8, width);
    const kinds = try arena.alloc(data.ColumnKind, width);
    const values = try arena.alloc([]f32, width);
    const levels = try arena.alloc([][]u8, width);
    for (features.items, 0..) |ci, f| {
        const c = &a.columns[ci];
        names[f] = try arena.dupe(u8, c.name);
        values[f] = try arena.alloc(f32, n);
        const pa = c.at(ra).?;
        const pb = c.at(rb).?;
        switch (c.kind) {
            .numeric => {
                kinds[f] = .numeric;
                levels[f] = &.{};
                for (rows_a, 0..) |r, i| values[f][i] = @floatCast(pa.num[r]);
                for (rows_b, 0..) |r, i| values[f][m + i] = @floatCast(pb.num[r]);
            },
            .categorical => {
                kinds[f] = .categorical;
                const lm = try levelMap(arena, c, pa, pb);
                levels[f] = lm.names;
                for ([_]*const an.PerTable{ pa, pb }, [_][]const u32{ rows_a, rows_b }, 0..) |p, rows, side| {
                    for (rows, 0..) |r, i| {
                        const id = p.cat[r];
                        values[f][side * m + i] = if (id == an.no_level) std.math.nan(f32) else @floatFromInt(lm.map[id]);
                    }
                }
            },
            .empty => unreachable, // filtered above
        }
    }
    const label = width - 1;
    names[label] = try arena.dupe(u8, "zscour file label");
    kinds[label] = .numeric;
    levels[label] = &.{};
    values[label] = try arena.alloc(f32, n);
    @memset(values[label][0..m], 0);
    @memset(values[label][m..], 1);
    const frame: data.Frame = .{ .gpa = gpa, .n_rows = n, .names = names, .kinds = kinds, .values = values, .levels = levels };

    const enc: data.LabelEncoder = .{ .gpa = gpa };
    var ds = try data.quantise(gpa, pool, &frame, .{}, .{ .col = label, .enc = &enc }, &.{});
    defer ds.deinit();

    // 70/30 split by a hash of the sample position.
    var fit_rows: std.ArrayList(u32) = .empty;
    var val_rows: std.ArrayList(u32) = .empty;
    for (0..n) |i| {
        var h = std.hash.Wyhash.init(seed);
        h.update(std.mem.asBytes(&i));
        try (if (h.final() % 10 < valid_tenths) &val_rows else &fit_rows).append(arena, @intCast(i));
    }
    var fit = try data.subset(gpa, &ds, fit_rows.items);
    defer fit.deinit();
    var val = try data.subset(gpa, &ds, val_rows.items);
    defer val.deinit();

    var trained = try booster.train(gpa, pool, &fit, null, params, null);
    defer trained.model.deinit();

    const scores = try gpa.alloc(f32, val.n_rows);
    defer gpa.free(scores);
    trained.model.predictRaw(pool, &val, scores);
    const auc = try zarbor.metric.auc(gpa, scores, val.labels);
    var pos: f64 = 0;
    for (val.labels) |y| pos += y;
    const neg = @as(f64, @floatFromInt(val.n_rows)) - pos;

    // Permutation importance on the held-out rows. Prediction reads only the
    // row-major bins, so one column of `bins_rm` is shuffled and restored.
    const nf = val.n_features;
    const saved = try arena.alloc(data.BinIdx, val.n_rows);
    var imps: std.ArrayList(Importance) = .empty;
    for (features.items, 0..) |ci, f| {
        for (saved, 0..) |*s, r| s.* = val.bins_rm[r * nf + f];
        var lost: f64 = 0;
        for (0..shuffles) |_| {
            const perm = try arena.dupe(data.BinIdx, saved);
            rnd.shuffle(data.BinIdx, perm);
            for (perm, 0..) |b, r| val.bins_rm[r * nf + f] = b;
            trained.model.predictRaw(pool, &val, scores);
            lost += auc - try zarbor.metric.auc(gpa, scores, val.labels);
        }
        for (saved, 0..) |b, r| val.bins_rm[r * nf + f] = b;
        try imps.append(arena, .{ .column = ci, .drop = lost / shuffles });
    }
    const S = struct {
        fn more(_: void, x: Importance, y: Importance) bool {
            return x.drop > y.drop;
        }
    };
    std.mem.sort(Importance, imps.items, {}, S.more);

    return .{
        .a = ra,
        .b = rb,
        .rows_per_side = m,
        .auc = auc,
        .drift = @max(0, 2 * auc - 1),
        .z = aucZ(auc, pos, neg),
        .top = imps.items,
    };
}

pub fn isDrift(r: Result) bool {
    return r.z >= z_min and r.drift >= drift_warn;
}

/// Fill `cx.a.adversarial` for train vs test and train vs extra, and add a
/// finding for each.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    if (a.table(.train) == null) return;
    if (a.table(.@"test") == null and a.table(.extra) == null) return;
    const pool = try Pool.init(cx.opts.zarbor_gpa, cx.opts.threads);
    defer pool.deinit();

    var results: std.ArrayList(Result) = .empty;
    for ([_]Role{ .@"test", .extra }) |role| {
        const r = (try compare(cx, pool, .train, role)) orelse continue;
        try results.append(cx.arena, r);

        var lean: std.ArrayList(u8) = .empty;
        var shown: usize = 0;
        for (r.top) |imp| {
            if (shown == 3 or imp.drop < 0.005) break;
            try lean.print(cx.arena, "{s}{s} ({d:.3})", .{ if (shown > 0) ", " else "", a.columns[imp.column].name, imp.drop });
            shown += 1;
        }
        const leans = if (shown > 0) lean.items else "no single feature";
        if (isDrift(r)) {
            try cx.add(if (role == .@"test") .warn else .info, .adversarial, role, null, "a classifier tells {s} rows from train rows: AUC {d:.3}, drift {d:.3} (z {d:.1}) — {s} is not drawn like train; it leans most on {s}", .{ role.label(), r.auc, r.drift, r.z, role.label(), leans });
        } else if (r.z >= z_min) {
            try cx.add(.info, .adversarial, role, null, "a classifier tells {s} rows from train rows only slightly: AUC {d:.3}, drift {d:.3} (z {d:.1}); it leans most on {s}", .{ role.label(), r.auc, r.drift, r.z, leans });
        } else {
            try cx.add(.info, .adversarial, role, null, "a classifier cannot tell {s} rows from train rows: AUC {d:.3} (z {d:.1}) — consistent with one distribution", .{ role.label(), r.auc, r.z });
        }
    }
    a.adversarial = results.items;
}

pub fn write(w: *std.Io.Writer, a: *const an.Analysis) std.Io.Writer.Error!void {
    if (a.adversarial.len == 0) return;
    try w.writeAll("\nADVERSARIAL VALIDATION   gradient-boosted trees told to tell the files apart; drift = 2·AUC − 1\n");
    for (a.adversarial) |r| {
        try w.print("  {s} ({s}) vs train   AUC {d:.4}   drift {d:.4}   z {d:.1}   ({d} rows a side){s}\n", .{ r.b.label(), a.table(r.b).?.path, r.auc, r.drift, r.z, r.rows_per_side, if (isDrift(r)) "   DRIFT" else "" });
        // At chance there is nothing to attribute: importances are noise.
        if (r.z < z_min) {
            try w.writeAll("    indistinguishable — no feature to attribute\n");
            continue;
        }
        var shown: usize = 0;
        for (r.top) |imp| {
            if (shown == 5) break;
            shown += 1;
            try w.print("    {s: <32} AUC lost when shuffled {d:.4}\n", .{ a.columns[imp.column].name[0..@min(32, a.columns[imp.column].name.len)], imp.drop });
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

fn noise(i: usize, salt: u64) f64 {
    var h = std.hash.Wyhash.init(salt);
    h.update(std.mem.asBytes(&i));
    return @as(f64, @floatFromInt(h.final() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

fn analyzedThreads(arena: std.mem.Allocator, train: []const u8, tst: []const u8, threads: u32) !an.Analysis {
    var tables: std.ArrayList(tbl.Table) = .empty;
    try tables.append(arena, try tbl.parse(arena, .train, "train", train));
    try tables.append(arena, try tbl.parse(arena, .@"test", "test", tst));
    // testing.allocator is thread-safe and reports anything zarbor leaks.
    return an.analyze(arena, tables.items, .{ .shift_warn = 1, .zarbor_gpa = testing.allocator, .threads = threads });
}

fn analyzed(arena: std.mem.Allocator, train: []const u8, tst: []const u8) !an.Analysis {
    return analyzedThreads(arena, train, tst, 0);
}

fn files(arena: std.mem.Allocator, shift: f64) ![2][]const u8 {
    var out: [2][]const u8 = undefined;
    for (&out, 0..) |*o, side| {
        var csv: std.ArrayList(u8) = .empty;
        try csv.appendSlice(arena, "id,a,b,c\n");
        for (0..3000) |i| {
            const id = side * 3000 + i;
            // `b` is shifted in the second file by `shift`; `a` and `c` match.
            const b = noise(id, 2) + if (side == 1) shift else 0;
            try csv.print(arena, "{d},{d:.5},{d:.5},{s}\n", .{ id, noise(id, 1), b, if (noise(id, 3) < 0.5) "x" else "y" });
        }
        o.* = csv.items;
    }
    return out;
}

test "identical distributions: AUC near 0.5, no drift reported" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try files(arena, 0);
    const a = try analyzed(arena, f[0], f[1]);
    const r = a.adversarial[0];
    try testing.expect(@abs(r.auc - 0.5) < 0.05);
    try testing.expect(!isDrift(r));
    for (a.findings.items) |fd| if (fd.code == .adversarial) try testing.expect(fd.sev == .info);
}

test "a shifted feature is detected and named first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try files(arena, 0.3);
    const a = try analyzed(arena, f[0], f[1]);
    const r = a.adversarial[0];
    try testing.expect(isDrift(r));
    try testing.expectEqualStrings("b", a.columns[r.top[0].column].name);
    try testing.expect(r.top[0].drop > 0.1);
    try testing.expect(r.top[1].drop < 0.02);
    var warned = false;
    for (a.findings.items) |fd| warned = warned or (fd.code == .adversarial and fd.sev == .warn);
    try testing.expect(warned);
}

test "wide categoricals are pooled to zarbor's limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files_: [2]std.ArrayList(u8) = .{ .empty, .empty };
    for (&files_, 0..) |*csv, side| {
        try csv.appendSlice(arena, "id,user,x\n");
        for (0..1500) |i| try csv.print(arena, "{d},u{d},{d:.4}\n", .{ side * 1500 + i, i % 600, noise(i + side * 7919, 4) });
    }
    const a = try analyzed(arena, files_[0].items, files_[1].items);
    try testing.expectEqual(@as(usize, 1), a.adversarial.len);
    try testing.expect(!isDrift(a.adversarial[0]));
}

test "too few rows: not run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = try analyzed(arena_state.allocator(), "id,x\n0,1\n1,2\n", "id,x\n2,3\n");
    try testing.expectEqual(@as(usize, 0), a.adversarial.len);
}

test "the same result, bit for bit, on 1, 3 and 16 threads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const f = try files(arena, 0.1);
    var first: ?Result = null;
    for ([_]u32{ 1, 3, 16 }) |threads| {
        const a = try analyzedThreads(arena, f[0], f[1], threads);
        const r = a.adversarial[0];
        if (first) |want| {
            try testing.expectEqual(want.auc, r.auc);
            for (want.top, r.top) |x, y| {
                try testing.expectEqual(x.column, y.column);
                try testing.expectEqual(x.drop, y.drop);
            }
        } else first = r;
    }
}

test "the full sample size: 2 × 10 000 rows do not overflow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var f: [2]std.ArrayList(u8) = .{ .empty, .empty };
    for (&f, 0..) |*csv, side| {
        try csv.appendSlice(arena, "id,x\n");
        for (0..max_rows_per_side + 500) |i| try csv.print(arena, "{d},{d:.4}\n", .{ side * 20_000 + i, noise(side * 20_000 + i, 5) });
    }
    const a = try analyzed(arena, f[0].items, f[1].items);
    try testing.expectEqual(@as(usize, max_rows_per_side), a.adversarial[0].rows_per_side);
}

test "the report names features only when the files can be told apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]f64{ 0, 0.3 }) |shift| {
        const f = try files(arena, shift);
        const a = try analyzed(arena, f[0], f[1]);
        var buf: std.Io.Writer.Allocating = .init(arena);
        try write(&buf.writer, &a);
        const named = std.mem.find(u8, buf.written(), "AUC lost when shuffled") != null;
        try testing.expectEqual(shift > 0, named);
    }
}

test "isDrift needs both a large gap and z beyond chance" {
    const base: Result = .{ .a = .train, .b = .@"test", .rows_per_side = 100, .auc = 0.65, .drift = 0.3, .z = 2, .top = &.{} };
    try testing.expect(!isDrift(base));
    var big = base;
    big.z = 8;
    try testing.expect(isDrift(big));
    var small = big;
    small.drift = 0.05;
    try testing.expect(!isDrift(small));
}

test "wide categoricals keep their most frequent levels, wherever they first appear" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 600 rare filler levels come first, so the frequent ones get ids past
    // 254. Train's frequent levels are h0–h4, test's h5–h9: kept apart, the
    // files separate; pooled by id, they would not.
    var f: [2]std.ArrayList(u8) = .{ .empty, .empty };
    for (&f, 0..) |*csv, side| {
        try csv.appendSlice(arena, "id,lvl\n");
        for (0..600) |i| try csv.print(arena, "{d},f{d}\n", .{ side * 5000 + i, i });
        for (0..2000) |i| try csv.print(arena, "{d},h{d}\n", .{ side * 5000 + 600 + i, side * 5 + i % 5 });
    }
    const a = try analyzed(arena, f[0].items, f[1].items);
    try testing.expect(isDrift(a.adversarial[0]));
    try testing.expect(a.adversarial[0].drift > 0.5);
}
