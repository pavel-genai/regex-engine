const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "regex-engine",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the regex engine CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_files = [_][]const u8{
        "src/ast.zig",
        "src/parser.zig",
        "src/nfa.zig",
        "src/dfa.zig",
        "src/matcher.zig",
        "src/main.zig",
    };

    const test_step = b.step("test", "Run unit tests");

    for (test_files) |file| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
