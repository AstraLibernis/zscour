// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M3 — spelling variants beyond case, punctuation-only values, missing
//! markers matched on base form (docs/PLAN.md).
//!
//! The base-form rule is deepchecks' `string_baseform` (`utils/strings.py`,
//! re-read at 98475d1; ideas only, AGPL): drop every non-alphanumeric
//! character, lowercase; if nothing is left, keep the value. Its checks
//! `string_mismatch`, `string_mismatch_comparison`, `special_chars` (warn
//! above 0.1% of rows) and `mixed_nulls` ({none, null, nan, na, ""} on base
//! form) are the models for the findings here. Differences, and why:
//! - Base-form groups are **reported, not merged** by default: dropping
//!   punctuation joins values that differ ("A-1"/"A1", "C++"/"C"). `clean`
//!   folds case only unless `--fold spelling` is given.
//! - Values that parse as numbers never join a base-form group: "-5"/"5"
//!   and "1.5"/"15" share a base form and are different values.
//! - Unicode: zscour has no Unicode alphanumeric table. Non-ASCII code points
//!   count as letters, except the common punctuation and space blocks below;
//!   case folding is ASCII only. A known gap (M10).

const std = @import("std");
const an = @import("analyze.zig");
const Role = an.Role;

/// How values become one level.
pub const Fold = enum {
    /// "Eco" = "eco" = "ECO". Safe; the default.
    case,
    /// Also "New-York" = "new york" = "NEW YORK!". Opt-in.
    spelling,
};

/// Non-ASCII code points treated as punctuation or space: Latin-1
/// punctuation and NBSP, × and ÷, General Punctuation (dashes, curly quotes,
/// zero-width and odd spaces), CJK punctuation, the small-form and fullwidth
/// ASCII-punctuation blocks.
fn isUnicodePunct(cp: u21) bool {
    return (cp >= 0x00A0 and cp <= 0x00BF) or cp == 0x00D7 or cp == 0x00F7 or
        (cp >= 0x2000 and cp <= 0x206F) or (cp >= 0x3000 and cp <= 0x303F) or
        (cp >= 0xFE10 and cp <= 0xFE6F) or (cp >= 0xFF00 and cp <= 0xFF0F) or
        (cp >= 0xFF1A and cp <= 0xFF20) or (cp >= 0xFF3B and cp <= 0xFF40) or
        (cp >= 0xFF5B and cp <= 0xFF65) or cp == 0xFEFF;
}

/// Alphanumerics of `s`, ASCII lowercased, into `out` (at least `s.len`
/// bytes). Empty when `s` has none. Invalid UTF-8 bytes are kept.
pub fn baseFormRaw(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            if (std.ascii.isAlphanumeric(b)) {
                out[n] = std.ascii.toLower(b);
                n += 1;
            }
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            @memcpy(out[n..][0 .. s.len - i], s[i..]);
            n += s.len - i;
            break;
        }
        const decoded = switch (len) {
            2 => std.unicode.utf8Decode2(s[i..][0..2].*),
            3 => std.unicode.utf8Decode3(s[i..][0..3].*),
            4 => std.unicode.utf8Decode4(s[i..][0..4].*),
            else => error.Utf8ExpectedContinuation, // len 1 is ASCII, handled above
        };
        const cp = decoded catch {
            out[n] = b;
            n += 1;
            i += 1;
            continue;
        };
        if (!isUnicodePunct(cp)) {
            @memcpy(out[n..][0..len], s[i..][0..len]);
            n += len;
        }
        i += len;
    }
    return out[0..n];
}

/// deepchecks' base form: alphanumerics lowercased, or `s` itself when it
/// has none.
pub fn baseForm(out: []u8, s: []const u8) []const u8 {
    const b = baseFormRaw(out, s);
    return if (b.len == 0) s else b;
}

/// Punctuation and spaces only: "?", "-", "***", "…".
pub fn isPunctuationOnly(s: []const u8) bool {
    if (s.len == 0) return false;
    var buf: [64]u8 = undefined;
    if (s.len > buf.len) {
        // Long values: scan without copying.
        var i: usize = 0;
        while (i < s.len) : (i += 1) if (s[i] < 0x80 and std.ascii.isAlphanumeric(s[i])) return false;
        var tmp: [4]u8 = undefined;
        i = 0;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return false;
            if (len == 1 or i + len > s.len) {
                i += 1;
                continue;
            }
            if (baseFormRaw(&tmp, s[i..][0..len]).len > 0) return false;
            i += len;
        }
        return true;
    }
    return baseFormRaw(&buf, s).len == 0;
}

fn looksNumeric(s: []const u8) bool {
    _ = std.fmt.parseFloat(f64, s) catch return false;
    return true;
}

/// The key two values share when they are one level: lowercase (`case`), or
/// the base form (`spelling`) for values that are not numbers. Written into
/// `buf`, or the arena when `s` does not fit.
pub fn key(arena: std.mem.Allocator, buf: []u8, s: []const u8, mode: Fold) ![]const u8 {
    const out = if (s.len <= buf.len) buf[0..s.len] else try arena.alloc(u8, s.len);
    if (mode == .spelling and !looksNumeric(s)) {
        const b = baseFormRaw(out, s);
        if (b.len > 0) return b;
    }
    return std.ascii.lowerString(out, s);
}

/// Missing-value spellings, matched on base form so "N/A", "n.a.", "#N/A",
/// "(null)", "<NA>" and "NULL" all count (deepchecks' `mixed_nulls` list).
const marker_bases = [_][]const u8{ "na", "nan", "null", "none", "nil" };

pub fn isMarker(s: []const u8) bool {
    if (std.mem.eql(u8, s, "?")) return true;
    if (s.len == 0 or s.len > 8) return false;
    // Fast reject, run on every field while sniffing types: every marker's
    // first letter or digit is an "n". Numbers fail on their first byte.
    for (s) |b| {
        if (b < 0x80 and std.ascii.isAlphanumeric(b)) {
            if (b != 'n' and b != 'N') return false;
            break;
        }
    }
    var buf: [8]u8 = undefined;
    const b = baseFormRaw(&buf, s);
    for (marker_bases) |m| if (std.mem.eql(u8, b, m)) return true;
    return false;
}

/// Characters a reader cannot see or tell from a plain space: ASCII control
/// characters, NBSP, the Unicode space and zero-width runs, BOM, ideographic
/// space.
fn isInvisible(cp: u21) bool {
    return cp < 0x20 or cp == 0x7F or cp == 0x00A0 or cp == 0x00AD or
        (cp >= 0x2000 and cp <= 0x200F) or (cp >= 0x2028 and cp <= 0x202F) or
        (cp >= 0x205F and cp <= 0x206F) or cp == 0x3000 or cp == 0xFEFF;
}

/// A value as a reader should see it: invisible characters written as
/// `<U+00A0>`, so "New York" and "New<U+00A0>York" do not look identical.
/// Format with `{f}`.
pub const Visible = struct {
    s: []const u8,
    /// Also escape for HTML text and attributes.
    html: bool = false,

    pub fn format(v: Visible, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var i: usize = 0;
        const s = v.s;
        while (i < s.len) {
            const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            if (i + len > s.len) {
                try w.writeAll(s[i..]);
                return;
            }
            const cp: u21 = switch (len) {
                1 => s[i],
                2 => std.unicode.utf8Decode2(s[i..][0..2].*) catch 0xFFFD,
                3 => std.unicode.utf8Decode3(s[i..][0..3].*) catch 0xFFFD,
                4 => std.unicode.utf8Decode4(s[i..][0..4].*) catch 0xFFFD,
                else => 0xFFFD,
            };
            if (isInvisible(cp)) {
                try w.print("{s}U+{X:0>4}{s}", .{ if (v.html) "&lt;" else "<", cp, if (v.html) "&gt;" else ">" });
            } else if (v.html and len == 1 and std.mem.findScalar(u8, "&<>\"'", s[i]) != null) {
                try w.writeAll(switch (s[i]) {
                    '&' => "&amp;",
                    '<' => "&lt;",
                    '>' => "&gt;",
                    '"' => "&quot;",
                    else => "&#39;",
                });
            } else try w.writeAll(s[i..][0..len]);
            i += len;
        }
    }
};

pub fn visible(s: []const u8) Visible {
    return .{ .s = s };
}

pub fn visibleHtml(s: []const u8) Visible {
    return .{ .s = s, .html = true };
}

// ------------------------------------------------------------------ checks

/// Share of a file's rows of punctuation-only values above which they are a
/// warning, not a note (deepchecks' `special_chars` default, 0.1%).
const punct_warn_share = 0.001;

pub const Spelling = struct {
    text: []const u8,
    /// Rows per file: train, test, extra.
    rows: [3]usize,
    level: u32,
};

/// Spellings that share a base form but are separate levels.
pub const Group = struct {
    column: usize,
    base: []const u8,
    spellings: []const Spelling,
};

const roles = [_]Role{ .train, .@"test", .extra };

/// Add spelling-variant and punctuation-only findings for every categorical
/// column, and fill `cx.a.spelling_groups`.
pub fn run(cx: an.Ctx) !void {
    const a = cx.a;
    const arena = cx.arena;
    var groups: std.ArrayList(Group) = .empty;
    var buf: [256]u8 = undefined;

    for (a.columns, 0..) |*c, ci| {
        if (c.kind != .categorical) continue;

        // Work from the distinct spellings `analyze` collected; rows are
        // scanned only for a column that has something to report.
        var punct_set: std.array_hash_map.String(void) = .empty;
        var by_base: std.array_hash_map.String(std.ArrayList(Spelling)) = .empty;
        for (c.spellings, 0..) |sps, id| for (sps) |sp| {
            if (!isMarker(sp) and isPunctuationOnly(sp)) try punct_set.put(arena, sp, {});
            if (looksNumeric(sp)) continue;
            const b = baseFormRaw(if (sp.len <= buf.len) buf[0..sp.len] else try arena.alloc(u8, sp.len), sp);
            if (b.len == 0) continue;
            const gop = try by_base.getOrPut(arena, try arena.dupe(u8, b));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .text = sp, .rows = .{ 0, 0, 0 }, .level = @intCast(id) });
        };
        var interesting: std.array_hash_map.String(void) = .empty;
        for (punct_set.keys()) |sp| try interesting.put(arena, sp, {});
        for (by_base.values()) |list| {
            var separate = false;
            for (list.items[1..]) |sp| separate = separate or sp.level != list.items[0].level;
            if (separate) for (list.items) |sp| try interesting.put(arena, sp.text, {});
        }
        if (interesting.count() == 0) continue;

        // Rows per interesting spelling per file.
        var spellings: std.array_hash_map.String([3]usize) = .empty;
        var punct: [3]std.array_hash_map.String(usize) = .{ .empty, .empty, .empty };
        for (roles, 0..) |role, k| {
            const t = a.table(role) orelse continue;
            const p = c.at(role) orelse continue;
            for (t.cols[p.src]) |raw| {
                const sp = an.trim(raw);
                if (sp.len == 0 or !interesting.contains(sp)) continue;
                const gop = try spellings.getOrPut(arena, sp);
                if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0, 0 };
                gop.value_ptr[k] += 1;
                if (punct_set.contains(sp)) {
                    const pg = try punct[k].getOrPut(arena, sp);
                    if (!pg.found_existing) pg.value_ptr.* = 0;
                    pg.value_ptr.* += 1;
                }
            }
        }
        for (by_base.values()) |list| for (list.items) |*sp| {
            sp.rows = spellings.get(sp.text) orelse .{ 0, 0, 0 };
        };

        // Punctuation-only values, per file.
        for (roles, 0..) |role, k| {
            if (punct[k].count() == 0) continue;
            const p = c.at(role).?;
            var total: usize = 0;
            for (punct[k].values()) |v| total += v;
            var list: std.ArrayList(u8) = .empty;
            for (punct[k].keys()[0..@min(punct[k].count(), 4)], punct[k].values()[0..@min(punct[k].count(), 4)], 0..) |s, v, i|
                try list.print(arena, "{s}\"{f}\" ×{d}", .{ if (i > 0) ", " else "", visible(s), v });
            if (punct[k].count() > 4) try list.print(arena, ", … {d} more", .{punct[k].count() - 4});
            const share = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(@max(p.n, 1)));
            try cx.add(if (share > punct_warn_share) .warn else .info, .punctuation_only, role, c.name, "{d} values are only punctuation — placeholders for unknown? {s}", .{ total, list.items });
        }

        // Base-form groups whose spellings are separate levels.
        for (by_base.keys(), by_base.values()) |b, list| {
            if (list.items.len < 2) continue;
            var separate = false;
            for (list.items[1..]) |sp| separate = separate or sp.level != list.items[0].level;
            if (!separate) continue; // one level: case_variants already reports it
            try groups.append(arena, .{ .column = ci, .base = b, .spellings = list.items });
            var text: std.ArrayList(u8) = .empty;
            for (list.items[0..@min(list.items.len, 6)], 0..) |sp, i| {
                try text.print(arena, "{s}\"{f}\" (", .{ if (i > 0) ", " else "", visible(sp.text) });
                var first = true;
                for (roles, sp.rows) |role, k| if (k > 0) {
                    try text.print(arena, "{s}{s} {d}", .{ if (first) "" else ", ", role.label(), k });
                    first = false;
                };
                try text.appendSlice(arena, ")");
            }
            if (list.items.len > 6) try text.print(arena, ", … {d} more", .{list.items.len - 6});
            try cx.add(.warn, .spelling_variants, null, c.name, "{d} spellings of one value are separate levels: {s}; --fold spelling merges them", .{ list.items.len, text.items });

            // Test spellings train never uses, for a value train has.
            var train_has = false;
            for (list.items) |sp| train_has = train_has or sp.rows[0] > 0;
            if (!train_has) continue;
            for (list.items) |sp| if (sp.rows[0] == 0 and sp.rows[1] > 0) {
                var in_train = false;
                for (list.items) |o| in_train = in_train or (o.level == sp.level and o.rows[0] > 0);
                if (!in_train) try cx.add(.warn, .spelling_variants, .@"test", c.name, "\"{f}\" ({d} rows) is spelled a way train never uses; a model will treat it as an unseen level", .{ visible(sp.text), sp.rows[1] });
            };
        }
    }
    a.spelling_groups = groups.items;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

test "baseForm: deepchecks' rule, with the empty fallback" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("newyork", baseForm(&buf, "New-York"));
    try testing.expectEqualStrings("newyork", baseForm(&buf, " new york! "));
    try testing.expectEqualStrings("***", baseForm(&buf, "***"));
    try testing.expectEqualStrings("", baseFormRaw(&buf, "***"));
    // Non-ASCII letters stay; NBSP, en dash and curly quotes go.
    try testing.expectEqualStrings("café", baseForm(&buf, "Café"));
    try testing.expectEqualStrings("newyork", baseForm(&buf, "New\u{00A0}York"));
    try testing.expectEqualStrings("ab", baseForm(&buf, "a\u{2013}b"));
    try testing.expectEqualStrings("ok", baseForm(&buf, "\u{201C}OK\u{201D}"));
    // Invalid UTF-8 bytes are kept, never dropped silently.
    try testing.expectEqualStrings("a\xFFb", baseForm(&buf, "a\xFF-b"));
}

test "punctuation only, short and long" {
    try testing.expect(isPunctuationOnly("?"));
    try testing.expect(isPunctuationOnly("— —"));
    try testing.expect(!isPunctuationOnly(""));
    try testing.expect(!isPunctuationOnly("a-"));
    try testing.expect(isPunctuationOnly("-" ** 100));
    try testing.expect(!isPunctuationOnly("-" ** 100 ++ "x"));
    try testing.expect(!isPunctuationOnly("-" ** 100 ++ "é"));
}

test "markers on base form" {
    for ([_][]const u8{ "NA", "N/A", "n.a.", "#N/A", "(null)", "<NA>", "NULL", "None", "nan", "?" }) |m| try testing.expect(isMarker(m));
    for ([_][]const u8{ "", "-", "Nancy", "nano", "nullable", "a" }) |m| try testing.expect(!isMarker(m));
}

test "key: numbers never fold on base form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("new-york", try key(arena, &buf, "New-York", .case));
    try testing.expectEqualStrings("newyork", try arena.dupe(u8, try key(arena, &buf, "New-York", .spelling)));
    try testing.expectEqualStrings("-5", try arena.dupe(u8, try key(arena, &buf, "-5", .spelling)));
    try testing.expectEqualStrings("1.5", try arena.dupe(u8, try key(arena, &buf, "1.5", .spelling)));
    // Longer than the buffer: the arena takes it.
    try testing.expectEqualStrings("averyveryverylongvalue", try key(arena, &buf, "A-Very-Very-Very-Long-Value", .spelling));
}

fn analyzed(arena: std.mem.Allocator, train: []const u8, tst: ?[]const u8, fold: Fold) !an.Analysis {
    var tables: std.ArrayList(tbl.Table) = .empty;
    try tables.append(arena, try tbl.parse(arena, .train, "train", train));
    if (tst) |t| try tables.append(arena, try tbl.parse(arena, .@"test", "test", t));
    return an.analyze(arena, tables.items, .{ .shift_warn = 1, .fold = fold });
}

fn count(a: *const an.Analysis, code: an.Code, table: ?Role) usize {
    var n: usize = 0;
    for (a.findings.items) |f| n += @intFromBool(f.code == code and f.table == table);
    return n;
}

test "spelling variants: reported and kept apart by default, merged with --fold spelling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const train = "id,c\n0,New York\n1,New York\n2,new-york\n3,Boston\n4,-5\n5,5\n";
    const tst = "id,c\n6,NEW YORK!\n7,Boston\n";
    const a = try analyzed(arena, train, tst, .case);
    // "New York"/"new-york"/"NEW YORK!" are 3 levels; -5 and 5 never group.
    try testing.expectEqual(@as(usize, 1), a.spelling_groups.len);
    try testing.expectEqual(@as(usize, 3), a.spelling_groups[0].spellings.len);
    try testing.expectEqual(@as(usize, 1), count(&a, .spelling_variants, null));
    try testing.expectEqual(@as(usize, 1), count(&a, .spelling_variants, .@"test"));
    const merged = try analyzed(arena, train, tst, .spelling);
    try testing.expectEqual(@as(usize, 0), merged.spelling_groups.len);
    try testing.expectEqual(@as(usize, 0), count(&merged, .spelling_variants, .@"test"));
    // One level for all three spellings, written the most common way.
    const c = &merged.columns[1];
    try testing.expectEqual(c.at(.train).?.cat[0], c.at(.train).?.cat[2]);
    try testing.expectEqual(c.at(.train).?.cat[0], c.at(.@"test").?.cat[0]);
    try testing.expectEqualStrings("New York", c.levels[c.at(.train).?.cat[0]]);
    try testing.expect(c.at(.train).?.cat[4] != c.at(.train).?.cat[5]);
}

test "punctuation-only values: noted when rare, warned past 0.1%, markers excluded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(arena, "id,c\n");
    for (0..2000) |i| try csv.print(arena, "{d},{s}\n", .{ i, if (i == 7) "-" else if (i == 8) "?" else "a" });
    const rare = try analyzed(arena, csv.items, null, .case);
    var sev: ?an.Severity = null;
    var msg: []const u8 = "";
    for (rare.findings.items) |f| if (f.code == .punctuation_only) {
        sev = f.sev;
        msg = f.msg;
    };
    // "-" counts; "?" is a missing marker, reported as such, not here.
    try testing.expect(std.mem.startsWith(u8, msg, "1 values are only punctuation"));
    try testing.expect(std.mem.find(u8, msg, "\"?\"") == null);
    try testing.expectEqual(an.Severity.info, sev.?);
    const many = try analyzed(arena, "id,c\n0,***\n1,a\n2,b\n", null, .case);
    for (many.findings.items) |f| if (f.code == .punctuation_only) {
        sev = f.sev;
    };
    try testing.expectEqual(an.Severity.warn, sev.?);
}

test "mixed missing: two marker spellings with no empty values still count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const two = try analyzed(arena, "id,x\n0,1\n1,NA\n2,null\n3,4\n", null, .case);
    try testing.expectEqual(@as(usize, 1), count(&two, .mixed_missing, .train));
    const one = try analyzed(arena, "id,x\n0,1\n1,NA\n2,NA\n3,4\n", null, .case);
    try testing.expectEqual(@as(usize, 0), count(&one, .mixed_missing, .train));
    // Base-form markers make a numeric column's "n.a." missing, not junk.
    const dotted = try analyzed(arena, "id,x\n0,1\n1,n.a.\n2,3\n", null, .case);
    try testing.expectEqual(@as(usize, 0), count(&dotted, .junk, .train));
}

test "visible: invisible characters are shown, everything else is untouched" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try buf.writer.print("{f}|{f}|{f}|{f}", .{ visible("New\u{00A0}York"), visible("a\u{200B}b\tc"), visible("Café “x”"), visible("bad\xFF") });
    try testing.expectEqualStrings("New<U+00A0>York|a<U+200B>b<U+0009>c|Café “x”|bad\xFF", buf.written());
    buf.clearRetainingCapacity();
    try buf.writer.print("{f}", .{visibleHtml("<b>&\u{00A0}\"'")});
    try testing.expectEqualStrings("&lt;b&gt;&amp;&lt;U+00A0&gt;&quot;&#39;", buf.written());
}

test "a merged group is not reported even when its column has other findings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // "-" makes the column worth a row scan; the New York spellings are one
    // level under --fold spelling and must not come back as variants.
    const a = try analyzed(arena, "id,c\n0,New York\n1,new-york\n2,-\n3,Boston\n", null, .spelling);
    try testing.expectEqual(@as(usize, 0), a.spelling_groups.len);
    try testing.expectEqual(@as(usize, 0), count(&a, .spelling_variants, null));
    try testing.expectEqual(@as(usize, 1), count(&a, .punctuation_only, .train));
}
