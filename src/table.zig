// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! One CSV file as raw text: header, column-major fields, and what was wrong
//! with the bytes before any value was looked at. Nothing is trimmed or
//! converted here; `analyze.zig` judges the values.

const std = @import("std");
const zsift = @import("vendor/zsift/csv.zig");

pub const Role = enum {
    train,
    @"test",
    extra,
    sub,

    pub fn label(r: Role) []const u8 {
        return @tagName(r);
    }
};

/// Record numbers kept per issue; the count itself is always exact.
pub const max_examples = 5;

/// A count of occurrences plus the first few record numbers. Record N is the
/// Nth CSV record, header = 1, which is the line number unless a quoted field
/// spans lines.
pub const Examples = struct {
    count: usize = 0,
    at: [max_examples]usize = undefined,

    pub fn add(e: *Examples, record: usize) void {
        if (e.count < max_examples) e.at[e.count] = record;
        e.count += 1;
    }

    pub fn slice(e: *const Examples) []const usize {
        return e.at[0..@min(e.count, max_examples)];
    }
};

pub const FileIssues = struct {
    bom: bool = false,
    crlf: usize = 0,
    lf: usize = 0,
    cr: usize = 0,
    nul: usize = 0,
    utf8_valid: bool = true,
    final_newline: bool = true,
    /// Records that are a single empty field: blank lines. Skipped.
    blank: Examples = .{},
    /// Records whose field count differs from the header's. Skipped.
    ragged: Examples = .{},
    /// The parser stopped at this record; nothing after it was read.
    parse_error: ?struct { err: anyerror, record: usize } = null,
};

pub const Table = struct {
    role: Role,
    path: []const u8,
    names: []const []const u8,
    /// cols[c][r]: the field as written, quotes removed, nothing trimmed.
    cols: []const []const []const u8,
    /// Record number of each kept row, for reports.
    records: []const usize,
    n_rows: usize,
    issues: FileIssues,

    pub fn column(t: *const Table, name: []const u8) ?usize {
        for (t.names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
        return null;
    }
};

const bom = "\xEF\xBB\xBF";

/// Parse `bytes` into a `Table`. Everything is allocated in `arena`, and
/// fields borrow from `bytes`, which must outlive the table.
pub fn parse(arena: std.mem.Allocator, role: Role, path: []const u8, raw: []const u8) !Table {
    var issues: FileIssues = .{};
    var bytes = raw;
    if (std.mem.startsWith(u8, bytes, bom)) {
        issues.bom = true;
        bytes = bytes[bom.len..];
    }
    scanBytes(bytes, &issues);

    // Upper bound on records: quoted newlines only make this larger.
    var max_records: usize = 1;
    for (bytes) |c| max_records += @intFromBool(c == '\n' or c == '\r');

    const scratch = try arena.alloc(u8, 1 << 20);
    var p = try zsift.Parser.init(bytes, scratch, .{});

    var names: std.ArrayList([]const u8) = .empty;
    var record: usize = 1;
    // Header: read field by field so a parse error is reported, not fatal.
    while (true) {
        const f = p.next() catch |err| {
            issues.parse_error = .{ .err = err, .record = record };
            break;
        } orelse break;
        try names.append(arena, try own(arena, bytes, f.bytes));
        if (f.last_in_record) break;
    }
    if (names.items.len == 0) return error.EmptyFile;
    const width = names.items.len;

    const cols = try arena.alloc([][]const u8, width);
    for (cols) |*c| c.* = try arena.alloc([]const u8, max_records);
    const records = try arena.alloc(usize, max_records);
    const row = try arena.alloc([]const u8, width);

    var n_rows: usize = 0;
    if (issues.parse_error == null) records: while (true) {
        record += 1;
        p.resetScratch();
        var n_fields: usize = 0;
        while (true) {
            const f = p.next() catch |err| {
                issues.parse_error = .{ .err = err, .record = record };
                break :records;
            } orelse {
                if (n_fields == 0) break :records;
                break;
            };
            if (n_fields < width) row[n_fields] = f.bytes;
            n_fields += 1;
            if (f.last_in_record) break;
        }
        if (n_fields == 1 and row[0].len == 0 and width > 1) {
            issues.blank.add(record);
            continue;
        }
        if (n_fields != width) {
            issues.ragged.add(record);
            continue;
        }
        for (cols, row) |c, v| c[n_rows] = try own(arena, bytes, v);
        records[n_rows] = record;
        n_rows += 1;
    };

    const out_cols = try arena.alloc([]const []const u8, width);
    for (out_cols, cols) |*o, c| o.* = c[0..n_rows];
    return .{
        .role = role,
        .path = path,
        .names = names.items,
        .cols = out_cols,
        .records = records[0..n_rows],
        .n_rows = n_rows,
        .issues = issues,
    };
}

/// A field that points into the parser's scratch (it held an escaped quote)
/// is copied, since scratch is reused by the next record.
fn own(arena: std.mem.Allocator, input: []const u8, field: []const u8) ![]const u8 {
    const lo = @intFromPtr(input.ptr);
    const at = @intFromPtr(field.ptr);
    if (at >= lo and at + field.len <= lo + input.len) return field;
    return arena.dupe(u8, field);
}

fn scanBytes(bytes: []const u8, issues: *FileIssues) void {
    issues.utf8_valid = std.unicode.utf8ValidateSlice(bytes);
    if (bytes.len > 0) {
        const last = bytes[bytes.len - 1];
        issues.final_newline = last == '\n' or last == '\r';
    }
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            0 => issues.nul += 1,
            '\n' => issues.lf += 1,
            '\r' => if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                issues.crlf += 1;
                i += 1;
            } else {
                issues.cr += 1;
            },
            else => {},
        }
    }
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "clean file: no issues, fields borrowed" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = try parse(a.allocator(), .train, "t", "id,x\n1,a\n2,b\n");
    try testing.expectEqual(@as(usize, 2), t.n_rows);
    try testing.expectEqualStrings("b", t.cols[1][1]);
    try testing.expectEqual(@as(usize, 3), t.records[1]);
    try testing.expect(!t.issues.bom and t.issues.crlf == 0 and t.issues.lf == 3);
    try testing.expect(t.issues.final_newline and t.issues.parse_error == null);
}

test "BOM, CRLF, blank line, ragged rows, missing final newline" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = try parse(a.allocator(), .train, "t", bom ++ "id,x\r\n1,a\r\n\r\n2\r\n3,c,extra\r\n4,d");
    try testing.expect(t.issues.bom);
    try testing.expectEqualStrings("id", t.names[0]);
    try testing.expectEqual(@as(usize, 5), t.issues.crlf);
    try testing.expect(!t.issues.final_newline);
    try testing.expectEqual(@as(usize, 1), t.issues.blank.count);
    try testing.expectEqual(@as(usize, 3), t.issues.blank.at[0]);
    try testing.expectEqual(@as(usize, 2), t.issues.ragged.count);
    try testing.expectEqualSlices(usize, &.{ 4, 5 }, t.issues.ragged.slice());
    try testing.expectEqual(@as(usize, 2), t.n_rows);
    try testing.expectEqualStrings("d", t.cols[1][1]);
}

test "escaped quote survives the next record reusing scratch" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = try parse(a.allocator(), .train, "t", "id,x\n1,\"say \"\"hi\"\"\"\n2,\"a\"\"b\"\n");
    try testing.expectEqualStrings("say \"hi\"", t.cols[1][0]);
    try testing.expectEqualStrings("a\"b", t.cols[1][1]);
}

test "unterminated quote is reported with its record, earlier rows kept" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = try parse(a.allocator(), .train, "t", "id,x\n1,a\n2,\"oops\n");
    try testing.expectEqual(@as(usize, 1), t.n_rows);
    try testing.expectEqual(@as(usize, 3), t.issues.parse_error.?.record);
}

test "NUL bytes and invalid UTF-8 are counted" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const t = try parse(a.allocator(), .train, "t", "id,x\n1,a\x00\n2,\xC0\n");
    try testing.expectEqual(@as(usize, 1), t.issues.nul);
    try testing.expect(!t.issues.utf8_valid);
}
