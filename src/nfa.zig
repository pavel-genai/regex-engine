const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const CharRange = ast.CharRange;

/// Transition types for NFA edges
pub const Transition = union(enum) {
    /// Match a specific character
    char: u8,
    /// Match any character except newline
    any,
    /// Match a character class (ranges + negation)
    char_class: CharClassTransition,
    /// Shorthand class
    shorthand: Node.ShorthandClass,
    /// Epsilon transition (no input consumed)
    epsilon,
    /// Anchor: start of string
    anchor_start,
    /// Anchor: end of string
    anchor_end,

    pub const CharClassTransition = struct {
        ranges: []const CharRange,
        negated: bool,
    };
};

/// A single NFA state
pub const State = struct {
    transitions: std.ArrayList(Edge),
    is_accept: bool,

    pub fn init(allocator: Allocator) State {
        return .{
            .transitions = std.ArrayList(Edge).init(allocator),
            .is_accept = false,
        };
    }

    pub fn addTransition(self: *State, transition: Transition, target: u32) !void {
        try self.transitions.append(.{ .transition = transition, .target = target });
    }
};

pub const Edge = struct {
    transition: Transition,
    target: u32,
};

/// NFA built via Thompson's construction
pub const NFA = struct {
    states: std.ArrayList(State),
    start: u32,
    accept: u32,
    allocator: Allocator,
    /// References to char_class ranges from the AST that this NFA borrows.
    /// We don't own these, so we don't free them.

    pub fn init(allocator: Allocator) NFA {
        return .{
            .states = std.ArrayList(State).init(allocator),
            .start = 0,
            .accept = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NFA) void {
        for (self.states.items) |*state| {
            state.transitions.deinit();
        }
        self.states.deinit();
    }

    pub fn addState(self: *NFA) !u32 {
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(State.init(self.allocator));
        return id;
    }

    pub fn stateCount(self: *const NFA) u32 {
        return @intCast(self.states.items.len);
    }

    /// Compile an AST node into this NFA using Thompson's construction.
    /// Returns (start_state, accept_state) for the compiled fragment.
    pub fn compile(self: *NFA, node: *const Node) Allocator.Error!struct { start: u32, accept: u32 } {
        switch (node.*) {
            .literal => |ch| {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.{ .char = ch }, a);
                return .{ .start = s, .accept = a };
            },
            .dot => {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.any, a);
                return .{ .start = s, .accept = a };
            },
            .char_class => |cc| {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.{ .char_class = .{
                    .ranges = cc.ranges,
                    .negated = cc.negated,
                } }, a);
                return .{ .start = s, .accept = a };
            },
            .shorthand => |sh| {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.{ .shorthand = sh }, a);
                return .{ .start = s, .accept = a };
            },
            .anchor_start => {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.anchor_start, a);
                return .{ .start = s, .accept = a };
            },
            .anchor_end => {
                const s = try self.addState();
                const a = try self.addState();
                try self.states.items[s].addTransition(.anchor_end, a);
                return .{ .start = s, .accept = a };
            },
            .concat => |c| {
                const left = try self.compile(c.left);
                const right = try self.compile(c.right);
                try self.states.items[left.accept].addTransition(.epsilon, right.start);
                return .{ .start = left.start, .accept = right.accept };
            },
            .alternation => |a| {
                const s = try self.addState();
                const accept = try self.addState();
                const left = try self.compile(a.left);
                const right = try self.compile(a.right);
                try self.states.items[s].addTransition(.epsilon, left.start);
                try self.states.items[s].addTransition(.epsilon, right.start);
                try self.states.items[left.accept].addTransition(.epsilon, accept);
                try self.states.items[right.accept].addTransition(.epsilon, accept);
                return .{ .start = s, .accept = accept };
            },
            .star => |child| {
                const s = try self.addState();
                const accept = try self.addState();
                const inner = try self.compile(child);
                try self.states.items[s].addTransition(.epsilon, inner.start);
                try self.states.items[s].addTransition(.epsilon, accept);
                try self.states.items[inner.accept].addTransition(.epsilon, inner.start);
                try self.states.items[inner.accept].addTransition(.epsilon, accept);
                return .{ .start = s, .accept = accept };
            },
            .plus => |child| {
                const s = try self.addState();
                const accept = try self.addState();
                const inner = try self.compile(child);
                try self.states.items[s].addTransition(.epsilon, inner.start);
                try self.states.items[inner.accept].addTransition(.epsilon, inner.start);
                try self.states.items[inner.accept].addTransition(.epsilon, accept);
                return .{ .start = s, .accept = accept };
            },
            .question => |child| {
                const s = try self.addState();
                const accept = try self.addState();
                const inner = try self.compile(child);
                try self.states.items[s].addTransition(.epsilon, inner.start);
                try self.states.items[s].addTransition(.epsilon, accept);
                try self.states.items[inner.accept].addTransition(.epsilon, accept);
                return .{ .start = s, .accept = accept };
            },
            .repetition => |rep| {
                return try self.compileRepetition(rep.child, rep.bounds);
            },
            .group => |g| {
                // For NFA purposes, groups are transparent (capture is handled at match time)
                return try self.compile(g.child);
            },
        }
    }

    fn compileRepetition(self: *NFA, child: *const Node, bounds: ast.RepetitionBounds) Allocator.Error!struct { start: u32, accept: u32 } {
        // Build min required copies concatenated
        const entry = try self.addState();
        var current_end = entry;

        var i: u32 = 0;
        while (i < bounds.min) : (i += 1) {
            const frag = try self.compile(child);
            try self.states.items[current_end].addTransition(.epsilon, frag.start);
            current_end = frag.accept;
        }

        if (bounds.max) |max| {
            // Build (max - min) optional copies
            var j: u32 = bounds.min;
            const final_accept = try self.addState();
            try self.states.items[current_end].addTransition(.epsilon, final_accept);

            while (j < max) : (j += 1) {
                const frag = try self.compile(child);
                try self.states.items[current_end].addTransition(.epsilon, frag.start);
                current_end = frag.accept;
                try self.states.items[current_end].addTransition(.epsilon, final_accept);
            }

            return .{ .start = entry, .accept = final_accept };
        } else {
            // Unbounded: after min copies, add a star-like loop
            const loop_start = try self.addState();
            const accept = try self.addState();
            try self.states.items[current_end].addTransition(.epsilon, loop_start);
            const frag = try self.compile(child);
            try self.states.items[loop_start].addTransition(.epsilon, frag.start);
            try self.states.items[loop_start].addTransition(.epsilon, accept);
            try self.states.items[frag.accept].addTransition(.epsilon, loop_start);
            return .{ .start = entry, .accept = accept };
        }
    }

    /// Build a complete NFA from an AST root node.
    pub fn buildFromAst(allocator: Allocator, root: *const Node) !NFA {
        var nfa = NFA.init(allocator);
        errdefer nfa.deinit();

        const result = try nfa.compile(root);
        nfa.start = result.start;
        nfa.accept = result.accept;
        nfa.states.items[result.accept].is_accept = true;
        return nfa;
    }
};

// Tests
const parser_mod = @import("parser.zig");

test "nfa compile literal" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    try std.testing.expect(nfa.stateCount() == 2);
    try std.testing.expect(nfa.states.items[nfa.accept].is_accept);
}

test "nfa compile concat" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "ab");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    try std.testing.expect(nfa.stateCount() >= 4);
    try std.testing.expect(nfa.states.items[nfa.accept].is_accept);
}

test "nfa compile alternation" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a|b");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    try std.testing.expect(nfa.stateCount() >= 6);
}

test "nfa compile star" {
    const allocator = std.testing.allocator;
    var p = parser_mod.Parser.init(allocator, "a*");
    const root = try p.parse();
    defer {
        root.deinit(allocator);
        allocator.destroy(root);
    }

    var nfa = try NFA.buildFromAst(allocator, root);
    defer nfa.deinit();

    try std.testing.expect(nfa.stateCount() >= 4);
}
