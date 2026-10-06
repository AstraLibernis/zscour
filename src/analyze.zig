// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Every check: per file, per column, per row and across files. Produces an
//! `Analysis` holding typed columns (a value per row, shared level ids across
//! files) and the findings. `report.zig` prints it; `clean.zig` writes from it.

const std = @import("std");
const tbl = @import("table.zig");
const Table = tbl.Table;
const Examples = tbl.Examples;
pub const Role = tbl.Role;

// Milestone passes (docs/PLAN.md). Each has `run(Ctx)`; report sections
// render from the fields they fill in `Analysis`.
const drift = @import("drift.zig");
const target_rate = @import("target_rate.zig");
const signal = @import("signal.zig");
const strings = @import("strings.zig");
const discrete = @import("discrete.zig");
const adversarial = @import("adversarial.zig");
const assoc = @import("assoc.zig");
const stats = @import("stats.zig");
const missingness = @import("missingness.zig");

pub const Severity = enum { err, warn, info };

pub const Code = enum {
    // file
    bom,
    line_endings,
    nul,
    utf8,
    no_final_newline,
    blank_lines,
    ragged,
    parse_error,
    // header and schema
    header_duplicate,
    header_empty,
    header_padded,
    schema,
    column_order,
    // values
    missing,
    mixed_missing,
    marker_level,
    padded,
    junk,
    nonfinite,
    nonint,
    case_variants,
    mixed_type,
    empty_column,
    constant,
    high_cardinality,
    // across files
    unseen_levels,
    out_of_range,
    shift,
    // id and target
    id,
    target,
    // rows
    duplicate_rows,
    conflicting_labels,
    cross_duplicates,
    // submission
    submission,
    // milestone passes (docs/PLAN.md)
    pure_rate, // M1
    informative_missing, // M1
    signal, // M2
    leak, // M2
    spelling_variants, // M3
    punctuation_only, // M3
    discrete_numeric, // M4
    adversarial, // M5
    association, // M6
    skew, // M7
    imbalance, // M7
    order, // M7
    missing_together, // M8
};

pub const Finding = struct {
    sev: Severity,
    code: Code,
    table: ?Role = null,
    column: ?[]const u8 = null,
    msg: []const u8,
};

pub const Kind = enum { numeric, categorical, empty };
pub const Use = enum { id, target, feature };

/// Level id of a missing categorical value.
pub const no_level = std.math.maxInt(u32);

pub const PerTable = struct {
    /// Column index in the table.
    src: usize,
    n: usize,
    /// Empty or whitespace only.
    empty: usize = 0,
    /// NA, NaN, null, … In a numeric column they are missing; in a
    /// categorical column they stay levels (`marker_level`).
    markers: usize = 0,
    /// The first few distinct marker spellings ("NA", "null", …).
    marker_spellings: [4][]const u8 = undefined,
    n_marker_spellings: usize = 0,
    padded: Examples = .{},
    /// Numeric column, field not a number. Treated as missing.
    junk: Examples = .{},
    junk_sample: [3][]const u8 = undefined,
    nonfinite: usize = 0,
    nonint: usize = 0,
    /// Numeric: value per row, NaN = missing. Categorical: empty.
    num: []f64 = &.{},
    /// Categorical: level id per row, `no_level` = missing. Numeric: empty.
    cat: []u32 = &.{},
    /// Numeric: the non-missing values, ascending.
    sorted: []f64 = &.{},
    /// Categorical: rows per level id.
    level_counts: []usize = &.{},

    fn noteMarker(p: *PerTable, s: []const u8) void {
        p.markers += 1;
        for (p.marker_spellings[0..@min(p.n_marker_spellings, p.marker_spellings.len)]) |m| if (std.mem.eql(u8, m, s)) return;
        if (p.n_marker_spellings < p.marker_spellings.len) p.marker_spellings[p.n_marker_spellings] = s;
        p.n_marker_spellings += 1;
    }

    pub fn missingCount(p: *const PerTable, kind: Kind) usize {
        return switch (kind) {
            .numeric => p.n - p.sorted.len,
            .categorical => p.empty,
            .empty => p.n,
        };
    }

    pub fn quantile(p: *const PerTable, q: f64) f64 {
        if (p.sorted.len == 0) return std.math.nan(f64);
        const last: f64 = @floatFromInt(p.sorted.len - 1);
        return p.sorted[@intFromFloat(@round(q * last))];
    }
};

pub const Column = struct {
    name: []const u8,
    use: Use,
    kind: Kind,
    /// Every finite value in every file is a whole number.
    integral: bool = false,
    /// Numeric with few distinct values; set by M4 (`discrete.zig`).
    discrete: bool = false,
    /// Categorical: canonical spelling per level id (the most frequent one).
    levels: []const []const u8 = &.{},
    /// Categorical: every trimmed spelling folded into each level.
    spellings: []const []const []const u8 = &.{},
    per: [4]?PerTable = .{ null, null, null, null },

    pub fn at(c: *const Column, r: Role) ?*const PerTable {
        if (c.per[@intFromEnum(r)]) |*p| return p;
        return null;
    }
};

pub const Options = struct {
    id: []const u8 = "id",
    /// Default: the one train column that test lacks, besides the id.
    target: ?[]const u8 = null,
    /// KS statistic (numeric) or total variation distance (categorical)
    /// between train and test above which a column is flagged as shifted.
    shift_warn: f64 = 0.02,
    /// Row hashes are ANDed with this. Tests set 0 so every row collides and
    /// row equality is decided by comparing values, never by the hash alone.
    row_hash_mask: u64 = std.math.maxInt(u64),
    /// Run M5's train-vs-test classifier (seconds on large files).
    adversarial: bool = true,
    /// What makes two spellings one level (M3).
    fold: strings.Fold = .case,
};

pub const Analysis = struct {
    tables: []const Table,
    columns: []Column,
    id: ?usize = null,
    target: ?usize = null,
    /// Target levels spelled as booleans (true/false, yes/no): level id of
    /// the positive class, so `clean` can write 0/1.
    target_positive: ?u32 = null,
    findings: std.ArrayList(Finding) = .empty,

    // Filled by the milestone passes; empty until each is built.
    target_rates: []const target_rate.Feature = &.{},
    target_mode: target_rate.TargetMode = .none,
    spelling_groups: []const strings.Group = &.{},
    signal: []const signal.Score = &.{},
    signal_task: signal.Task = .binary,
    /// The target's lag-1 dependence in train's file order (M2).
    order: ?signal.Order = null,
    adversarial: []const adversarial.Result = &.{},
    associations: []const assoc.Pair = &.{},
    column_stats: []const stats.Extra = &.{},
    missing_together: []const missingness.Pair = &.{},

    pub fn table(a: *const Analysis, r: Role) ?*const Table {
        for (a.tables) |*t| if (t.role == r) return t;
        return null;
    }

    pub fn count(a: *const Analysis, sev: Severity) usize {
        var n: usize = 0;
        for (a.findings.items) |f| n += @intFromBool(f.sev == sev);
        return n;
    }

    pub fn has(a: *const Analysis, code: Code) bool {
        for (a.findings.items) |f| if (f.code == code) return true;
        return false;
    }
};

/// Missing-value markers (NA, N/A, null, …), matched on base form (M3).
pub const isMarker = strings.isMarker;

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// A column is numeric if at least this share of its non-empty, non-marker
/// fields parse as numbers; the rest are reported as junk.
const numeric_share = 0.99;

/// What every check gets: the arena, the analysis it adds to, the options.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    a: *Analysis,
    opts: Options,

    pub fn add(c: Ctx, sev: Severity, code: Code, t: ?Role, col: ?[]const u8, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(c.arena, fmt, args);
        try c.a.findings.append(c.arena, .{ .sev = sev, .code = code, .table = t, .column = col, .msg = msg });
    }
};

/// All allocations go to `arena`; the result borrows from `tables`.
pub fn analyze(arena: std.mem.Allocator, tables: []const Table, opts: Options) !Analysis {
    var a: Analysis = .{ .tables = tables, .columns = &.{} };
    const cx: Ctx = .{ .arena = arena, .a = &a, .opts = opts };

    for (tables) |*t| try fileFindings(cx, t);
    for (tables) |*t| try headerFindings(cx, t);
    try buildColumns(cx);
    for (a.columns) |*c| try typeColumn(cx, c);
    try schemaFindings(cx);
    for (a.columns) |*c| try columnFindings(cx, c);
    try idFindings(cx);
    try targetFindings(cx);
    try rowFindings(cx);
    try submissionFindings(cx);

    try strings.run(cx);
    try discrete.run(cx);
    try target_rate.run(cx);
    try signal.run(cx);
    if (opts.adversarial) try adversarial.run(cx);
    try assoc.run(cx);
    try stats.run(cx);
    try missingness.run(cx);
    return a;
}

// ------------------------------------------------------------------ files

fn fileFindings(cx: Ctx, t: *const Table) !void {
    const r = t.role;
    const is = &t.issues;
    if (is.parse_error) |pe|
        try cx.add(.err, .parse_error, r, null, "CSV parse error {s} at record {d}; nothing after it was read", .{ @errorName(pe.err), pe.record });
    if (is.ragged.count > 0)
        try cx.add(.err, .ragged, r, null, "{d} records have a field count different from the header's ({d}); skipped. First at records {any}", .{ is.ragged.count, t.names.len, is.ragged.slice() });
    if (is.blank.count > 0)
        try cx.add(.warn, .blank_lines, r, null, "{d} blank lines (skipped), first at records {any}", .{ is.blank.count, is.blank.slice() });
    if (is.nul > 0)
        try cx.add(.err, .nul, r, null, "{d} NUL bytes", .{is.nul});
    if (!is.utf8_valid)
        try cx.add(.warn, .utf8, r, null, "not valid UTF-8 (wrong encoding, or a binary file)", .{});
    if (is.bom)
        try cx.add(.info, .bom, r, null, "UTF-8 byte-order mark at start of file (stripped)", .{});
    const kinds = @as(usize, @intFromBool(is.lf > 0)) + @intFromBool(is.crlf > 0) + @intFromBool(is.cr > 0);
    if (kinds > 1)
        try cx.add(.warn, .line_endings, r, null, "mixed line endings: {d} LF, {d} CRLF, {d} bare CR", .{ is.lf, is.crlf, is.cr })
    else if (is.crlf > 0 or is.cr > 0)
        try cx.add(.info, .line_endings, r, null, "{s} line endings", .{if (is.crlf > 0) "CRLF" else "bare CR"});
    if (!is.final_newline)
        try cx.add(.info, .no_final_newline, r, null, "no newline at end of file", .{});
}

fn headerFindings(cx: Ctx, t: *const Table) !void {
    for (t.names, 0..) |n, i| {
        if (trim(n).len == 0) try cx.add(.err, .header_empty, t.role, null, "column {d} has an empty name", .{i + 1});
        if (trim(n).len != n.len and trim(n).len > 0)
            try cx.add(.warn, .header_padded, t.role, n, "column name has leading/trailing whitespace: \"{s}\"", .{n});
        for (t.names[0..i]) |m| if (std.mem.eql(u8, m, n)) {
            try cx.add(.err, .header_duplicate, t.role, n, "column name appears more than once", .{});
            break;
        };
    }
}

// ---------------------------------------------------------------- columns

/// The union of column names over train, test and extra, train's order first.
/// The submission file is checked separately and contributes no columns.
fn buildColumns(cx: Ctx) !void {
    const a = cx.a;
    var cols: std.ArrayList(Column) = .empty;
    for (a.tables) |*t| {
        if (t.role == .sub) continue;
        next: for (t.names) |n| {
            for (cols.items) |c| if (std.mem.eql(u8, c.name, n)) continue :next;
            try cols.append(cx.arena, .{ .name = n, .use = .feature, .kind = .empty });
        }
    }
    a.columns = cols.items;

    for (a.columns, 0..) |*c, i| if (std.mem.eql(u8, c.name, cx.opts.id)) {
        c.use = .id;
        a.id = i;
    };
    if (cx.opts.target) |name| {
        for (a.columns, 0..) |*c, i| if (std.mem.eql(u8, c.name, name)) {
            c.use = .target;
            a.target = i;
        };
        if (a.target == null) try cx.add(.err, .target, null, name, "target column not found in any file", .{});
    } else if (a.table(.train)) |train| if (a.table(.@"test")) |tst| {
        var found: ?usize = null;
        var n_found: usize = 0;
        for (a.columns, 0..) |c, i| {
            if (c.use == .id or train.column(c.name) == null or tst.column(c.name) != null) continue;
            found = i;
            n_found += 1;
        }
        if (n_found == 1) {
            a.columns[found.?].use = .target;
            a.target = found;
        } else {
            try cx.add(.warn, .target, null, null, "cannot infer the target: {d} train columns are missing from test; pass --target", .{n_found});
        }
    };
}

const FieldClass = enum { empty, marker, number, text };

fn classify(s: []const u8) FieldClass {
    if (s.len == 0) return .empty;
    if (isMarker(s)) return .marker;
    _ = std.fmt.parseFloat(f64, s) catch return .text;
    return .number;
}

fn typeColumn(cx: Ctx, c: *Column) !void {
    // Pass 1: decide the kind from every file at once, so a column cannot be
    // numeric in train and categorical in test.
    var numbers: usize = 0;
    var texts: usize = 0;
    var markers: usize = 0;
    for (cx.a.tables) |*t| {
        if (t.role == .sub) continue;
        const ci = t.column(c.name) orelse continue;
        for (t.cols[ci]) |raw| switch (classify(trim(raw))) {
            .empty => {},
            .marker => markers += 1,
            .number => numbers += 1,
            .text => texts += 1,
        };
    }
    const shown: f64 = @floatFromInt(numbers + texts);
    c.kind = if (numbers + texts + markers == 0)
        .empty
    else if (numbers > 0 and @as(f64, @floatFromInt(numbers)) >= numeric_share * shown)
        .numeric
    else
        .categorical;

    const index: LevelIndex = if (c.kind == .categorical) try buildLevels(cx, c) else .empty;

    c.integral = c.kind == .numeric;
    for (cx.a.tables) |*t| {
        if (t.role == .sub) continue;
        const ci = t.column(c.name) orelse continue;
        var p: PerTable = .{ .src = ci, .n = t.n_rows };
        switch (c.kind) {
            .numeric => try fillNumeric(cx.arena, t, &p),
            .categorical => try fillCategorical(cx.arena, c, &index, cx.opts.fold, t, &p),
            .empty => for (t.cols[ci], 0..) |raw, r| {
                if (trim(raw).len == 0) p.empty += 1 else p.markers += 1;
                if (trim(raw).len != raw.len) p.padded.add(t.records[r]);
            },
        }
        if (p.nonint > 0) c.integral = false;
        c.per[@intFromEnum(t.role)] = p;
    }
    if (numbers > 0 and c.kind == .categorical)
        try cx.add(.warn, .mixed_type, null, c.name, "mixed types: {d} numeric and {d} text values; kept as categorical", .{ numbers, texts });
}

fn fillNumeric(arena: std.mem.Allocator, t: *const Table, p: *PerTable) !void {
    p.num = try arena.alloc(f64, t.n_rows);
    var kept: usize = 0;
    for (t.cols[p.src], p.num, 0..) |raw, *v, r| {
        const s = trim(raw);
        if (s.len != raw.len) p.padded.add(t.records[r]);
        v.* = std.math.nan(f64);
        switch (classify(s)) {
            .empty => p.empty += 1,
            .marker => p.noteMarker(s),
            .text => {
                if (p.junk.count < p.junk_sample.len) p.junk_sample[p.junk.count] = s;
                p.junk.add(t.records[r]);
            },
            .number => {
                const x = std.fmt.parseFloat(f64, s) catch unreachable; // zsnag:ok classify parsed it
                if (!std.math.isFinite(x)) {
                    p.nonfinite += 1;
                } else {
                    v.* = if (x == 0) 0 else x; // -0 and 0 are one value
                    if (@floor(x) != x) p.nonint += 1;
                    kept += 1;
                }
            },
        }
    }
    p.sorted = try arena.alloc(f64, kept);
    var k: usize = 0;
    for (p.num) |v| if (!std.math.isNan(v)) {
        p.sorted[k] = v;
        k += 1;
    };
    std.mem.sort(f64, p.sorted, {}, std.sort.asc(f64));
}


/// Level ids for a categorical column, shared across files. Spellings that
/// differ only in case are one level, written with the most frequent spelling.
fn buildLevels(cx: Ctx, c: *Column) !LevelIndex {
    const arena = cx.arena;
    var counts: std.array_hash_map.String(usize) = .empty;
    for (cx.a.tables) |*t| {
        if (t.role == .sub) continue;
        const ci = t.column(c.name) orelse continue;
        for (t.cols[ci]) |raw| {
            const s = trim(raw);
            if (s.len == 0) continue;
            const gop = try counts.getOrPut(arena, s);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }
    var by_fold: LevelIndex = .empty;
    var buf: [256]u8 = undefined;
    for (counts.keys()) |s| {
        const key = try arena.dupe(u8, try strings.key(arena, &buf, s, cx.opts.fold));
        const gop = try by_fold.getOrPut(arena, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, s);
    }
    const levels = try arena.alloc([]const u8, by_fold.count());
    const spellings = try arena.alloc([]const []const u8, by_fold.count());
    for (by_fold.values(), levels, spellings) |list, *l, *sp| {
        var best = list.items[0];
        for (list.items[1..]) |s| {
            const cs = counts.get(s).?;
            const cb = counts.get(best).?;
            if (cs > cb or (cs == cb and std.mem.order(u8, s, best) == .lt)) best = s;
        }
        l.* = best;
        sp.* = list.items;
    }
    c.levels = levels;
    c.spellings = spellings;
    return by_fold;
}

/// Folded spelling → its spellings; the entry's index is the level id.
const LevelIndex = std.array_hash_map.String(std.ArrayList([]const u8));

fn fillCategorical(arena: std.mem.Allocator, c: *const Column, index: *const LevelIndex, fold_mode: strings.Fold, t: *const Table, p: *PerTable) !void {
    p.cat = try arena.alloc(u32, t.n_rows);
    p.level_counts = try arena.alloc(usize, c.levels.len);
    @memset(p.level_counts, 0);
    var buf: [256]u8 = undefined;
    for (t.cols[p.src], p.cat, 0..) |raw, *v, r| {
        const s = trim(raw);
        if (s.len != raw.len) p.padded.add(t.records[r]);
        if (s.len == 0) {
            p.empty += 1;
            v.* = no_level;
            continue;
        }
        if (isMarker(s)) p.noteMarker(s);
        const idx = index.getIndex(try strings.key(arena, &buf, s, fold_mode)) orelse unreachable; // zsnag:ok every spelling was indexed
        v.* = @intCast(idx);
        p.level_counts[idx] += 1;
    }
}

// ----------------------------------------------------------------- schema

fn schemaFindings(cx: Ctx) !void {
    const a = cx.a;
    const train = a.table(.train) orelse return;
    const target_name = if (a.target) |ti| a.columns[ti].name else null;
    for ([_]Role{ .@"test", .extra }) |role| {
        const t = a.table(role) orelse continue;
        for (train.names) |n| {
            if (target_name != null and std.mem.eql(u8, n, target_name.?)) continue;
            if (t.column(n) == null) {
                const id_ok = role == .extra and std.mem.eql(u8, n, cx.opts.id);
                if (!id_ok) try cx.add(if (role == .@"test") .err else .warn, .schema, role, n, "column in train but not here", .{});
            }
        }
        for (t.names) |n| if (train.column(n) == null)
            try cx.add(if (role == .@"test") .err else .warn, .schema, role, n, "column here but not in train", .{});
        if (role == .extra) if (target_name) |tn| if (t.column(tn) == null)
            try cx.add(.warn, .schema, role, tn, "extra data has no target column", .{});
        // Order: compare the shared columns' relative order.
        var last: usize = 0;
        for (t.names) |n| {
            const i = train.column(n) orelse continue;
            if (i < last) {
                try cx.add(.info, .column_order, role, null, "columns are in a different order from train (clean writes train's order)", .{});
                break;
            }
            last = i;
        }
    }
}

// ----------------------------------------------------------- column checks

const missing_warn_pct = 5.0;

fn pct(part: usize, whole: usize) f64 {
    if (whole == 0) return 0;
    return 100.0 * @as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole));
}

fn columnFindings(cx: Ctx, c: *const Column) !void {
    const name = c.name;
    if (c.kind == .empty) {
        try cx.add(.warn, .empty_column, null, name, "every value is missing in every file", .{});
        return;
    }
    var nonint_total: usize = 0;
    var values_total: usize = 0;
    for (c.per, 0..) |maybe, ri| {
        const p = maybe orelse continue;
        const role: Role = @enumFromInt(ri);
        const miss = p.missingCount(c.kind);
        if (miss > 0) {
            // A feature's missing values are a note up to 5% of a file and a
            // warning past it (deepchecks' percent_of_nulls default; ydata
            // alerts from 1%). A missing id or train target is an error.
            const heavy = pct(miss, p.n) > missing_warn_pct;
            const sev: Severity = if (c.use == .feature or role == .@"test") (if (heavy) .warn else .info) else .err;
            try cx.add(sev, .missing, role, name, "{d} missing ({d:.2}%): {d} empty, {d} markers, {d} junk, {d} non-finite", .{ miss, pct(miss, p.n), p.empty, if (c.kind == .numeric) p.markers else 0, p.junk.count, p.nonfinite });
        }
        // Two or more spellings of "missing" in one column: empty plus a
        // marker, or two markers (deepchecks' mixed_nulls).
        if (c.kind == .numeric and p.n_marker_spellings + @intFromBool(p.empty > 0) > 1) {
            var list: std.ArrayList(u8) = .empty;
            if (p.empty > 0) try list.print(cx.arena, "{d} empty", .{p.empty});
            for (p.marker_spellings[0..@min(p.n_marker_spellings, p.marker_spellings.len)], 0..) |m, i|
                try list.print(cx.arena, "{s}\"{s}\"", .{ if (i > 0 or p.empty > 0) ", " else "", m });
            if (p.n_marker_spellings > p.marker_spellings.len) try list.print(cx.arena, ", … {d} more", .{p.n_marker_spellings - p.marker_spellings.len});
            try cx.add(.warn, .mixed_missing, role, name, "missing values are spelled {d} ways — {s} — in {d} rows (clean writes all as empty)", .{ p.n_marker_spellings + @intFromBool(p.empty > 0), list.items, p.empty + p.markers });
        }
        if (c.kind == .categorical and p.markers > 0)
            try cx.add(.warn, .marker_level, role, name, "{d} values look like missing markers (NA, null, …) but are kept as a level: in a text column they may be real categories", .{p.markers});
        if (p.padded.count > 0)
            try cx.add(.warn, .padded, role, name, "{d} values have leading/trailing whitespace (clean trims), first at records {any}", .{ p.padded.count, p.padded.slice() });
        if (p.junk.count > 0)
            try cx.add(.warn, .junk, role, name, "{d} non-numeric values in a numeric column, e.g. {any}; treated as missing (records {any})", .{ p.junk.count, fmtSamples(&p), p.junk.slice() });
        if (p.nonfinite > 0)
            try cx.add(.warn, .nonfinite, role, name, "{d} infinite values; treated as missing", .{p.nonfinite});
        nonint_total += p.nonint;
        values_total += p.sorted.len;
    }
    // A handful of fractions in an otherwise whole-number column is a
    // generator artefact or a typo, not a real fractional feature.
    if (c.kind == .numeric and nonint_total > 0 and @as(f64, @floatFromInt(nonint_total)) <= 0.01 * @as(f64, @floatFromInt(values_total)))
        try cx.add(.warn, .nonint, null, name, "mostly whole numbers, but {d} values have a fractional part", .{nonint_total});

    if (c.kind == .categorical) for (c.spellings, c.levels) |sp, lvl| if (sp.len > 1)
        try cx.add(.warn, .case_variants, null, name, "\"{s}\" is spelled {d} ways ({f}); they are one level, and clean writes \"{s}\"", .{ lvl, sp.len, fmtList(sp), lvl });

    if (c.use != .feature) return;
    const train = c.at(.train) orelse return;
    const distinct = switch (c.kind) {
        .numeric => distinctSorted(train.sorted),
        .categorical => nonzero(train.level_counts),
        .empty => 0,
    };
    if (distinct <= 1 and train.n > 0)
        try cx.add(.warn, .constant, .train, name, "constant in train ({d} distinct value): carries no signal", .{distinct});
    if (c.kind == .categorical and distinct > 1000 and distinct * 20 > train.n)
        try cx.add(.info, .high_cardinality, .train, name, "{d} distinct levels: free text or an id?", .{distinct});

    for ([_]Role{ .@"test", .extra }) |role| {
        const other = c.at(role) orelse continue;
        try compareToTrain(cx, c, train, other, role);
    }
}

fn compareToTrain(cx: Ctx, c: *const Column, train: *const PerTable, other: *const PerTable, role: Role) !void {
    const sev_shift: Severity = if (role == .@"test") .warn else .info;
    switch (c.kind) {
        .numeric => {
            if (train.sorted.len == 0 or other.sorted.len == 0) return;
            const lo = train.sorted[0];
            const hi = train.sorted[train.sorted.len - 1];
            var below: usize = 0;
            var above: usize = 0;
            for (other.sorted) |x| {
                below += @intFromBool(x < lo);
                above += @intFromBool(x > hi);
            }
            if (below + above > 0)
                try cx.add(.info, .out_of_range, role, c.name, "{d} values outside train's range [{d}, {d}] ({d} below, {d} above)", .{ below + above, lo, hi, below, above });
            const d = drift.ks(train.sorted, other.sorted);
            if (d > cx.opts.shift_warn)
                try cx.add(sev_shift, .shift, role, c.name, "distribution differs from train: KS = {d:.4}", .{d});
        },
        .categorical => {
            var unseen: std.ArrayList(u8) = .empty;
            var n_unseen: usize = 0;
            var rows_unseen: usize = 0;
            for (other.level_counts, train.level_counts, c.levels) |k, kt, lvl| if (k > 0 and kt == 0) {
                n_unseen += 1;
                rows_unseen += k;
                if (n_unseen <= 5) try unseen.print(cx.arena, "{s}\"{f}\" ×{d}", .{ if (n_unseen > 1) ", " else "", strings.visible(lvl), k });
            };
            if (n_unseen > 0)
                try cx.add(if (role == .@"test") .warn else .info, .unseen_levels, role, c.name, "{d} levels never seen in train, {d} rows: {s}", .{ n_unseen, rows_unseen, unseen.items });
            const d = drift.tvd(train.level_counts, other.level_counts);
            if (d > cx.opts.shift_warn)
                try cx.add(sev_shift, .shift, role, c.name, "level mix differs from train: total variation = {d:.4}", .{d});
        },
        .empty => {},
    }
}

fn distinctSorted(xs: []const f64) usize {
    if (xs.len == 0) return 0;
    var n: usize = 1;
    for (xs[1..], xs[0 .. xs.len - 1]) |x, prev| n += @intFromBool(x != prev);
    return n;
}

fn nonzero(xs: []const usize) usize {
    var n: usize = 0;
    for (xs) |x| n += @intFromBool(x > 0);
    return n;
}

fn fmtSamples(p: *const PerTable) []const []const u8 {
    return p.junk_sample[0..@min(p.junk.count, p.junk_sample.len)];
}

const ListFmt = struct {
    items: []const []const u8,
    pub fn format(l: ListFmt, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (l.items, 0..) |s, i| try w.print("{s}\"{f}\"", .{ if (i > 0) ", " else "", strings.visible(s) });
    }
};

fn fmtList(items: []const []const u8) ListFmt {
    return .{ .items = items };
}

// --------------------------------------------------------------------- id

fn idFindings(cx: Ctx) !void {
    const a = cx.a;
    const ci = a.id orelse {
        try cx.add(.info, .id, null, cx.opts.id, "no id column; pass --id if it has another name", .{});
        return;
    };
    const c = &a.columns[ci];
    if (c.kind != .numeric or !c.integral) {
        try cx.add(.warn, .id, null, c.name, "id is not an integer column; uniqueness checked, sorting skipped", .{});
    }
    for (c.per, 0..) |maybe, ri| {
        const p = maybe orelse continue;
        const role: Role = @enumFromInt(ri);
        if (c.kind != .numeric) continue;
        const miss = p.n - p.sorted.len;
        if (miss > 0) try cx.add(.err, .id, role, c.name, "{d} rows have no id", .{miss});
        const dups = p.sorted.len - distinctSorted(p.sorted);
        if (dups > 0) try cx.add(.err, .id, role, c.name, "{d} duplicate ids", .{dups});
        var unsorted = false;
        for (p.num[1..], p.num[0 .. p.num.len - @min(p.num.len, 1)]) |x, prev| if (x < prev) {
            unsorted = true;
            break;
        };
        if (unsorted) try cx.add(.info, .id, role, c.name, "rows are not in id order (clean sorts them)", .{});
        if (p.sorted.len > 1 and dups == 0 and c.integral) {
            const span = p.sorted[p.sorted.len - 1] - p.sorted[0] + 1;
            if (span != @as(f64, @floatFromInt(p.sorted.len)))
                try cx.add(.info, .id, role, c.name, "ids are not contiguous: {d} ids span {d}..{d}", .{ p.sorted.len, p.sorted[0], p.sorted[p.sorted.len - 1] });
        }
    }
    const train = c.at(.train) orelse return;
    const tst = c.at(.@"test") orelse return;
    if (c.kind == .numeric) {
        const shared = sharedSorted(train.sorted, tst.sorted);
        if (shared > 0) try cx.add(.err, .id, .@"test", c.name, "{d} test ids also appear in train", .{shared});
    }
}

fn sharedSorted(a: []const f64, b: []const f64) usize {
    var i: usize = 0;
    var j: usize = 0;
    var n: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i] < b[j]) {
            i += 1;
        } else if (a[i] > b[j]) {
            j += 1;
        } else {
            n += 1;
            i += 1;
            j += 1;
        }
    }
    return n;
}

// ----------------------------------------------------------------- target

const positive_words = [_][]const u8{ "true", "yes", "y", "t" };
const negative_words = [_][]const u8{ "false", "no", "n", "f" };

fn wordIn(s: []const u8, words: []const []const u8) bool {
    for (words) |w| if (std.ascii.eqlIgnoreCase(s, w)) return true;
    return false;
}

fn targetFindings(cx: Ctx) !void {
    const a = cx.a;
    const ti = a.target orelse return;
    const c = &a.columns[ti];
    const train = c.at(.train) orelse {
        try cx.add(.err, .target, .train, c.name, "train has no target column", .{});
        return;
    };
    if (c.kind == .categorical) {
        var out: std.ArrayList(u8) = .empty;
        const total = train.n - train.empty;
        for (c.levels, train.level_counts, 0..) |lvl, k, i| {
            if (i == 8) {
                try out.print(cx.arena, ", …", .{});
                break;
            }
            try out.print(cx.arena, "{s}{s} {d:.2}%", .{ if (i > 0) " · " else "", lvl, pct(k, total) });
        }
        try cx.add(.info, .target, .train, c.name, "{d} classes: {s}", .{ c.levels.len, out.items });
        if (c.levels.len == 2) {
            const p0 = wordIn(c.levels[0], &positive_words) and wordIn(c.levels[1], &negative_words);
            const p1 = wordIn(c.levels[1], &positive_words) and wordIn(c.levels[0], &negative_words);
            if (p0 or p1) {
                a.target_positive = if (p0) 0 else 1;
                try cx.add(.info, .target, null, c.name, "boolean target \"{s}\"/\"{s}\": clean writes 1/0; submit probabilities of \"{s}\"", .{ c.levels[a.target_positive.?], c.levels[1 - a.target_positive.?], c.levels[a.target_positive.?] });
            }
        }
    } else if (c.kind == .numeric) {
        const distinct = distinctSorted(train.sorted);
        if (distinct == 2) {
            var ones: usize = 0;
            for (train.sorted) |x| ones += @intFromBool(x == train.sorted[train.sorted.len - 1]);
            try cx.add(.info, .target, .train, c.name, "binary: {d} {d:.2}% · {d} {d:.2}%", .{ train.sorted[0], pct(train.sorted.len - ones, train.sorted.len), train.sorted[train.sorted.len - 1], pct(ones, train.sorted.len) });
        } else {
            try cx.add(.info, .target, .train, c.name, "numeric, {d} distinct: min {d} · p50 {d} · max {d}", .{ distinct, train.quantile(0), train.quantile(0.5), train.quantile(1) });
        }
    }
    if (c.at(.extra)) |ex| if (c.kind == .categorical) {
        for (ex.level_counts, train.level_counts, c.levels) |k, kt, lvl| if (k > 0 and kt == 0)
            try cx.add(.warn, .target, .extra, c.name, "target level \"{s}\" ({d} rows) never occurs in train", .{ lvl, k });
    };
}

// ------------------------------------------------------------------- rows

/// Rows compare on their features: every column but id and target, by typed
/// value, so "4" and "4.0", or "Eco" and "eco", are the same.
const RowKey = struct {
    a: *const Analysis,
    features: []const usize,
    mask: u64,

    fn hash(k: RowKey, role: Role, r: usize) ?u64 {
        var h = std.hash.Wyhash.init(0);
        for (k.features) |ci| {
            const p = k.a.columns[ci].at(role) orelse return null;
            switch (k.a.columns[ci].kind) {
                .numeric => {
                    const bits: u64 = if (std.math.isNan(p.num[r])) 0x7ff8_0000_0000_0000 else @bitCast(p.num[r]);
                    h.update(std.mem.asBytes(&bits));
                },
                .categorical => h.update(std.mem.asBytes(&p.cat[r])),
                .empty => {},
            }
        }
        return h.final() & k.mask;
    }

    fn eql(k: RowKey, ra: Role, a_row: usize, rb: Role, b_row: usize) bool {
        for (k.features) |ci| {
            const c = &k.a.columns[ci];
            const pa = c.at(ra).?;
            const pb = c.at(rb).?;
            switch (c.kind) {
                .numeric => {
                    const x = pa.num[a_row];
                    const y = pb.num[b_row];
                    if (!(x == y or (std.math.isNan(x) and std.math.isNan(y)))) return false;
                },
                .categorical => if (pa.cat[a_row] != pb.cat[b_row]) return false,
                .empty => {},
            }
        }
        return true;
    }

    fn target(k: RowKey, role: Role, r: usize) ?u64 {
        const ti = k.a.target orelse return null;
        const p = k.a.columns[ti].at(role) orelse return null;
        return switch (k.a.columns[ti].kind) {
            .numeric => @bitCast(p.num[r]),
            .categorical => p.cat[r],
            .empty => null,
        };
    }
};

/// Open-addressed on the 64-bit hash; a hash collision between unequal rows
/// probes the next key instead of merging them.
const RowIndex = struct {
    map: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn find(ix: *const RowIndex, key: RowKey, role_ix: Role, role: Role, r: usize) ?u32 {
        var h = key.hash(role, r) orelse return null;
        while (ix.map.get(h)) |first| : (h +%= 1) {
            if (key.eql(role_ix, first, role, r)) return first;
        }
        return null;
    }

    /// Returns the earlier equal row, or null after inserting `r`.
    fn insert(ix: *RowIndex, arena: std.mem.Allocator, key: RowKey, role: Role, r: usize) !?u32 {
        var h = key.hash(role, r) orelse return null;
        while (true) : (h +%= 1) {
            const gop = try ix.map.getOrPut(arena, h);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(r);
                return null;
            }
            if (key.eql(role, gop.value_ptr.*, role, r)) return gop.value_ptr.*;
        }
    }
};

fn rowFindings(cx: Ctx) !void {
    const a = cx.a;
    var features: std.ArrayList(usize) = .empty;
    for (a.columns, 0..) |c, i| if (c.use == .feature) try features.append(cx.arena, i);
    if (features.items.len == 0) return;

    var indexes: [4]?RowIndex = .{ null, null, null, null };
    for (a.tables) |*t| {
        if (t.role == .sub) continue;
        // Only files holding every feature can be compared row by row.
        var complete = true;
        for (features.items) |ci| complete = complete and a.columns[ci].at(t.role) != null;
        if (!complete) {
            try cx.add(.info, .duplicate_rows, t.role, null, "not every feature column is present; row comparisons skipped", .{});
            continue;
        }
        const key: RowKey = .{ .a = a, .features = features.items, .mask = cx.opts.row_hash_mask };
        var ix: RowIndex = .{};
        try ix.map.ensureTotalCapacity(cx.arena, @intCast(t.n_rows));
        var dups: usize = 0;
        var exact: usize = 0;
        var conflicts: Examples = .{};
        for (0..t.n_rows) |r| {
            const first = try ix.insert(cx.arena, key, t.role, r) orelse continue;
            dups += 1;
            const ta = key.target(t.role, first);
            const tb = key.target(t.role, r);
            if (ta != null and tb != null and ta.? != tb.?) conflicts.add(t.records[r]) else exact += 1;
        }
        if (dups == 0)
            try cx.add(.info, .duplicate_rows, t.role, null, "no two rows share all feature values", .{});
        if (dups > 0)
            try cx.add(.warn, .duplicate_rows, t.role, null, "{d} rows repeat an earlier row's features ({d} also with the same target)", .{ dups, exact });
        if (conflicts.count > 0)
            try cx.add(.warn, .conflicting_labels, t.role, null, "{d} rows repeat an earlier row's features with a different target (records {any}): irreducible error", .{ conflicts.count, conflicts.slice() });
        indexes[@intFromEnum(t.role)] = ix;
    }

    const key: RowKey = .{ .a = a, .features = features.items, .mask = cx.opts.row_hash_mask };
    const pairs = [_][2]Role{ .{ .train, .@"test" }, .{ .extra, .train }, .{ .extra, .@"test" } };
    for (pairs) |pair| {
        const ix = indexes[@intFromEnum(pair[0])] orelse continue;
        const t = a.table(pair[1]) orelse continue;
        if (indexes[@intFromEnum(pair[1])] == null) continue;
        var hits: usize = 0;
        for (0..t.n_rows) |r| hits += @intFromBool(ix.find(key, pair[0], pair[1], r) != null);
        if (hits > 0)
            try cx.add(.info, .cross_duplicates, pair[1], null, "{d} rows ({d:.2}%) have exactly the features of a row in {s}", .{ hits, pct(hits, t.n_rows), pair[0].label() });
    }
}

// ------------------------------------------------------------- submission

fn submissionFindings(cx: Ctx) !void {
    const a = cx.a;
    const sub = a.table(.sub) orelse return;
    const want_target = if (a.target) |ti| a.columns[ti].name else null;
    if (sub.names.len != 2 or !std.mem.eql(u8, sub.names[0], cx.opts.id) or
        (want_target != null and !std.mem.eql(u8, sub.names[1], want_target.?)))
        try cx.add(.err, .submission, .sub, null, "header is {any}, expected [\"{s}\", \"{s}\"]", .{ sub.names, cx.opts.id, want_target orelse "<target>" });
    const tst = a.table(.@"test") orelse return;
    if (sub.n_rows != tst.n_rows) {
        try cx.add(.err, .submission, .sub, null, "{d} rows, test has {d}", .{ sub.n_rows, tst.n_rows });
        return;
    }
    const sid = sub.column(cx.opts.id) orelse return;
    const tid = tst.column(cx.opts.id) orelse return;
    var mismatched: usize = 0;
    var first: ?usize = null;
    for (sub.cols[sid], tst.cols[tid], 0..) |s, t, r| if (!std.mem.eql(u8, trim(s), trim(t))) {
        mismatched += 1;
        if (first == null) first = r;
    };
    if (mismatched > 0)
        try cx.add(.err, .submission, .sub, null, "{d} rows' ids differ from test's in the same position (first at record {d})", .{ mismatched, sub.records[first.?] })
    else
        try cx.add(.info, .submission, .sub, null, "ids match test row for row ({d} rows)", .{sub.n_rows});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tables: std.ArrayList(Table) = .empty,

    fn init() Fixture {
        return .{ .arena = .init(testing.allocator) };
    }
    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }
    fn add(f: *Fixture, role: Role, csv: []const u8) !void {
        const al = f.arena.allocator();
        try f.tables.append(al, try tbl.parse(al, role, @tagName(role), csv));
    }
    fn run(f: *Fixture) !Analysis {
        return analyze(f.arena.allocator(), f.tables.items, .{});
    }
};

fn findingCount(a: *const Analysis, code: Code) usize {
    var n: usize = 0;
    for (a.findings.items) |f| n += @intFromBool(f.code == code);
    return n;
}

test "clean pair: target inferred, nothing above info" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x,c,y\n0,1.5,a,True\n1,2.5,b,False\n2,3.5,a,True\n");
    try f.add(.@"test", "id,x,c\n3,2.0,b\n4,3.0,a\n");
    try f.add(.sub, "id,y\n3,0.5\n4,0.5\n");
    // Three rows cannot match two on distribution; shift has its own test.
    const a = try analyze(f.arena.allocator(), f.tables.items, .{ .shift_warn = 1 });
    try testing.expectEqualStrings("y", a.columns[a.target.?].name);
    try testing.expectEqual(@as(usize, 0), a.count(.err));
    try testing.expectEqual(@as(usize, 0), a.count(.warn));
    try testing.expectEqual(@as(?u32, 0), a.target_positive);
}

test "numeric column: markers, junk, padding, non-finite" {
    var f = Fixture.init();
    defer f.deinit();
    var csv: std.ArrayList(u8) = .empty;
    const al = f.arena.allocator();
    try csv.appendSlice(al, "id,x\n");
    for (0..200) |i| try csv.print(al, "{d},{d}\n", .{ i, i % 7 });
    try csv.appendSlice(al, "200,NA\n201,\n202, 3\n203,abc\n204,inf\n");
    try f.add(.train, csv.items);
    const a = try f.run();
    const x = a.columns[1];
    try testing.expectEqual(Kind.numeric, x.kind);
    const p = x.at(.train).?;
    try testing.expectEqual(@as(usize, 1), p.markers);
    try testing.expectEqual(@as(usize, 1), p.empty);
    try testing.expectEqual(@as(usize, 1), p.junk.count);
    try testing.expectEqual(@as(usize, 1), p.nonfinite);
    try testing.expectEqual(@as(usize, 1), p.padded.count);
    try testing.expectEqual(@as(f64, 3), p.num[202]);
    try testing.expect(std.math.isNan(p.num[203]));
    try testing.expect(a.has(.mixed_missing) and a.has(.junk) and a.has(.nonfinite) and a.has(.padded));
}

test "too many text values make a column categorical, reported as mixed" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x\n0,1\n1,2\n2,three\n");
    const a = try f.run();
    try testing.expectEqual(Kind.categorical, a.columns[1].kind);
    try testing.expect(a.has(.mixed_type));
}

test "case variants fold into one level spelled the most common way" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,c\n0,Eco\n1,Eco\n2,eco\n3,Business\n");
    try f.add(.@"test", "id,c\n4,ECO\n5,Business\n");
    const a = try f.run();
    const c = a.columns[1];
    try testing.expectEqual(@as(usize, 2), c.levels.len);
    try testing.expectEqualStrings("Eco", c.levels[0]);
    try testing.expectEqual(c.at(.train).?.cat[0], c.at(.@"test").?.cat[0]);
    try testing.expectEqual(@as(usize, 1), findingCount(&a, .case_variants));
}

test "unseen test level and level-mix shift" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,c,y\n0,a,1\n1,a,0\n2,b,1\n");
    try f.add(.@"test", "id,c\n3,z\n4,b\n");
    const a = try f.run();
    try testing.expect(a.has(.unseen_levels) and a.has(.shift));
}

test "duplicate rows, conflicting labels, train/test copies" {
    // Mask 0: every row hashes alike, so only value comparison can tell
    // rows apart. Full hash: the normal path. Both must agree.
    for ([_]u64{ std.math.maxInt(u64), 0 }) |mask| {
        var f = Fixture.init();
        defer f.deinit();
        try f.add(.train, "id,x,c,y\n0,1,a,1\n1,1.0,A,1\n2,1,a,0\n3,2,b,0\n");
        try f.add(.@"test", "id,x,c\n4,2,b\n5,9,z\n");
        const a = try analyze(f.arena.allocator(), f.tables.items, .{ .row_hash_mask = mask });
        var dup_msg: ?[]const u8 = null;
        var conflict_msg: ?[]const u8 = null;
        for (a.findings.items) |fd| {
            if (fd.code == .duplicate_rows and fd.table == .train) dup_msg = fd.msg;
            if (fd.code == .conflicting_labels) conflict_msg = fd.msg;
        }
        try testing.expectEqualStrings("2 rows repeat an earlier row's features (1 also with the same target)", dup_msg.?);
        // Row 2 (record 4) conflicts with row 0; row 1 (record 3) agrees.
        try testing.expect(std.mem.find(u8, conflict_msg.?, "(records { 4 })") != null);
        try testing.expectEqual(@as(usize, 1), findingCount(&a, .cross_duplicates));
    }
}

test "id problems: duplicates, train/test overlap, unsorted" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x,y\n2,1,0\n1,2,1\n1,3,0\n");
    try f.add(.@"test", "id,x\n2,5\n");
    const a = try f.run();
    var errs: usize = 0;
    var unsorted = false;
    for (a.findings.items) |fd| if (fd.code == .id) {
        errs += @intFromBool(fd.sev == .err);
        unsorted = unsorted or std.mem.find(u8, fd.msg, "not in id order") != null;
    };
    try testing.expectEqual(@as(usize, 2), errs);
    try testing.expect(unsorted);
}

test "submission must match test ids in order" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x,y\n0,1,0\n1,2,1\n");
    try f.add(.@"test", "id,x\n2,5\n3,6\n");
    try f.add(.sub, "id,y\n3,0.5\n2,0.5\n");
    const a = try f.run();
    try testing.expectEqual(@as(usize, 1), a.count(.err));
    try testing.expect(a.has(.submission));
}

test "schema: test missing a feature is an error" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x,z,y\n0,1,1,0\n");
    try f.add(.@"test", "id,x\n1,2\n");
    var a = try analyze(f.arena.allocator(), f.tables.items, .{ .target = "y" });
    _ = &a;
    try testing.expect(a.has(.schema));
    try testing.expect(a.count(.err) >= 1);
}


test "-0 and 0 are one value for duplicate detection" {
    var f = Fixture.init();
    defer f.deinit();
    try f.add(.train, "id,x,y\n0,-0,1\n1,0,1\n2,-0.0,1\n");
    const a = try f.run();
    var msg: ?[]const u8 = null;
    for (a.findings.items) |fd| if (fd.code == .duplicate_rows) {
        msg = fd.msg;
    };
    try testing.expect(std.mem.startsWith(u8, msg.?, "2 rows repeat"));
}
