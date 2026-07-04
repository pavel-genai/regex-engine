const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a single character class range, e.g., a-z
pub const CharRange = struct {
    start: u8,
    end: u8,
};

/// Quantifier bounds for {n,m} syntax
pub const RepetitionBounds = struct {
    min: u32,
    max: ?u32, // null means unbounded
};

/// AST node representing a parsed regex pattern
pub const Node = union(enum) {
    /// A literal character
    literal: u8,

    /// Dot — matches any character except newline
    dot,

    /// Character class: list of ranges + negation flag
    char_class: CharClass,

    /// Zero or more (*)
    star: *Node,

    /// One or more (+)
    plus: *Node,

    /// Zero or one (?)
    question: *Node,

    /// Repetition {n,m}
    repetition: Repetition,

    /// Concatenation of two nodes
    concat: Concat,

    /// Alternation (|)
    alternation: Concat,

    /// Capture group
    group: Group,

    /// Start anchor (^)
    anchor_start,

    /// End anchor ($)
    anchor_end,

    /// Shorthand character class: \d, \w, \s, \D, \W, \S
    shorthand: ShorthandClass,

    pub const CharClass = struct {
        ranges: []CharRange,
        negated: bool,
    };

    pub const Repetition = struct {
        child: *Node,
        bounds: RepetitionBounds,
    };

    pub const Concat = struct {
        left: *Node,
        right: *Node,
    };

    pub const Group = struct {
        child: *Node,
        capture_index: u32,
    };

    pub const ShorthandClass = enum {
        digit, // \d
        word, // \w
        whitespace, // \s
        non_digit, // \D
        non_word, // \W
        non_whitespace, // \S
    };

    /// Recursively free this node and its children.
    pub fn deinit(self: *Node, allocator: Allocator) void {
        switch (self.*) {
            .literal, .dot, .anchor_start, .anchor_end, .shorthand => {},
            .char_class => |cc| {
                allocator.free(cc.ranges);
            },
            .star => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .plus => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .question => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .repetition => |rep| {
                rep.child.deinit(allocator);
                allocator.destroy(rep.child);
            },
            .concat => |c| {
                c.left.deinit(allocator);
                allocator.destroy(c.left);
                c.right.deinit(allocator);
                allocator.destroy(c.right);
            },
            .alternation => |a| {
                a.left.deinit(allocator);
                allocator.destroy(a.left);
                a.right.deinit(allocator);
                allocator.destroy(a.right);
            },
            .group => |g| {
                g.child.deinit(allocator);
                allocator.destroy(g.child);
            },
        }
    }
};

test "ast node creation" {
    const allocator = std.testing.allocator;

    const node = try allocator.create(Node);
    node.* = Node{ .literal = 'a' };
    node.deinit(allocator);
    allocator.destroy(node);
}

test "ast concat creation" {
    const allocator = std.testing.allocator;

    const left = try allocator.create(Node);
    left.* = Node{ .literal = 'a' };

    const right = try allocator.create(Node);
    right.* = Node{ .literal = 'b' };

    const concat = try allocator.create(Node);
    concat.* = Node{ .concat = .{ .left = left, .right = right } };

    concat.deinit(allocator);
    allocator.destroy(concat);
}
