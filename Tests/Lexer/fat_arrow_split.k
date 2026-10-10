// `a >=> b` lexes as `a` `>` `=>` `b` (no prefix `>` exists, so `>=` `>` could
// never have been valid). The one error is the missing right operand of the
// `>`: the token found there is the `=>` right after it. Before the split this
// read as `a >= > b` and the error was a stray `>` after `>=`.

fn f(a: i32, b: i32) {
    var t = a >=> b
// DIAG:     fat_arrow_split.k:[[@LINE-1]]:16: error [S052E]: expected expression, found '=>'
// DIAG-NOT: found '>'
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only 2>&1 1>/dev/null || true; } | %FileCheck %s --check-prefix=DIAG
