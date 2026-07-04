const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Node = ast.Node;
const CharRange = ast.CharRange;

pub const ParseError = error{
    UnexpectedEnd,
    UnexpectedChar,
    UnmatchedParen,
    UnmatchedBracket,
    InvalidRepetition,
    InvalidEscape,
    OutOfMemory,
};

pub const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: Allocator,
    capture_count: u32,

    pub fn init(allocator: Allocator, pattern: []const u8) Parser {
        return .{
            .source = pattern,
            .pos = 0,
            .allocator = allocator,
            .capture_count = 0,
        };
    }

    pub fn parse(self: *Parser) ParseError!*Node {
        const result = try self.parseAlternation();
        if (self.pos < self.source.len) {
            // Unexpected remaining chars (e.g. unmatched ')')
            result.deinit(self.allocator);
            self.allocator.destroy(result);
            return ParseError.UnmatchedParen;
        }
        return result;
    }

    fn parseAlternation(self: *Parser) ParseError!*Node {
        var left = try self.parseConcat();

        while (self.pos < self.source.len and self.source[self.pos] == '|') {
            self.pos += 1;
            const right = try self.parseConcat();
            const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
            node.* = Node{ .alternation = .{ .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    fn parseConcat(self: *Parser) ParseError!*Node {
        // Parse first atom; if nothing is available, return an empty literal
        var left = self.parseQuantified() catch |err| {
            switch (err) {
                ParseError.UnexpectedEnd, ParseError.UnexpectedChar => {
                    // Empty alternative — create an empty literal node
                    const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                    node.* = Node{ .literal = 0 };
                    return node;
                },
                else => return err,
            }
        };

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == ')' or ch == '|') break;

            const right = self.parseQuantified() catch break;
            const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
            node.* = Node{ .concat = .{ .left = left, .right = right } };
            left = node;
        }

        return left;
    }

    fn parseQuantified(self: *Parser) ParseError!*Node {
        var node = try self.parseAtom();

        if (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            switch (ch) {
                '*' => {
                    self.pos += 1;
                    const wrapper = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                    wrapper.* = Node{ .star = node };
                    node = wrapper;
                },
                '+' => {
                    self.pos += 1;
                    const wrapper = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                    wrapper.* = Node{ .plus = node };
                    node = wrapper;
                },
                '?' => {
                    self.pos += 1;
                    const wrapper = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                    wrapper.* = Node{ .question = node };
                    node = wrapper;
                },
                '{' => {
                    const bounds = try self.parseRepetitionBounds();
                    const wrapper = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                    wrapper.* = Node{ .repetition = .{ .child = node, .bounds = bounds } };
                    node = wrapper;
                },
                else => {},
            }
        }

        return node;
    }

    fn parseRepetitionBounds(self: *Parser) ParseError!ast.RepetitionBounds {
        if (self.pos >= self.source.len or self.source[self.pos] != '{')
            return ParseError.InvalidRepetition;
        self.pos += 1;

        const min = try self.parseNumber();

        var max: ?u32 = min;

        if (self.pos < self.source.len and self.source[self.pos] == ',') {
            self.pos += 1;
            if (self.pos < self.source.len and self.source[self.pos] == '}') {
                max = null; // unbounded
            } else {
                max = try self.parseNumber();
            }
        }

        if (self.pos >= self.source.len or self.source[self.pos] != '}')
            return ParseError.InvalidRepetition;
        self.pos += 1;

        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) ParseError!u32 {
        var result: u32 = 0;
        var found = false;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch >= '0' and ch <= '9') {
                result = result * 10 + @as(u32, ch - '0');
                self.pos += 1;
                found = true;
            } else {
                break;
            }
        }
        if (!found) return ParseError.InvalidRepetition;
        return result;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        if (self.pos >= self.source.len) return ParseError.UnexpectedEnd;

        const ch = self.source[self.pos];

        switch (ch) {
            '(' => return self.parseGroup(),
            '[' => return self.parseCharClass(),
            '.' => {
                self.pos += 1;
                const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                node.* = Node.dot;
                return node;
            },
            '^' => {
                self.pos += 1;
                const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                node.* = Node.anchor_start;
                return node;
            },
            '$' => {
                self.pos += 1;
                const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                node.* = Node.anchor_end;
                return node;
            },
            '\\' => return self.parseEscape(),
            ')', '|' => return ParseError.UnexpectedChar,
            '*', '+', '?', '{' => return ParseError.UnexpectedChar,
            else => {
                self.pos += 1;
                const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
                node.* = Node{ .literal = ch };
                return node;
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        if (self.pos >= self.source.len or self.source[self.pos] != '(')
            return ParseError.UnexpectedChar;
        self.pos += 1;

        self.capture_count += 1;
        const idx = self.capture_count;

        const child = try self.parseAlternation();

        if (self.pos >= self.source.len or self.source[self.pos] != ')') {
            child.deinit(self.allocator);
            self.allocator.destroy(child);
            return ParseError.UnmatchedParen;
        }
        self.pos += 1;

        const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;
        node.* = Node{ .group = .{ .child = child, .capture_index = idx } };
        return node;
    }

    fn parseCharClass(self: *Parser) ParseError!*Node {
        if (self.pos >= self.source.len or self.source[self.pos] != '[')
            return ParseError.UnexpectedChar;
        self.pos += 1;

        var negated = false;
        if (self.pos < self.source.len and self.source[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges = std.ArrayList(CharRange).init(self.allocator);
        defer ranges.deinit();

        while (self.pos < self.source.len and self.source[self.pos] != ']') {
            const start_ch = self.source[self.pos];
            self.pos += 1;

            if (self.pos + 1 < self.source.len and self.source[self.pos] == '-' and self.source[self.pos + 1] != ']') {
                self.pos += 1; // skip '-'
                const end_ch = self.source[self.pos];
                self.pos += 1;
                ranges.append(.{ .start = start_ch, .end = end_ch }) catch return ParseError.OutOfMemory;
            } else {
                ranges.append(.{ .start = start_ch, .end = start_ch }) catch return ParseError.OutOfMemory;
            }
        }

        if (self.pos >= self.source.len) return ParseError.UnmatchedBracket;
        self.pos += 1; // skip ']'

        const owned_ranges = ranges.toOwnedSlice() catch return ParseError.OutOfMemory;

        const node = self.allocator.create(Node) catch {
            self.allocator.free(owned_ranges);
            return ParseError.OutOfMemory;
        };
        node.* = Node{ .char_class = .{ .ranges = owned_ranges, .negated = negated } };
        return node;
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        if (self.pos >= self.source.len or self.source[self.pos] != '\\')
            return ParseError.UnexpectedChar;
        self.pos += 1;

        if (self.pos >= self.source.len) return ParseError.InvalidEscape;

        const ch = self.source[self.pos];
        self.pos += 1;

        const node = self.allocator.create(Node) catch return ParseError.OutOfMemory;

        switch (ch) {
            'd' => node.* = Node{ .shorthand = .digit },
            'D' => node.* = Node{ .shorthand = .non_digit },
            'w' => node.* = Node{ .shorthand = .word },
            'W' => node.* = Node{ .shorthand = .non_word },
            's' => node.* = Node{ .shorthand = .whitespace },
            'S' => node.* = Node{ .shorthand = .non_whitespace },
            'n' => node.* = Node{ .literal = '\n' },
            't' => node.* = Node{ .literal = '\t' },
            'r' => node.* = Node{ .literal = '\r' },
            '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$' => {
                node.* = Node{ .literal = ch };
            },
            else => {
                self.allocator.destroy(node);
                return ParseError.InvalidEscape;
            },
        }

        return node;
    }
};

// Tests

test "parse literal" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expectEqual(Node{ .literal = 'a' }, node.*);
}

test "parse concat" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "ab");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .concat);
}

test "parse alternation" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a|b");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .alternation);
}

test "parse star" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a*");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .star);
}

test "parse group" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "(ab)");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .group);
    try std.testing.expectEqual(@as(u32, 1), node.group.capture_index);
}

test "parse char class" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "[a-z]");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .char_class);
    try std.testing.expect(!node.char_class.negated);
    try std.testing.expectEqual(@as(usize, 1), node.char_class.ranges.len);
}

test "parse negated char class" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "[^0-9]");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .char_class);
    try std.testing.expect(node.char_class.negated);
}

test "parse dot" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, ".");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .dot);
}

test "parse anchors" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "^a$");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .concat);
}

test "parse escape sequences" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "\\d\\w\\s");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .concat);
}

test "parse repetition" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "a{2,5}");
    const node = try parser.parse();
    defer {
        node.deinit(allocator);
        allocator.destroy(node);
    }
    try std.testing.expect(node.* == .repetition);
    try std.testing.expectEqual(@as(u32, 2), node.repetition.bounds.min);
    try std.testing.expectEqual(@as(?u32, 5), node.repetition.bounds.max);
}

test "unmatched paren" {
    const allocator = std.testing.allocator;
    var parser = Parser.init(allocator, "(a");
    const result = parser.parse();
    try std.testing.expect(result == ParseError.UnmatchedParen);
}
