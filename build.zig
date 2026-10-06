// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    // zarbor (LGPL-3.0+) trains M5's train-vs-test classifier.
    const zarbor = b.dependency("zarbor", .{ .target = target, .optimize = optimize }).module("zarbor");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zarbor", .module = zarbor }},
    });
    const exe = b.addExecutable(.{ .name = "zscour", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Audit (and optionally clean) a dataset's CSV files").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // `zig build test-tsan` — the unit tests under ThreadSanitizer (M5 trains
    // on zarbor's thread pool). Needs LLVM, libc and an explicit linux-gnu
    // target, as in zsift and zarbor. zarbor is instrumented too.
    const tsan_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu });
    const tsan_zarbor = b.dependency("zarbor", .{ .target = tsan_target, .optimize = optimize }).module("zarbor");
    tsan_zarbor.sanitize_thread = true;
    tsan_zarbor.link_libc = true;
    const tsan_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = tsan_target,
            .optimize = optimize,
            .link_libc = true,
            .sanitize_thread = true,
            .imports = &.{.{ .name = "zarbor", .module = tsan_zarbor }},
        }),
        .use_llvm = true,
    });
    b.step("test-tsan", "Run unit tests under ThreadSanitizer (data races)").dependOn(&b.addRunArtifact(tsan_tests).step);

    const check = b.addExecutable(.{ .name = "zscour", .root_module = mod });
    b.step("check", "Type-check without installing").dependOn(&check.step);
}
