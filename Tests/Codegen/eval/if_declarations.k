// A top-level `eval if` selects between DECLARATIONS (eval.mdx, Eval If):
// the taken branch's `eval` constants and functions are declared at file
// scope, the others are discarded (EvalIfFolding, EVAL.md §4). Before the
// fold, both branches were block scopes and CACHE_LINE / line_bytes were
// R020E undeclared at their uses.

eval WIDE = true

eval if WIDE {
    eval CACHE_LINE = 64
    fn line_bytes() -> i32 { return 1 }
} else {
    eval CACHE_LINE = 128
    fn line_bytes() -> i32 { return 2 }
}

fn main() -> i32 {
    return CACHE_LINE + line_bytes()            // 64 + 1
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 65
