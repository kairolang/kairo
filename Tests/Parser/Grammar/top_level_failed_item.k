// A top-level item that fails must not end the file silently. The
// top-level loop stopped at the first null from the declaration parser, so
// everything after it was dropped with no error:
//
//   - `inline "c++"` with no block: S056E now, and both functions after it
//     are still parsed;
//   - `fn` alone on a line before a function: the closure parse skipped
//     `fn main()` to the `->` without a word (the body was then a closure
//     with no name); S047E now names the skipped token;
//   - `inline "c++" { }` at the top level: parse_decl declines it, and it
//     goes to the statement path (which owns inline blocks) instead of
//     ending the loop, so `fn after` is parsed.
//
// The loop also reports S063E for any item that fails with no diagnostic
// of its own, then resumes at the next line; no input here reaches that
// net, it is the backstop for paths nobody has found yet.

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %S/Inputs/top_level_failed_item/inline_no_brace.k --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOBRACE
// NOBRACE: inline_no_brace.k:1:1: error [S056E]: expected '{' to begin an inline foreign block
// RUN: { %kairo %S/Inputs/top_level_failed_item/inline_no_brace.k --syntax-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=NOBRACE-AST
// NOBRACE-AST: fn a() {}
// NOBRACE-AST-NEXT: fn b() {}

// RUN: { %kairo %S/Inputs/top_level_failed_item/fn_then_fn.k --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=FNFN
// FNFN: fn_then_fn.k:2:1: error [S047E]: unexpected 'fn' in a closure signature; expected '(' and the parameters, '|' and the captures, '->', '{' or '='

// RUN: { %kairo %S/Inputs/top_level_failed_item/inline_block_top.k --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=BLOCK --allow-empty
// BLOCK-NOT: error
// RUN: { %kairo %S/Inputs/top_level_failed_item/inline_block_top.k --syntax-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=BLOCK-AST
// BLOCK-AST: inline "c++" { ... }
// BLOCK-AST-NEXT: fn after() {}
