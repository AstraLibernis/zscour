// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Cleaned copies of the data files. Rewrites only what the report flagged:
//! trims whitespace, writes every missing value as an empty field, folds case
//! variants to one spelling, maps a boolean target to 1/0, sorts rows by id,
//! puts columns in train's order, and writes UTF-8 without a BOM, LF line
//! endings and RFC 4180 quoting. Rows the parser skipped stay out. Numbers
//! keep their original text: nothing is re-formatted or rounded.

const std = @import("std");
const an = @import("analyze.zig");
const tbl = @import("table.zig");
const Analysis = an.Analysis;
const Table = tbl.Table;

const Writer = std.Io.Writer;

/// What one file's rewrite changed, per column.
pub const Changes = struct {
    role: tbl.Role,
    path: []const u8,
    rows: usize,
    skipped: usize,
    reordered: bool,
    /// Fields whose written text differs from the original, per output column.
    changed: []const usize,
    names: []const []const u8,
};

/// Output column order: train's, then any column train lacks.
fn columnOrder(arena: std.mem.Allocator, a: *const Analysis, t: *const Table) ![]usize {
    var order: std.ArrayList(usize) = .empty;
    for (a.columns, 0..) |c, i| if (c.at(t.role) != null) try order.append(arena, i);
    return order.items;
}

/// Row order: ascending numeric id when the file has one, else file order.
fn rowOrder(arena: std.mem.Allocator, a: *const Analysis, t: *const Table) ![]u32 {
    const order = try arena.alloc(u32, t.n_rows);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const ci = a.id orelse return order;
    const c = &a.columns[ci];
    if (c.kind != .numeric) return order;
    const p = c.at(t.role) orelse return order;
    const Ctx = struct {
        ids: []const f64,
        fn less(ctx: @This(), x: u32, y: u32) bool {
            // NaN (missing id) sorts last.
            const ix = ctx.ids[x];
            const iy = ctx.ids[y];
            if (std.math.isNan(iy)) return !std.math.isNan(ix);
            return ix < iy;
        }
    };
    std.mem.sort(u32, order, Ctx{ .ids = p.num }, Ctx.less);
    return order;
}

/// The text written for row `r` of column `ci`.
fn cell(a: *const Analysis, ci: usize, t: *const Table, r: usize) []const u8 {
    const c = &a.columns[ci];
    const p = c.at(t.role).?;
    const raw = t.cols[p.src][r];
    switch (c.kind) {
        .numeric => return if (std.math.isNan(p.num[r])) "" else an.trim(raw),
        .categorical => {
            const id = p.cat[r];
            if (id == an.no_level) return "";
            if (a.target == ci) if (a.target_positive) |pos| return if (id == pos) "1" else "0";
            return c.levels[id];
        },
        .empty => return "",
    }
}

fn writeField(w: *Writer, s: []const u8) Writer.Error!void {
    if (std.mem.findAny(u8, s, ",\"\r\n") == null) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeByte('"');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// Write the cleaned `t` to `w`; returns what changed.
pub fn writeTable(arena: std.mem.Allocator, w: *Writer, a: *const Analysis, t: *const Table) !Changes {
    const cols = try columnOrder(arena, a, t);
    const rows = try rowOrder(arena, a, t);
    const changed = try arena.alloc(usize, cols.len);
    @memset(changed, 0);
    const names = try arena.alloc([]const u8, cols.len);

    for (cols, names, 0..) |ci, *n, j| {
        n.* = an.trim(a.columns[ci].name);
        if (j > 0) try w.writeByte(',');
        try writeField(w, n.*);
    }
    try w.writeByte('\n');
    var reordered = false;
    for (rows, 0..) |r, k| {
        reordered = reordered or r != k;
        for (cols, changed, 0..) |ci, *ch, j| {
            const s = cell(a, ci, t, r);
            const raw = t.cols[a.columns[ci].at(t.role).?.src][r];
            ch.* += @intFromBool(!std.mem.eql(u8, s, raw));
            if (j > 0) try w.writeByte(',');
            try writeField(w, s);
        }
        try w.writeByte('\n');
    }
    return .{
        .role = t.role,
        .path = t.path,
        .rows = rows.len,
        .skipped = t.issues.blank.count + t.issues.ragged.count,
        .reordered = reordered,
        .changed = changed,
        .names = names,
    };
}

pub fn writeChanges(w: *Writer, all: []const Changes) Writer.Error!void {
    try w.writeAll("\nCLEANED\n");
    for (all) |c| {
        try w.print("  {s}: {d} rows written", .{ c.role.label(), c.rows });
        if (c.skipped > 0) try w.print(", {d} malformed records dropped", .{c.skipped});
        if (c.reordered) try w.writeAll(", rows sorted by id");
        var any = false;
        for (c.changed) |n| any = any or n > 0;
        if (!any) {
            try w.writeAll("; no values rewritten\n");
            continue;
        }
        try w.writeAll("; values rewritten:\n");
        for (c.names, c.changed) |n, k| if (k > 0) try w.print("      {s}: {d}\n", .{ n, k });
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn cleaned(arena: std.mem.Allocator, train: []const u8, tst: []const u8) ![2][]const u8 {
    var tables: [2]Table = .{
        try tbl.parse(arena, .train, "train", train),
        try tbl.parse(arena, .@"test", "test", tst),
    };
    const a = try an.analyze(arena, &tables, .{});
    var out: [2][]const u8 = undefined;
    for (&tables, &out) |*t, *o| {
        var buf: Writer.Allocating = .init(arena);
        _ = try writeTable(arena, &buf.writer, &a, t);
        o.* = buf.written();
    }
    return out;
}

test "clean: trim, missing, case fold, bool target, id sort, column order, quoting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = try cleaned(arena,
        "\xEF\xBB\xBFid,x,c,y\r\n" ++
            "2, 7 ,Eco,False\r\n" ++
            "0,NA,eco,True\r\n" ++
            "1,,\"a,b\",True\r\n" ++
            "3,1e3,Eco,False\r\n",
        "c,id,x\n Eco ,5,1\nECO,4,2\n");
    try testing.expectEqualStrings(
        "id,x,c,y\n" ++
            "0,,Eco,1\n" ++
            "1,,\"a,b\",1\n" ++
            "2,7,Eco,0\n" ++
            "3,1e3,Eco,0\n",
        out[0]);
    try testing.expectEqualStrings("id,x,c\n4,2,Eco\n5,1,Eco\n", out[1]);
}

test "clean: a clean file comes back byte-identical" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const train = "id,x,c,y\n0,1.5,a,1\n1,2,\"q\"\"uote\",0\n";
    const out = try cleaned(arena, train, "id,x,c\n2,3,a\n");
    try testing.expectEqualStrings(train, out[0]);
}
