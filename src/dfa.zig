const std = @import("std");
const Allocator = std.mem.Allocator;
const nfa_mod = @import("nfa.zig");
const NFA = nfa_mod.NFA;
const Transition = nfa_mod.Transition;
const ast = @import("ast.zig");
const Node = ast.Node;

/// A DFA state is a set of NFA states.
pub const DFAState = struct {
    nfa_states: []u32,
    is_accept: bool,
    transitions: [256]?u32, // One entry per byte value

    pub fn init(allocator: Allocator, nfa_state_set: []const u32, is_accept: bool) !DFAState {
        const owned = try allocator.alloc(u32, nfa_state_set.len);
        @memcpy(owned, nfa_state_set);
        var transitions: [256]?u32 = undefined;
        for (&transitions) |*t| {
            t.* = null;
        }
        return .{
            .nfa_states = owned,
            .is_accept = is_accept,
            .transitions = transitions,
        };
    }

    pub fn deinit(self: *DFAState, allocator: Allocator) void {
        allocator.free(self.nfa_states);
    }
};

/// DFA built via subset construction from an NFA.
pub const DFA = struct {
    states: std.ArrayList(DFAState),
    start: u32,
    allocator: Allocator,

    pub fn init(allocator: Allocator) DFA {
        return .{
            .states = std.ArrayList(DFAState).init(allocator),
            .start = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DFA) void {
        for (self.states.items) |*state| {
            state.deinit(self.allocator);
        }
        self.states.deinit();
    }

    /// Build a DFA from an NFA using subset construction.
    /// Note: This handles literal chars, dot, char classes, and shorthands.
    /// Anchors are not fully supported in DFA mode.
    pub fn buildFromNFA(allocator: Allocator, nfa: *const NFA) !DFA {
        var dfa = DFA.init(allocator);
        errdefer dfa.deinit();

        // Map from sorted NFA state sets to DFA state IDs
        var state_map = std.AutoArrayHashMap(u64, u32).init(allocator);
        defer state_map.deinit();

        // Compute epsilon closure of start state
        var start_closure = std.AutoArrayHashMap(u32, void).init(allocator);
        defer start_closure.deinit();
        try epsilonClosure(nfa, nfa.start, &start_closure);

        var start_set = try sortedKeys(allocator, &start_closure);
        defer allocator.free(start_set);

        const start_hash = hashStateSet(start_set);
        const start_accept = setContainsAccept(nfa, start_set);
        const start_dfa_state = try DFAState.init(allocator, start_set, start_accept);
        try dfa.states.append(start_dfa_state);
        try state_map.put(start_hash, 0);
        dfa.start = 0;

        // Worklist
        var worklist = std.ArrayList(u32).init(allocator);
        defer worklist.deinit();
        try worklist.append(0);

        while (worklist.items.len > 0) {
            const current_id = worklist.pop();
            const current_nfa_states = dfa.states.items[current_id].nfa_states;

            // For each possible byte value
            var byte_val: u16 = 0;
            while (byte_val < 256) : (byte_val += 1) {
                const ch: u8 = @intCast(byte_val);

                var next_closure = std.AutoArrayHashMap(u32, void).init(allocator);
                defer next_closure.deinit();

                // Find all NFA states reachable by consuming ch
                for (current_nfa_states) |nfa_state_id| {
                    const nfa_state = &nfa.states.items[nfa_state_id];
                    for (nfa_state.transitions.items) |edge| {
                        const edge_matches = switch (edge.transition) {
                            .char => |c| c == ch,
                            .any => ch != '\n',
                            .char_class => |cc| charMatchesClass(ch, cc.ranges, cc.negated),
                            .shorthand => |sh| charMatchesShorthand(ch, sh),
                            .epsilon, .anchor_start, .anchor_end => false,
                        };
                        if (edge_matches) {
                            try epsilonClosure(nfa, edge.target, &next_closure);
                        }
                    }
                }

                if (next_closure.count() == 0) continue;

                var next_set = try sortedKeys(allocator, &next_closure);
                defer allocator.free(next_set);

                const next_hash = hashStateSet(next_set);

                const existing = state_map.get(next_hash);
                if (existing) |target_id| {
                    dfa.states.items[current_id].transitions[ch] = target_id;
                } else {
                    const new_id: u32 = @intCast(dfa.states.items.len);
                    const next_accept = setContainsAccept(nfa, next_set);
                    const new_state = try DFAState.init(allocator, next_set, next_accept);
                    try dfa.states.append(new_state);
                    try state_map.put(next_hash, new_id);
                    try worklist.append(new_id);
                    dfa.states.items[current_id].transitions[ch] = new_id;
                }
            }
        }

        return dfa;
    }

    /// Match input against this DFA.
    pub fn matches(self: *const DFA, input: []const u8) bool {
        var current = self.start;
        for (input) |ch| {
            if (self.states.items[current].transitions[ch]) |next| {
                current = next;
            } else {
                return false;
            }
        }
        return self.states.items[current].is_accept;
    }
};

fn epsilonClosure(nfa: *const NFA, state_id: u32, closure: *std.AutoArrayHashMap(u32, void)) !void {
    if (closure.contains(state_id)) return;
    try closure.put(state_id, {});

    const state = &nfa.states.items[state_id];
    for (state.transitions.items) |edge| {
        switch (edge.transition) {
            .epsilon, .anchor_start, .anchor_end => {
                try epsilonClosure(nfa, edge.target, closure);
            },
            else => {},
        }
    }
}

fn sortedKeys(allocator: Allocator, map: *std.AutoArrayHashMap(u32, void)) ![]u32 {
    const keys = try allocator.alloc(u32, map.count());
    var i: usize = 0;
    var iter = map.iterator();
    while (iter.next()) |entry| {
        keys[i] = entry.key_ptr.*;
        i += 1;
    }
    std.mem.sort(u32, keys, {}, std.sort.asc(u32));
    return keys;
}

fn hashStateSet(set: []const u32) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (set) |s| {
        hasher.update(std.mem.asBytes(&s));
    }
    return hasher.final();
}

fn setContainsAccept(nfa: *const NFA, set: []const u32) bool {
    for (set) |s| {
        if (nfa.states.items[s].is_accept) return true;
    }
    return false;
}

pub fn charMatchesClass(ch: u8, ranges: []const ast.CharRange, negated: bool) bool {
    var in_range = false;
    for (ranges) |r| {
        if (ch >= r.start and ch <= r.end) {
            in_range = true;
            break;
        }
    }
    return if (negated) !in_range else in_range;
}

pub fn charMatchesShorthand(ch: u8, class: Node.ShorthandClass) bool {
    return switch (class) {
        .digit => ch >= '0' and ch <= '9',
        .non_digit => !(ch >= '0' and ch <= '9'),
        .word => (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_',
        .non_word => !((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_'),
        .whitespace => ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r',
        .non_whitespace => !(ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'),
    };
}

// Tests
const parser_mod = @import("parser.zig");

test "dfa from simple literal" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    var dfa = try DFA.buildFromNFA(allocator, &nfa);
    defer dfa.deinit();

    try std.testing.expect(dfa.matches("a"));
    try std.testing.expect(!dfa.matches("b"));
    try std.testing.expect(!dfa.matches(""));
}

test "dfa from concat" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "ab");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    var dfa = try DFA.buildFromNFA(allocator, &nfa);
    defer dfa.deinit();

    try std.testing.expect(dfa.matches("ab"));
    try std.testing.expect(!dfa.matches("a"));
    try std.testing.expect(!dfa.matches("abc"));
}

test "dfa from alternation" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a|b");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    var dfa = try DFA.buildFromNFA(allocator, &nfa);
    defer dfa.deinit();

    try std.testing.expect(dfa.matches("a"));
    try std.testing.expect(dfa.matches("b"));
    try std.testing.expect(!dfa.matches("c"));
}

test "dfa from star" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a*");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    var dfa = try DFA.buildFromNFA(allocator, &nfa);
    defer dfa.deinit();

    try std.testing.expect(dfa.matches(""));
    try std.testing.expect(dfa.matches("a"));
    try std.testing.expect(dfa.matches("aaa"));
    try std.testing.expect(!dfa.matches("b"));
}

test "charMatchesShorthand" {
    try std.testing.expect(charMatchesShorthand('5', .digit));
    try std.testing.expect(!charMatchesShorthand('a', .digit));
    try std.testing.expect(charMatchesShorthand('a', .word));
    try std.testing.expect(charMatchesShorthand('_', .word));
    try std.testing.expect(charMatchesShorthand(' ', .whitespace));
    try std.testing.expect(!charMatchesShorthand('a', .whitespace));
}
