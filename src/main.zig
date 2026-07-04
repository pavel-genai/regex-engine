const std = @import("std");
const matcher_mod = @import("matcher.zig");
const Matcher = matcher_mod.Matcher;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: regex-engine <pattern> [file]\n", .{});
        try stderr.print("Reads from stdin if no file is given.\n", .{});
        std.process.exit(1);
    }

    const pattern = args[1];

    var m = Matcher.init(allocator, pattern) catch |err| {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Error compiling pattern: {}\n", .{err});
        std.process.exit(1);
    };
    defer m.deinit();

    const stdin = std.io.getStdIn();
    var buf_reader = std.io.bufferedReader(stdin.reader());
    var reader = buf_reader.reader();
    const stdout = std.io.getStdOut().writer();

    var line_buf: [8192]u8 = undefined;
    var any_match = false;

    while (true) {
        const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error reading input: {}\n", .{err});
            std.process.exit(1);
        };

        if (line == null) break;

        const matched = m.search(line.?) catch |err| {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("Error during matching: {}\n", .{err});
            std.process.exit(1);
        };

        if (matched) {
            any_match = true;
            try stdout.print("{s}\n", .{line.?});
        }
    }

    if (!any_match) {
        std.process.exit(1);
    }
}

// Tests
test "imports compile" {
    // Verify that all modules can be imported
    _ = @import("ast.zig");
    _ = @import("parser.zig");
    _ = @import("nfa.zig");
    _ = @import("dfa.zig");
    _ = @import("matcher.zig");
}
