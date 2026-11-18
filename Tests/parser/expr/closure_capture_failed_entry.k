// A capture list whose only entry fails to parse is NOT the empty list.
// `| |` and `||` capture nothing; `|3|` is S047E, and the closure keeps no
// "captures nothing" marking. It is not keyed on the parsed list being
// empty: a failed entry would read as `||` and every free name in the body would be
// a follow-on "not captured" error under the syntax error.

fn main() -> i32 {
    var y = 2
    var bad = fn () |3| -> i32 { return y }
    var spaced = fn () | | -> i32 { return 1 }
    return bad() + spaced()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: closure_capture_failed_entry.k:9:22: error [S047E]: expected capture name or '*' in capture list
// DIAG-NOT: not captured

// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE: VariableDecl var bad
// TREE-NOT: CaptureList
// TREE: VariableDecl var spaced
// TREE-NEXT: ClosureExpr
// TREE-NEXT: CaptureList (explicit no capture)
