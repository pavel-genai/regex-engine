# Regex Engine

[![CI](https://github.com/ai-pavel/pattern/actions/workflows/ci.yml/badge.svg)](https://github.com/ai-pavel/pattern/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/ai-pavel/pattern/branch/main/graph/badge.svg)](https://codecov.io/gh/ai-pavel/pattern)

A regex engine written in Zig 0.13, implementing parsing, NFA compilation (Thompson's construction), optional NFA-to-DFA conversion (subset construction), and matching.

## Supported Features

- Literal characters
- Dot (`.`) — matches any character except newline
- Character classes (`[a-z]`, `[^0-9]`)
- Quantifiers: `*`, `+`, `?`, `{n,m}`
- Alternation (`|`)
- Grouping with capture groups (`(...)`)
- Anchors: `^` (start), `$` (end)
- Escape sequences: `\d`, `\w`, `\s`, `\D`, `\W`, `\S`

## Building

```
zig build
```

## Running

The CLI works like a simplified grep, matching a pattern against input lines from stdin:

```
echo "hello world" | zig build run -- "h[a-z]+o"
```

Or match against a file:

```
cat myfile.txt | zig build run -- "pattern"
```

## Testing

```
zig build test
```

## Project Structure

- `src/ast.zig` — AST node types for parsed regex patterns
- `src/parser.zig` — Regex pattern parser producing an AST
- `src/nfa.zig` — NFA compiler using Thompson's construction
- `src/dfa.zig` — NFA-to-DFA converter using subset construction
- `src/matcher.zig` — Matching engine
- `src/main.zig` — CLI entry point (grep-like interface)
- `build.zig` — Build configuration
