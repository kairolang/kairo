// Code after a top-level `return` in a script never runs, and is warned
// about as it would be in a function body (SC003W, ControlFlowAnalysis).
// The top level is not one block in the tree, so the pass walks the
// script's statements as one: a declaration between them (`helper`) is not
// code and is never part of the reported region, so the fix-it that deletes
// the region cannot delete it; a binding whose initializer is constant is a
// declaration too, a deferred one is a line that never runs. Nothing
// ScriptLowering mints warns: it runs after the checks, so the `return 0`
// it appends after the user's `return` is not reported.

import std::io::println

fn load() -> i32 { return 3 }

println("start")
return
println("dead one")
println("dead two")

fn helper() -> i32 { return 1 }

const K: i32 = 2
var late = load()
println(f"{helper()} {K} {late}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      unreachable_top_level.k:17:1: warning [SC003W]: unreachable code; the statement above always transfers control out of this block
// DIAG-NEXT: fix-it:{{.*}}:{17:1-18:20}:""
// DIAG-NEXT: unreachable_top_level.k:16:1: note [{{[A-Z0-9]+}}]: any code after this 'return' is never run
// DIAG-NOT: {{error|warning}}
// DIAG:      unreachable_top_level.k:23:1: warning [SC003W]: unreachable code; the statement above always transfers control out of this block
// DIAG-NEXT: fix-it:{{.*}}:{23:1-24:34}:""
// DIAG-NEXT: unreachable_top_level.k:16:1: note [{{[A-Z0-9]+}}]: any code after this 'return' is never run
// DIAG-NOT: {{error|warning}}
//
// The program still builds and runs: the warning is only a warning.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>/dev/null
// RUN: %t.exe | %FileCheck %s --check-prefix=OUT --match-full-lines
// OUT:      start
// OUT-NOT:  {{.}}
