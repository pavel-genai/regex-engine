const std = @import("std");
const Allocator = std.mem.Allocator;
const nfa_mod = @import("nfa.zig");
const NFA = nfa_mod.NFA;
const Transition = nfa_mod.Transition;
const dfa_mod = @import("dfa.zig");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const Parser = parser_mod.Parser;

/// Result of a match operation
pub const MatchResult = struct {
    matched: bool,
    start: usize,
    end: usize,
};

/// Regex matcher using NFA simulation
pub const Matcher = struct {
    allocator: Allocator,
    nfa: NFA,
    root: *ast.Node,
    has_start_anchor: bool,

    pub fn init(allocator: Allocator, pattern: []const u8) !Matcher {
        var p = Parser.init(allocator, pattern);
        const root = p.parse() catch return error.InvalidPattern;

        var nfa = NFA.buildFromAst(allocator, root) catch |err| {
            root.deinit(allocator);
            allocator.destroy(root);
            return err;
        };
        _ = &nfa;

        // Check if pattern starts with ^
        const has_start_anchor = pattern.len > 0 and pattern[0] == '^';

        return .{
            .allocator = allocator,
            .nfa = nfa,
            .root = root,
            .has_start_anchor = has_start_anchor,
        };
    }

    pub fn deinit(self: *Matcher) void {
        self.nfa.deinit();
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }

    /// Check if the pattern matches anywhere in the input string (like grep).
    pub fn search(self: *const Matcher, input: []const u8) !bool {
        if (self.has_start_anchor) {
            // Only try matching from position 0
            return try self.matchAt(input, 0);
        }

        // Try matching at every position
        var i: usize = 0;
        while (i <= input.len) : (i += 1) {
            if (try self.matchAt(input, i)) return true;
        }
        return false;
    }

    /// Try to match the NFA starting at position `start` in the input.
    fn matchAt(self: *const Matcher, input: []const u8, start: usize) !bool {
        // NFA simulation using set of current states
        var current = std.AutoArrayHashMap(u32, void).init(self.allocator);
        defer current.deinit();
        var next = std.AutoArrayHashMap(u32, void).init(self.allocator);
        defer next.deinit();

        // Start with epsilon closure of start state
        try addEpsilonClosure(&self.nfa, self.nfa.start, &current, input, start);

        // Check for immediate accept (e.g., empty pattern, anchors only)
        if (current.contains(self.nfa.accept)) return true;

        var pos = start;
        while (pos < input.len) : (pos += 1) {
            const ch = input[pos];

            next.clearRetainingCapacity();

            var iter = current.iterator();
            while (iter.next()) |entry| {
                const state_id = entry.key_ptr.*;
                const state = &self.nfa.states.items[state_id];

                for (state.transitions.items) |edge| {
                    const matches_char = switch (edge.transition) {
                        .char => |c| c == ch,
                        .any => ch != '\n',
                        .char_class => |cc| dfa_mod.charMatchesClass(ch, cc.ranges, cc.negated),
                        .shorthand => |sh| dfa_mod.charMatchesShorthand(ch, sh),
                        .epsilon, .anchor_start, .anchor_end => false,
                    };
                    if (matches_char) {
                        try addEpsilonClosure(&self.nfa, edge.target, &next, input, pos + 1);
                    }
                }
            }

            // Swap current and next
            const tmp = current;
            current = next;
            next = tmp;
            next.clearRetainingCapacity();

            if (current.count() == 0) return false;
            if (current.contains(self.nfa.accept)) return true;
        }

        return current.contains(self.nfa.accept);
    }
};

fn addEpsilonClosure(nfa: *const NFA, state_id: u32, set: *std.AutoArrayHashMap(u32, void), input: []const u8, pos: usize) !void {
    if (set.contains(state_id)) return;
    try set.put(state_id, {});

    const state = &nfa.states.items[state_id];
    for (state.transitions.items) |edge| {
        switch (edge.transition) {
            .epsilon => {
                try addEpsilonClosure(nfa, edge.target, set, input, pos);
            },
            .anchor_start => {
                if (pos == 0) {
                    try addEpsilonClosure(nfa, edge.target, set, input, pos);
                }
            },
            .anchor_end => {
                if (pos == input.len) {
                    try addEpsilonClosure(nfa, edge.target, set, input, pos);
                }
            },
            else => {},
        }
    }
}

// Tests

test "match literal" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "hello");
    defer m.deinit();

    try std.testing.expect(try m.search("hello"));
    try std.testing.expect(try m.search("say hello world"));
    try std.testing.expect(!try m.search("hell"));
    try std.testing.expect(!try m.search("helo"));
}

test "match dot" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "h.llo");
    defer m.deinit();

    try std.testing.expect(try m.search("hello"));
    try std.testing.expect(try m.search("hallo"));
    try std.testing.expect(!try m.search("hllo"));
}

test "match star" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "ab*c");
    defer m.deinit();

    try std.testing.expect(try m.search("ac"));
    try std.testing.expect(try m.search("abc"));
    try std.testing.expect(try m.search("abbc"));
    try std.testing.expect(try m.search("abbbc"));
    try std.testing.expect(!try m.search("adc"));
}

test "match plus" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "ab+c");
    defer m.deinit();

    try std.testing.expect(!try m.search("ac"));
    try std.testing.expect(try m.search("abc"));
    try std.testing.expect(try m.search("abbc"));
}

test "match question" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "ab?c");
    defer m.deinit();

    try std.testing.expect(try m.search("ac"));
    try std.testing.expect(try m.search("abc"));
    try std.testing.expect(!try m.search("abbc"));
}

test "match alternation" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "cat|dog");
    defer m.deinit();

    try std.testing.expect(try m.search("cat"));
    try std.testing.expect(try m.search("dog"));
    try std.testing.expect(!try m.search("cow"));
}

test "match char class" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "[a-z]+");
    defer m.deinit();

    try std.testing.expect(try m.search("hello"));
    try std.testing.expect(!try m.search("12345"));
}

test "match negated char class" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "[^0-9]+");
    defer m.deinit();

    try std.testing.expect(try m.search("hello"));
    try std.testing.expect(!try m.search("12345"));
}

test "match shorthand digit" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "\\d+");
    defer m.deinit();

    try std.testing.expect(try m.search("abc123"));
    try std.testing.expect(!try m.search("abcdef"));
}

test "match shorthand word" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "\\w+");
    defer m.deinit();

    try std.testing.expect(try m.search("hello_123"));
    try std.testing.expect(!try m.search("   "));
}

test "match anchor start" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "^hello");
    defer m.deinit();

    try std.testing.expect(try m.search("hello world"));
    try std.testing.expect(!try m.search("say hello"));
}

test "match anchor end" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "world$");
    defer m.deinit();

    try std.testing.expect(try m.search("hello world"));
    try std.testing.expect(!try m.search("world hello"));
}

test "match group" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "(ab)+");
    defer m.deinit();

    try std.testing.expect(try m.search("ab"));
    try std.testing.expect(try m.search("abab"));
    try std.testing.expect(!try m.search("aa"));
}

test "match repetition" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "a{2,4}");
    defer m.deinit();

    try std.testing.expect(!try m.search("a"));
    try std.testing.expect(try m.search("aa"));
    try std.testing.expect(try m.search("aaa"));
    try std.testing.expect(try m.search("aaaa"));
    try std.testing.expect(try m.search("aaaaa")); // matches substring aaaa
}

test "match complex pattern" {
    const allocator = std.testing.allocator;
    var m = try Matcher.init(allocator, "^[a-z]+\\d{2,}$");
    defer m.deinit();

    try std.testing.expect(try m.search("abc12"));
    try std.testing.expect(try m.search("x99"));
    try std.testing.expect(!try m.search("123abc"));
    try std.testing.expect(!try m.search("abc1"));
}
