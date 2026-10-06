// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! M1.5 — the HTML report: one self-contained file (inline CSS, inline SVG,
//! a few lines of script, nothing fetched), readable offline and on a phone.
//! It renders the same `Analysis` as the text report, so the two never
//! disagree. Each milestone adds a section here as it is built.
//!
//! Chart rules (docs/PLAN.md, M1.5): one axis per chart — the target rate is
//! its own panel sharing the rows, never a second y-axis over the
//! distribution; train/test/extra are fixed colour slots validated for colour
//! blindness in both themes; every chart has a table view.
//!
//! Every string that came from a data file (column names, levels, file
//! paths) goes through `esc`. The script only toggles classes and attributes;
//! it never inserts text into the page.

const std = @import("std");
const an = @import("analyze.zig");
const drift = @import("drift.zig");
const target_rate = @import("target_rate.zig");
const Analysis = an.Analysis;
const Column = an.Column;
const Role = an.Role;
const Writer = std.Io.Writer;

/// Escape for HTML text and attribute values.
fn esc(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const rep: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// 1234567 → "1,234,567".
fn count(w: *Writer, n: usize) Writer.Error!void {
    var buf: [32]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable; // zsnag:ok a usize fits in 32 bytes
    for (digits, 0..) |d, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(d);
    }
}

fn roleName(r: Role) []const u8 {
    return switch (r) {
        .train => "train",
        .@"test" => "test",
        .extra => "extra",
        .sub => "submission",
    };
}

/// Colour slot per file: the first three categorical slots of the reference
/// palette, the only three that validate all-pairs in both themes.
fn seriesVar(r: Role) []const u8 {
    return switch (r) {
        .train => "var(--s-train)",
        .@"test" => "var(--s-test)",
        .extra => "var(--s-extra)",
        .sub => "var(--ink-3)",
    };
}

const css =
    \\:root{color-scheme:light;--page:#f9f9f7;--surface:#fcfcfb;--ink-1:#0b0b0b;--ink-2:#52514e;--ink-3:#898781;
    \\--grid:#e1e0d9;--axis:#c3c2b7;--ring:rgba(11,11,11,.10);--hover:rgba(11,11,11,.05);
    \\--s-train:#2a78d6;--s-test:#eb6834;--s-extra:#1baf7a;
    \\--critical:#d03b3b;--warning:#fab219;--info:#898781}
    \\@media (prefers-color-scheme:dark){:root:where(:not([data-theme="light"])){color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;
    \\--ink-1:#fff;--ink-2:#c3c2b7;--ink-3:#898781;--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);--hover:rgba(255,255,255,.06);
    \\--s-train:#3987e5;--s-test:#d95926;--s-extra:#199e70}}
    \\:root[data-theme="dark"]{color-scheme:dark;--page:#0d0d0d;--surface:#1a1a19;
    \\--ink-1:#fff;--ink-2:#c3c2b7;--ink-3:#898781;--grid:#2c2c2a;--axis:#383835;--ring:rgba(255,255,255,.10);--hover:rgba(255,255,255,.06);
    \\--s-train:#3987e5;--s-test:#d95926;--s-extra:#199e70}
    \\*{box-sizing:border-box}
    \\body{margin:0;background:var(--page);color:var(--ink-1);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif}
    \\main{max-width:1400px;margin:0 auto;padding:24px 16px 64px}
    \\header{display:flex;flex-wrap:wrap;gap:12px;align-items:baseline;justify-content:space-between}
    \\h1{font-size:22px;margin:0}h2{font-size:17px;margin:32px 0 12px}h3{font-size:15px;margin:0;overflow-wrap:anywhere}
    \\.sub{color:var(--ink-2);margin:4px 0 0;overflow-wrap:anywhere}
    \\button,input{font:inherit;color:inherit;background:var(--surface);border:1px solid var(--ring);border-radius:8px;padding:6px 10px}
    \\.tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;margin-top:20px}
    \\.tile,.card,.panel{background:var(--surface);border:1px solid var(--ring);border-radius:12px;padding:14px 16px}
    \\.tile .l{color:var(--ink-2);font-size:13px}.tile .v{font-size:24px;font-weight:600}
    \\.legend{display:flex;flex-wrap:wrap;gap:16px;color:var(--ink-2);font-size:13px;margin:8px 0}
    \\.legend i{display:inline-block;width:12px;height:12px;border-radius:3px;margin-right:6px;vertical-align:-1px}
    \\.filters{display:flex;flex-wrap:wrap;gap:16px;align-items:center;margin-bottom:12px}
    \\.findings{list-style:none;margin:0;padding:0}
    \\.findings li{display:flex;gap:10px;padding:7px 0;border-top:1px solid var(--grid)}
    \\.findings li:first-child{border-top:0}
    \\.sev{flex:none;min-width:84px;font-size:12px;font-weight:600;color:var(--ink-2)}
    \\.sev b{display:inline-block;width:16px;height:16px;border-radius:50%;color:#fff;text-align:center;line-height:16px;font-size:11px;margin-right:6px}
    \\.err .sev b{background:var(--critical)}.warn .sev b{background:var(--warning);color:#0b0b0b}.info .sev b{background:var(--info)}
    \\.msg{overflow-wrap:anywhere}.msg em{font-style:normal;color:var(--ink-2)}
    \\body.hide-err .panel li.err,body.hide-warn .panel li.warn,body.hide-info .panel li.info,.findings.hide-info li.info{display:none}
    \\.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,620px),1fr));gap:16px}
    \\.card[hidden]{display:none}
    \\.badges{display:flex;flex-wrap:wrap;gap:6px;margin:6px 0}
    \\.badge{font-size:12px;color:var(--ink-2);border:1px solid var(--ring);border-radius:999px;padding:1px 8px}
    \\.meta{color:var(--ink-2);font-size:13px;margin:4px 0 8px;overflow-wrap:anywhere}
    \\.card ul.findings{margin:6px 0 10px}.card .findings li{font-size:13px;padding:4px 0}
    \\.chart{overflow-x:auto;margin:0 -4px;padding:0 4px}
    \\svg{display:block;width:100%;min-width:540px;height:auto;overflow:visible}
    \\svg text{font:12px system-ui,-apple-system,"Segoe UI",sans-serif;fill:var(--ink-2)}
    \\svg .tick{fill:var(--ink-3);font-size:11px;font-variant-numeric:tabular-nums}
    \\svg .tick.flag{fill:var(--ink-1);font-weight:600}
    \\svg .grid{stroke:var(--grid);stroke-width:1}svg .base{stroke:var(--axis);stroke-width:1}
    \\svg .hit{fill:transparent}svg .row:hover .hit{fill:var(--hover)}
    \\details{margin-top:8px}summary{cursor:pointer;color:var(--ink-2);font-size:13px}
    \\table{border-collapse:collapse;width:100%;font-size:12px;font-variant-numeric:tabular-nums;margin-top:6px}
    \\th,td{text-align:right;padding:3px 6px;border-bottom:1px solid var(--grid)}th:first-child,td:first-child{text-align:left;overflow-wrap:anywhere}
    \\footer{color:var(--ink-3);font-size:12px;margin-top:40px}
;

const script =
    \\const root=document.documentElement;
    \\document.getElementById('theme').addEventListener('click',()=>{
    \\ const dark=root.dataset.theme?root.dataset.theme==='dark':matchMedia('(prefers-color-scheme: dark)').matches;
    \\ root.dataset.theme=dark?'light':'dark';});
    \\for(const cb of document.querySelectorAll('[data-sev]'))
    \\ cb.addEventListener('change',()=>{document.body.classList.toggle('hide-'+cb.dataset.sev,!cb.checked);
    \\  for(const l of document.querySelectorAll('.panel .findings'))l.classList.remove('hide-'+cb.dataset.sev);});
    \\const q=document.getElementById('q');
    \\q.addEventListener('input',()=>{const v=q.value.trim().toLowerCase();
    \\ for(const c of document.querySelectorAll('article.card'))c.hidden=v!==''&&!c.dataset.name.toLowerCase().includes(v);});
;

pub fn write(w: *Writer, a: *const Analysis, opts: an.Options) Writer.Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>zscour report</title><style>" ++ css ++ "</style></head><body><main>\n");

    try w.writeAll("<header><div><h1>zscour report</h1><p class=\"sub\">");
    for (a.tables, 0..) |t, i| {
        if (i > 0) try w.writeAll(" · ");
        try w.print("{s}: ", .{roleName(t.role)});
        try esc(w, t.path);
    }
    try w.writeAll("</p></div><button id=\"theme\" type=\"button\">Light / dark</button></header>\n");

    try tiles(w, a);
    try findings(w, a);
    try driftSection(w, a, opts);
    try columns(w, a);

    try w.writeAll("<footer>Generated by zscour · charts after ideas from sweetviz and ydata-profiling " ++
        "(MIT; see docs/prior-art.md)</footer>\n</main><script>" ++ script ++ "</script></body></html>\n");
}

fn tiles(w: *Writer, a: *const Analysis) Writer.Error!void {
    try w.writeAll("<section class=\"tiles\">");
    for (a.tables) |t| {
        try w.print("<div class=\"tile\"><div class=\"l\">{s}</div><div class=\"v\">", .{roleName(t.role)});
        try count(w, t.n_rows);
        try w.print("</div><div class=\"l\">rows · {d} columns</div></div>", .{t.names.len});
    }
    for ([_]an.Severity{ .err, .warn, .info }, [_][]const u8{ "Errors", "Warnings", "Notes" }) |sev, label| {
        try w.print("<div class=\"tile\"><div class=\"l\">{s}</div><div class=\"v\">{d}</div></div>", .{ label, a.count(sev) });
    }
    try w.writeAll("</section>\n");
}

fn sevClass(s: an.Severity) []const u8 {
    return switch (s) {
        .err => "err",
        .warn => "warn",
        .info => "info",
    };
}

/// Severity is never colour alone: an icon and a word go with it.
fn sevMark(w: *Writer, s: an.Severity) Writer.Error!void {
    try w.writeAll(switch (s) {
        .err => "<span class=\"sev\"><b>✕</b>Error</span>",
        .warn => "<span class=\"sev\"><b>!</b>Warning</span>",
        .info => "<span class=\"sev\"><b>i</b>Note</span>",
    });
}

fn findingItem(w: *Writer, f: an.Finding, with_column: bool) Writer.Error!void {
    try w.print("<li class=\"{s}\">", .{sevClass(f.sev)});
    try sevMark(w, f.sev);
    try w.writeAll("<span class=\"msg\">");
    if (f.table) |r| try w.print("<em>[{s}]</em> ", .{roleName(r)});
    if (with_column) if (f.column) |c| {
        try w.writeAll("<strong>");
        try esc(w, c);
        try w.writeAll("</strong>: ");
    };
    try esc(w, f.msg);
    try w.writeAll("</span></li>\n");
}

const notes_open = 10;

fn findings(w: *Writer, a: *const Analysis) Writer.Error!void {
    try w.writeAll("<h2>Findings</h2><div class=\"panel\"><div class=\"filters\">");
    // Many notes would push every chart off screen: past `notes_open` they
    // start collapsed, one click away.
    const notes_hidden = a.count(.info) > notes_open;
    for ([_]an.Severity{ .err, .warn, .info }, [_][]const u8{ "Errors", "Warnings", "Notes" }) |sev, label|
        try w.print("<label><input type=\"checkbox\"{s} data-sev=\"{s}\"> {s} ({d})</label>", .{ if (sev == .info and notes_hidden) "" else " checked", sevClass(sev), label, a.count(sev) });
    try w.writeAll("</div>");
    if (a.findings.items.len == 0) {
        try w.writeAll("<p class=\"sub\">Nothing to report.</p></div>\n");
        return;
    }
    try w.print("<ul class=\"findings{s}\">", .{if (notes_hidden) " hide-info" else ""});
    for ([_]an.Severity{ .err, .warn, .info }) |sev| for (a.findings.items) |f| if (f.sev == sev) try findingItem(w, f, true);
    try w.writeAll("</ul></div>\n");
}

fn legend(w: *Writer, a: *const Analysis) Writer.Error!void {
    try w.writeAll("<div class=\"legend\">");
    for (a.tables) |t| {
        if (t.role == .sub) continue;
        try w.print("<span><i style=\"background:{s}\"></i>{s}</span>", .{ seriesVar(t.role), roleName(t.role) });
    }
    try w.writeAll("</div>");
}

// ------------------------------------------------------------------ geometry

const chart_w = 640.0;
const label_w = 150.0;
const pad_r = 16.0;
const top_pad = 22.0;
const bottom_pad = 24.0;
const bar_h = 8.0;
const bar_gap = 2.0;
const row_pad = 10.0;

/// A horizontal bar from `x0` with a 4px rounded data end and a square
/// baseline end.
fn hbar(w: *Writer, x0: f64, y: f64, len: f64, h: f64, fill: []const u8) Writer.Error!void {
    if (len <= 0) return;
    const r = @min(4.0, @min(h / 2, len));
    const x1 = x0 + len;
    try w.print("<path fill=\"{s}\" d=\"M{d:.1},{d:.1}H{d:.1}Q{d:.1},{d:.1} {d:.1},{d:.1}V{d:.1}Q{d:.1},{d:.1} {d:.1},{d:.1}H{d:.1}Z\"/>", .{
        fill, x0, y, x1 - r, x1, y, x1, y + r, y + h - r, x1, y + h, x1 - r, y + h, x0,
    });
}

/// Rounds `x` up to the next step of 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8 ×
/// 10^k: fine enough that an axis is never close to twice its data.
fn niceCeil(x: f64) f64 {
    if (x <= 0) return 1;
    const p = std.math.pow(f64, 10, @floor(std.math.log10(x)));
    for ([_]f64{ 1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10 }) |m| if (m * p >= x - 1e-12) return m * p;
    return 10 * p;
}

/// A number short enough for a label: integers whole, others to four
/// decimals (or four significant digits when smaller) with trailing zeros
/// dropped.
fn numText(buf: []u8, x: f64) []const u8 {
    if (@floor(x) == x and @abs(x) < 1e15)
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(x))}) catch "?";
    const mag = @abs(x);
    const s = if (mag != 0 and mag < 0.001)
        std.fmt.bufPrint(buf, "{e:.3}", .{x}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d:.4}", .{x}) catch "?";
    if (std.mem.findScalar(u8, s, 'e') != null) return s;
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
}

/// Tick anchors that keep a panel's end labels inside the panel, so two
/// panels side by side never print into each other.
fn anchor(q: f64) []const u8 {
    return if (q == 0) "start" else if (q == 1) "end" else "middle";
}

fn pctText(buf: []u8, x: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d:.1}%", .{100 * x}) catch "?";
}

fn truncLabel(w: *Writer, s: []const u8, max: usize) Writer.Error!void {
    if (s.len <= max) return esc(w, s);
    // Cut on a UTF-8 boundary.
    var cut = max - 1;
    while (cut > 0 and (s[cut] & 0xC0) == 0x80) cut -= 1;
    try esc(w, s[0..cut]);
    try w.writeAll("…");
}

// --------------------------------------------------------------------- drift

const drift_rows_max = 40;

fn driftSection(w: *Writer, a: *const Analysis, opts: an.Options) Writer.Error!void {
    const has_test = a.table(.@"test") != null;
    const has_extra = a.table(.extra) != null;
    if (a.table(.train) == null or (!has_test and !has_extra)) return;
    try w.writeAll("<h2>How far each file is from train</h2><div class=\"cards\">");
    for ([_]Role{ .@"test", .extra }) |role| {
        if (a.table(role) == null) continue;
        try driftChart(w, a, role, opts.shift_warn);
    }
    try w.writeAll("</div>\n");
}

fn driftChart(w: *Writer, a: *const Analysis, role: Role, threshold: f64) Writer.Error!void {
    const Item = struct { name: []const u8, value: f64, ks: bool };
    var items: [512]Item = undefined;
    var n: usize = 0;
    var total: usize = 0;
    for (a.columns) |*c| {
        if (c.use == .id) continue;
        const train = c.at(.train) orelse continue;
        const other = c.at(role) orelse continue;
        const v = switch (c.kind) {
            .numeric => drift.ks(train.sorted, other.sorted),
            .categorical => drift.tvd(train.level_counts, other.level_counts),
            .empty => continue,
        };
        total += 1;
        // Keep the largest `items.len`; ties keep file order.
        if (n < items.len) {
            items[n] = .{ .name = c.name, .value = v, .ks = c.kind == .numeric };
            n += 1;
        } else {
            var min_i: usize = 0;
            for (items[1..], 1..) |it, i| if (it.value < items[min_i].value) {
                min_i = i;
            };
            if (v > items[min_i].value) items[min_i] = .{ .name = c.name, .value = v, .ks = c.kind == .numeric };
        }
    }
    if (n == 0) return;
    const S = struct {
        fn more(_: void, x: Item, y: Item) bool {
            return x.value > y.value;
        }
    };
    std.mem.sort(Item, items[0..n], {}, S.more);
    const shown = @min(n, drift_rows_max);

    var top: f64 = threshold * 1.5;
    for (items[0..shown]) |it| top = @max(top, it.value);
    top = niceCeil(top);
    const row_h = 18.0;
    const plot_x = label_w + 8;
    const plot_w = chart_w - plot_x - pad_r - 40; // room for tip labels
    const h = top_pad + @as(f64, @floatFromInt(shown)) * row_h + bottom_pad;

    try w.print("<div class=\"card\"><h3>{s} vs train</h3>", .{roleName(role)});
    try w.writeAll("<p class=\"meta\">Kolmogorov–Smirnov statistic for numeric columns, total variation distance " ++
        "for categorical ones: 0 = same distribution, 1 = no overlap. ");
    try w.print("The line marks the flag threshold ({d}); values at or past it are bold.", .{threshold});
    if (shown < total) try w.print(" Largest {d} of {d} columns.", .{ shown, total });
    try w.print("</p><div class=\"chart\"><svg viewBox=\"0 0 {d} {d:.0}\" role=\"img\" aria-label=\"Distribution shift of each column, {s} vs train\">", .{ chart_w, h, roleName(role) });
    // Grid and ticks.
    for ([_]f64{ 0, 0.5, 1 }) |f| {
        const x = plot_x + f * plot_w;
        try w.print("<line class=\"grid\" x1=\"{d:.1}\" x2=\"{d:.1}\" y1=\"{d}\" y2=\"{d:.1}\"/>", .{ x, x, top_pad - 4, h - bottom_pad });
        try w.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\">{d}</text>", .{ x, h - 8, anchor(f), f * top });
    }
    for (items[0..shown], 0..) |it, i| {
        const y = top_pad + @as(f64, @floatFromInt(i)) * row_h;
        try w.writeAll("<g class=\"row\"><title>");
        try esc(w, it.name);
        try w.print(": {s} = {d:.4}</title>", .{ if (it.ks) "KS" else "total variation", it.value });
        try w.print("<rect class=\"hit\" x=\"0\" y=\"{d:.1}\" width=\"{d}\" height=\"{d}\"/>", .{ y, chart_w, row_h });
        try w.print("<text x=\"{d}\" y=\"{d:.1}\" text-anchor=\"end\">", .{ label_w, y + 13 });
        try truncLabel(w, it.name, 22);
        try w.writeAll("</text>");
        const len = it.value / top * plot_w;
        // One neutral colour: train/test/extra colours mean "which file",
        // so they cannot also mean "flagged". The flag is the bold value and the line.
        try hbar(w, plot_x, y + 4, len, 10, "var(--ink-3)");
        try w.print("<text class=\"tick{s}\" x=\"{d:.1}\" y=\"{d:.1}\">{d:.4}</text>", .{ if (it.value >= threshold) " flag" else "", plot_x + len + 6, y + 13, it.value });
        try w.writeAll("</g>");
    }
    const tx = plot_x + threshold / top * plot_w;
    try w.print("<line class=\"base\" x1=\"{d:.1}\" x2=\"{d:.1}\" y1=\"{d}\" y2=\"{d:.1}\"/>", .{ tx, tx, top_pad - 8, h - bottom_pad });
    try w.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d}\" text-anchor=\"middle\">flag ≥ {d}</text>", .{ tx, top_pad - 10, threshold });
    try w.writeAll("</svg></div></div>");
}

// ------------------------------------------------------------------- columns

fn columns(w: *Writer, a: *const Analysis) Writer.Error!void {
    try w.writeAll("<h2>Columns</h2><div class=\"filters\"><input id=\"q\" type=\"search\" placeholder=\"Filter columns by name\" aria-label=\"Filter columns by name\">");
    try legend(w, a);
    try w.writeAll("</div>");
    switch (a.target_mode) {
        .binary => |b| {
            try w.writeAll("<p class=\"sub\">Left: share of each file's rows per level, value or bin. Right: share of train rows with ");
            try esc(w, a.columns[a.target.?].name);
            try w.writeAll(" = ");
            try esc(w, b.label);
            try w.writeAll(" (dots; the line is the overall rate). Features are ordered by η², the share of the target's variance their rows explain.</p>");
        },
        .mean => {
            try w.writeAll("<p class=\"sub\">Left: share of each file's rows per level, value or bin. Right: mean ");
            try esc(w, a.columns[a.target.?].name);
            try w.writeAll(" per row (dots; the line is the overall mean). Features are ordered by η².</p>");
        },
        .none => {},
    }
    try w.writeAll("<div class=\"cards\">");
    // Target first, then features in the M1 ranking, then everything else.
    if (a.target) |ti| try card(w, a, ti);
    for (a.target_rates) |f| if (a.columns[f.column].use == .feature) try card(w, a, f.column);
    for (a.columns, 0..) |c, i| {
        if (c.use == .target) continue;
        var ranked = false;
        for (a.target_rates) |f| ranked = ranked or (f.column == i and c.use == .feature);
        if (!ranked) try card(w, a, i);
    }
    try w.writeAll("</div>\n");
}

fn featureOf(a: *const Analysis, ci: usize) ?*const target_rate.Feature {
    for (a.target_rates) |*f| if (f.column == ci) return f;
    return null;
}

fn card(w: *Writer, a: *const Analysis, ci: usize) Writer.Error!void {
    const c = &a.columns[ci];
    try w.writeAll("<article class=\"card\" data-name=\"");
    try esc(w, c.name);
    try w.writeAll("\"><h3>");
    try esc(w, c.name);
    try w.writeAll("</h3><div class=\"badges\">");
    switch (c.use) {
        .id => try w.writeAll("<span class=\"badge\">id</span>"),
        .target => try w.writeAll("<span class=\"badge\">target</span>"),
        .feature => {},
    }
    switch (c.kind) {
        .numeric => try w.print("<span class=\"badge\">{s}</span>", .{if (c.integral) "integer" else "decimal"}),
        .categorical => try w.print("<span class=\"badge\">categorical · {d} levels</span>", .{c.levels.len}),
        .empty => try w.writeAll("<span class=\"badge\">empty</span>"),
    }
    const f = featureOf(a, ci);
    if (f) |ft| if (ft.eta2) |e| try w.print("<span class=\"badge\">η² {d:.4}</span>", .{e});
    try w.writeAll("</div><div class=\"meta\">missing ");
    var first = true;
    for ([_]Role{ .train, .@"test", .extra }) |r| {
        const p = c.at(r) orelse continue;
        if (!first) try w.writeAll(" · ");
        first = false;
        try w.print("{s} ", .{roleName(r)});
        try count(w, p.missingCount(c.kind));
    }
    if (c.kind == .numeric) if (c.at(.train) orelse c.at(.@"test")) |p| if (p.sorted.len > 0) {
        var b0: [40]u8 = undefined;
        var b1: [40]u8 = undefined;
        var b2: [40]u8 = undefined;
        try w.print(" — min {s} · median {s} · max {s}", .{ numText(&b0, p.quantile(0)), numText(&b1, p.quantile(0.5)), numText(&b2, p.quantile(1)) });
    };
    try w.writeAll("</div>");

    // This column's findings.
    var any = false;
    for (a.findings.items) |fd| {
        const col = fd.column orelse continue;
        if (!std.mem.eql(u8, col, c.name)) continue;
        if (!any) try w.writeAll("<ul class=\"findings\">");
        any = true;
        try findingItem(w, fd, false);
    }
    if (any) try w.writeAll("</ul>");

    if (f) |ft| {
        try rowChart(w, a, c, ft);
        try rowTable(w, a, ft);
    }
    try w.writeAll("</article>\n");
}

/// Two panels sharing one row axis: each file's share of rows (grouped
/// bars) and, for a feature of a dataset with a target, the target rate
/// (dots, joined for ordered bins/values).
fn rowChart(w: *Writer, a: *const Analysis, c: *const Column, f: *const target_rate.Feature) Writer.Error!void {
    if (f.rows.len == 0) return;
    const roles = [_]Role{ .train, .@"test" };
    var n_series: usize = 1;
    var has_test = false;
    for (f.rows) |r| has_test = has_test or r.test_share != null;
    if (has_test) n_series = 2;

    var has_rate = false;
    var has_extra_rate = false;
    for (f.rows) |r| {
        has_rate = has_rate or r.rate != null;
        has_extra_rate = has_extra_rate or r.extra_rate != null;
    }
    const band = @as(f64, @floatFromInt(n_series)) * bar_h + @as(f64, @floatFromInt(n_series - 1)) * bar_gap + row_pad;
    const n_rows: f64 = @floatFromInt(f.rows.len);
    const h = top_pad + n_rows * band + bottom_pad;
    const dist_x = label_w + 8;
    const rate_w: f64 = if (has_rate) 170 else 0;
    const gap: f64 = if (has_rate) 36 else 0;
    const dist_w = chart_w - dist_x - pad_r - rate_w - gap;
    const rate_x = dist_x + dist_w + gap;

    var top: f64 = 0;
    for (f.rows) |r| top = @max(top, @max(r.train_share, r.test_share orelse 0));
    top = @min(1.0, niceCeil(top));

    // Rate scale: 0–1 for a binary target; the rates' own range for a mean.
    var lo: f64 = 0;
    var hi: f64 = 1;
    if (has_rate and a.target_mode == .mean) {
        lo = std.math.inf(f64);
        hi = -std.math.inf(f64);
        for (f.rows) |r| for ([_]?f64{ r.rate, r.extra_rate }) |v| if (v) |x| {
            lo = @min(lo, x);
            hi = @max(hi, x);
        };
        const span = if (hi > lo) hi - lo else @max(@abs(hi), 1);
        lo -= span * 0.05;
        hi += span * 0.05;
    }
    const rx = struct {
        fn at(x: f64, l: f64, hgh: f64, x0: f64, wid: f64) f64 {
            return x0 + (x - l) / (hgh - l) * wid;
        }
    }.at;

    try w.print("<div class=\"chart\"><svg viewBox=\"0 0 {d} {d:.0}\" role=\"img\" aria-label=\"", .{ chart_w, h });
    try esc(w, c.name);
    try w.writeAll(": share of rows per level or bin");
    if (has_rate) try w.writeAll(", and target rate");
    try w.writeAll("\">");

    // Panel titles, grid, ticks.
    try w.print("<text x=\"{d:.1}\" y=\"12\">share of rows</text>", .{dist_x});
    for ([_]f64{ 0, 0.5, 1 }) |q| {
        const x = dist_x + q * dist_w;
        var buf: [16]u8 = undefined;
        try w.print("<line class=\"{s}\" x1=\"{d:.1}\" x2=\"{d:.1}\" y1=\"{d}\" y2=\"{d:.1}\"/>", .{ if (q == 0) "base" else "grid", x, x, top_pad - 4, h - bottom_pad });
        try w.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\">{s}</text>", .{ x, h - 8, anchor(q), pctText(&buf, q * top) });
    }
    if (has_rate) {
        try w.print("<text x=\"{d:.1}\" y=\"12\">{s}</text>", .{ rate_x, if (a.target_mode == .mean) "target mean" else "target rate" });
        for ([_]f64{ 0, 0.5, 1 }) |q| {
            const x = rate_x + q * rate_w;
            const v = lo + q * (hi - lo);
            try w.print("<line class=\"grid\" x1=\"{d:.1}\" x2=\"{d:.1}\" y1=\"{d}\" y2=\"{d:.1}\"/>", .{ x, x, top_pad - 4, h - bottom_pad });
            var buf: [24]u8 = undefined;
            const label = if (a.target_mode == .mean) std.fmt.bufPrint(&buf, "{d:.3}", .{v}) catch "?" else pctText(&buf, v);
            try w.print("<text class=\"tick\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"{s}\">{s}</text>", .{ x, h - 8, anchor(q), label });
        }
    }

    // Rows.
    for (f.rows, 0..) |r, i| {
        const y = top_pad + @as(f64, @floatFromInt(i)) * band;
        try w.writeAll("<g class=\"row\"><title>");
        try esc(w, r.label);
        var buf: [16]u8 = undefined;
        try w.print(" — train {s} (", .{pctText(&buf, r.train_share)});
        try count(w, r.train_count);
        try w.writeAll(" rows)");
        if (r.test_share) |ts| try w.print(" · test {s}", .{pctText(&buf, ts)});
        if (r.rate) |rt| if (a.target_mode == .mean) try w.print(" · mean {d:.4}", .{rt}) else try w.print(" · rate {s}", .{pctText(&buf, rt)});
        if (r.extra_rate) |er| if (a.target_mode == .mean) try w.print(" · extra mean {d:.4}", .{er}) else try w.print(" · extra rate {s}", .{pctText(&buf, er)});
        try w.print("</title><rect class=\"hit\" x=\"0\" y=\"{d:.1}\" width=\"{d}\" height=\"{d:.1}\"/>", .{ y, chart_w, band });
        try w.print("<text x=\"{d}\" y=\"{d:.1}\" text-anchor=\"end\">", .{ label_w, y + band / 2 + 4 - row_pad / 2 });
        try truncLabel(w, r.label, 22);
        try w.writeAll("</text>");
        for (roles[0..n_series], 0..) |role, k| {
            const v = if (role == .train) r.train_share else (r.test_share orelse 0);
            const by = y + @as(f64, @floatFromInt(k)) * (bar_h + bar_gap);
            try hbar(w, dist_x, by, v / top * dist_w, bar_h, seriesVar(role));
        }
        try w.writeAll("</g>");
    }

    if (has_rate) {
        // Overall rate / mean as a reference line.
        var all_sum: f64 = 0;
        var all_n: f64 = 0;
        for (f.rows) |r| if (r.rate) |rt| {
            const k: f64 = @floatFromInt(r.train_count);
            all_sum += rt * k;
            all_n += k;
        };
        if (all_n > 0) {
            const x = rx(all_sum / all_n, lo, hi, rate_x, rate_w);
            try w.print("<line class=\"base\" x1=\"{d:.1}\" x2=\"{d:.1}\" y1=\"{d}\" y2=\"{d:.1}\"/>", .{ x, x, top_pad - 4, h - bottom_pad });
        }
        const ordered = c.kind == .numeric;
        for ([_]bool{ true, false }) |is_train| {
            if (!is_train and !has_extra_rate) continue;
            const color = if (is_train) "var(--s-train)" else "var(--s-extra)";
            if (ordered) {
                try w.print("<polyline fill=\"none\" stroke=\"{s}\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\" points=\"", .{color});
                for (f.rows, 0..) |r, i| {
                    if (r.kind != .value) continue;
                    const v = (if (is_train) r.rate else r.extra_rate) orelse continue;
                    const y = top_pad + @as(f64, @floatFromInt(i)) * band + (band - row_pad) / 2;
                    try w.print("{d:.1},{d:.1} ", .{ rx(v, lo, hi, rate_x, rate_w), y });
                }
                try w.writeAll("\"/>");
            }
            for (f.rows, 0..) |r, i| {
                const v = (if (is_train) r.rate else r.extra_rate) orelse continue;
                const y = top_pad + @as(f64, @floatFromInt(i)) * band + (band - row_pad) / 2;
                try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"4\" fill=\"{s}\" stroke=\"var(--surface)\" stroke-width=\"2\"/>", .{ rx(v, lo, hi, rate_x, rate_w), y, color });
            }
        }
    }
    try w.writeAll("</svg></div>");
}

/// The chart's numbers as a table: every value reachable without hovering.
fn rowTable(w: *Writer, a: *const Analysis, f: *const target_rate.Feature) Writer.Error!void {
    var has_test = false;
    var has_rate = false;
    var has_extra = false;
    for (f.rows) |r| {
        has_test = has_test or r.test_share != null;
        has_rate = has_rate or r.rate != null;
        has_extra = has_extra or r.extra_rate != null;
    }
    const rate_head = if (a.target_mode == .mean) "mean" else "rate";
    try w.writeAll("<details><summary>Table</summary><table><thead><tr><th>row</th><th>train rows</th><th>train</th>");
    if (has_test) try w.writeAll("<th>test</th>");
    if (has_rate) try w.print("<th>{s}</th>", .{rate_head});
    if (has_extra) try w.print("<th>extra {s}</th>", .{rate_head});
    try w.writeAll("</tr></thead><tbody>");
    for (f.rows) |r| {
        var buf: [16]u8 = undefined;
        try w.writeAll("<tr><td>");
        try esc(w, r.label);
        try w.writeAll("</td><td>");
        try count(w, r.train_count);
        try w.print("</td><td>{s}</td>", .{pctText(&buf, r.train_share)});
        if (has_test) try w.print("<td>{s}</td>", .{if (r.test_share) |t| pctText(&buf, t) else "–"});
        for ([_]bool{ has_rate, has_extra }, [_]?f64{ r.rate, r.extra_rate }) |show, v| {
            if (!show) continue;
            if (v) |x| {
                if (a.target_mode == .mean) try w.print("<td>{d:.4}</td>", .{x}) else try w.print("<td>{s}</td>", .{pctText(&buf, x)});
            } else try w.writeAll("<td>–</td>");
        }
        try w.writeAll("</tr>");
    }
    try w.writeAll("</tbody></table></details>");
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const tbl = @import("table.zig");

fn render(arena: std.mem.Allocator, train: []const u8, tst: ?[]const u8) ![]const u8 {
    var tables: std.ArrayList(tbl.Table) = .empty;
    try tables.append(arena, try tbl.parse(arena, .train, "train.csv", train));
    if (tst) |t| try tables.append(arena, try tbl.parse(arena, .@"test", "test.csv", t));
    const a = try an.analyze(arena, tables.items, .{});
    var buf: Writer.Allocating = .init(arena);
    try write(&buf.writer, &a, .{});
    return buf.written();
}

test "esc and count" {
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try esc(&buf.writer, "<a href=\"x\">&'</a>");
    try count(&buf.writer, 1234567);
    try count(&buf.writer, 12);
    try testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;1,234,56712", buf.written());
}

test "a hostile column name or level is escaped everywhere, never markup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const html = try render(arena_state.allocator(),
        "id,\"<script>alert(1)</script>\",y\n0,\"<img src=x onerror=alert(2)>\",1\n1,b,0\n",
        "id,\"<script>alert(1)</script>\"\n2,b\n");
    // The only <script> tag is the report's own, at the end.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "<script>"));
    try testing.expect(std.mem.find(u8, html, "<img") == null);
    try testing.expect(std.mem.find(u8, html, "&lt;script&gt;alert(1)&lt;/script&gt;") != null);
    try testing.expect(std.mem.find(u8, html, "&lt;img src=x onerror=alert(2)&gt;") != null);
}

test "page is self-contained: no external fetches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const html = try render(arena_state.allocator(), "id,x,c,y\n0,1.5,a,1\n1,2.5,b,0\n2,3,a,1\n", "id,x,c\n3,2,b\n");
    try testing.expect(std.mem.find(u8, html, "http") == null);
    try testing.expect(std.mem.find(u8, html, " src=") == null);
    try testing.expect(std.mem.startsWith(u8, html, "<!doctype html>"));
    try testing.expect(std.mem.endsWith(u8, html, "</html>\n"));
}

test "one chart per column with rows, rate panel only with a target, table view for each" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const with_target = try render(arena, "id,x,c,y\n0,1.5,a,1\n1,2.5,b,0\n2,3,a,1\n", "id,x,c\n3,2,b\n");
    // Charts: x, c, y (target) plus the drift chart.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, with_target, "<svg "));
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, with_target, "<summary>Table</summary>"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_target, ">target rate</text>"));
    const no_target = try render(arena, "id,x\n0,1\n1,2\n", null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, no_target, "<svg "));
    try testing.expect(std.mem.find(u8, no_target, "target rate") == null);
}

test "hbar: rounded data end, square baseline, nothing for zero length" {
    var buf: Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try hbar(&buf.writer, 10, 20, 0, 8, "red");
    try testing.expectEqual(@as(usize, 0), buf.written().len);
    try hbar(&buf.writer, 10, 20, 50, 8, "red");
    try testing.expectEqualStrings("<path fill=\"red\" d=\"M10.0,20.0H56.0Q60.0,20.0 60.0,24.0V24.0Q60.0,28.0 56.0,28.0H10.0Z\"/>", buf.written());
    // Shorter than the corner radius: the radius shrinks to the length, so
    // the path never runs backwards past its own baseline.
    buf.clearRetainingCapacity();
    try hbar(&buf.writer, 10, 20, 2, 8, "red");
    try testing.expectEqualStrings("<path fill=\"red\" d=\"M10.0,20.0H10.0Q12.0,20.0 12.0,22.0V26.0Q12.0,28.0 10.0,28.0H10.0Z\"/>", buf.written());
}

test "niceCeil" {
    try testing.expectEqual(@as(f64, 0.5), niceCeil(0.46));
    try testing.expectEqual(@as(f64, 0.2), niceCeil(0.2));
    try testing.expectApproxEqAbs(@as(f64, 0.8), niceCeil(0.51 * 1.5), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.12), niceCeil(0.10005), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.03), niceCeil(0.03), 1e-12);
}

test "numText" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("42", numText(&buf, 42));
    try testing.expectEqualStrings("-3", numText(&buf, -3));
    try testing.expectEqualStrings("0.4978", numText(&buf, 0.4978118668822066));
    try testing.expectEqualStrings("1.5", numText(&buf, 1.5));
    try testing.expectEqualStrings("5.830e-5", numText(&buf, 0.00005830073554957682));
}
