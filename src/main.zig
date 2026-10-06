// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zscour: audit a tabular dataset's CSV files for the problems that quietly
//! cost a model — malformed records, mixed missing markers, junk in numeric
//! columns, case variants, duplicate or conflicting rows, train/test shift,
//! a submission file that does not line up — and optionally write cleaned
//! copies. Exit 0: no errors; 1: errors found; 2: usage or I/O failure.

const std = @import("std");
const tbl = @import("table.zig");
const an = @import("analyze.zig");
const report = @import("report.zig");
const clean = @import("clean.zig");

const usage =
    \\usage: zscour [DIR] [options]
    \\
    \\  DIR              read DIR/train.csv, DIR/test.csv and DIR/sample_submission.csv
    \\                   (whichever exist)
    \\  --train FILE     training data (has the target)
    \\  --test FILE      test data (no target)
    \\  --extra FILE     more labelled data, e.g. the original a synthetic set came from
    \\  --sub FILE       sample submission: checked against test's ids
    \\  --id NAME        id column (default: id)
    \\  --target NAME    target column (default: the train column test lacks)
    \\  --shift X        flag train/test KS or total variation above X (default 0.02)
    \\  --out DIR        write cleaned train/test/extra and report.txt into DIR
    \\
;

const Args = struct {
    files: [4]?[]const u8 = .{ null, null, null, null },
    opts: an.Options = .{},
    out: ?[]const u8 = null,
};

fn parseArgs(arena: std.mem.Allocator, io: std.Io, argv: []const [:0]const u8) !Args {
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.Help;
        if (!std.mem.startsWith(u8, arg, "--")) {
            try fromDir(arena, io, &args, arg);
            continue;
        }
        if (i + 1 >= argv.len) return error.MissingValue;
        i += 1;
        const v: []const u8 = argv[i];
        if (std.mem.eql(u8, arg, "--train")) {
            args.files[@intFromEnum(tbl.Role.train)] = v;
        } else if (std.mem.eql(u8, arg, "--test")) {
            args.files[@intFromEnum(tbl.Role.@"test")] = v;
        } else if (std.mem.eql(u8, arg, "--extra")) {
            args.files[@intFromEnum(tbl.Role.extra)] = v;
        } else if (std.mem.eql(u8, arg, "--sub")) {
            args.files[@intFromEnum(tbl.Role.sub)] = v;
        } else if (std.mem.eql(u8, arg, "--id")) {
            args.opts.id = v;
        } else if (std.mem.eql(u8, arg, "--target")) {
            args.opts.target = v;
        } else if (std.mem.eql(u8, arg, "--shift")) {
            args.opts.shift_warn = std.fmt.parseFloat(f64, v) catch return error.BadNumber;
        } else if (std.mem.eql(u8, arg, "--out")) {
            args.out = v;
        } else return error.UnknownOption;
    }
    return args;
}

/// Kaggle's usual file names inside DIR; explicit flags still override.
fn fromDir(arena: std.mem.Allocator, io: std.Io, args: *Args, dir: []const u8) !void {
    const names = [_]struct { tbl.Role, []const u8 }{
        .{ .train, "train.csv" },
        .{ .@"test", "test.csv" },
        .{ .sub, "sample_submission.csv" },
    };
    var found = false;
    for (names) |n| {
        const path = try std.fs.path.join(arena, &.{ dir, n[1] });
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        if (args.files[@intFromEnum(n[0])] == null) args.files[@intFromEnum(n[0])] = path;
        found = true;
    }
    if (!found) return error.NoDataInDir;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    const args = parseArgs(arena, io, argv) catch |err| {
        if (err != error.Help) std.log.err("{s}", .{@errorName(err)});
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(if (err == error.Help) 0 else 2);
    };

    var tables: std.ArrayList(tbl.Table) = .empty;
    for (args.files, 0..) |maybe, ri| {
        const path = maybe orelse continue;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |err| {
            std.log.err("{s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        const t = tbl.parse(arena, @enumFromInt(ri), path, bytes) catch |err| {
            std.log.err("{s}: {s}", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        try tables.append(arena, t);
    }
    if (tables.items.len == 0) {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    }

    const a = try an.analyze(arena, tables.items, args.opts);

    var text: std.Io.Writer.Allocating = .init(arena);
    try report.write(&text.writer, &a);

    if (args.out) |dir_path| {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir_path);
        var dir = try cwd.openDir(io, dir_path, .{});
        defer dir.close(io);
        var changes: std.ArrayList(clean.Changes) = .empty;
        for (a.tables) |*t| {
            if (t.role == .sub) continue;
            const name = try std.fmt.allocPrint(arena, "{s}.csv", .{t.role.label()});
            var file = try dir.createFile(io, name, .{});
            defer file.close(io);
            var fbuf: [256 * 1024]u8 = undefined;
            var fw = file.writer(io, &fbuf);
            try changes.append(arena, try clean.writeTable(arena, &fw.interface, &a, t));
            try fw.end();
        }
        try clean.writeChanges(&text.writer, changes.items);
        try text.writer.print("  → {s}/\n", .{dir_path});
        try dir.writeFile(io, .{ .sub_path = "report.txt", .data = text.written() });
    }

    try out.writeAll(text.written());
    try out.flush();
    if (a.count(.err) > 0) std.process.exit(1);
}

test {
    _ = tbl;
    _ = an;
    _ = report;
    _ = clean;
}
