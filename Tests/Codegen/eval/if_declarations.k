// A top-level `eval if` selects between DECLARATIONS (eval.mdx, Eval If):
// the taken branch's `eval` constants and functions are declared at file
// scope, the others are discarded.
//
// XFAIL: *
// Ticket "[Sema] Declarations inside a top-level `eval if` stay
// branch-local" (private/IMPORTANT/TICKETS.TXT, 2026-10-26). Today the
// `eval if` is an ordinary ConditionalStmt whose branches are block scopes,
// so CACHE_LINE and line_bytes are R020E undeclared at their uses. Needs
// the eval-if semantics: fold the condition, splice the taken branch's
// declarations into the enclosing scope. When it XPASSes, delete the XFAIL
// -- the run below is already the real assertion.

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
