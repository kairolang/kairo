// A file is a script only when it has no `fn main`: with one, the program
// starts there, and a top-level statement would never run. That is an
// error at the first statement, with a note at `main`. Bindings alone are
// not statements: a `var` with a call in its initializer is an ordinary
// global, initialized before `main` as C++ does.

import std::io::println

fn load() -> i32 { return 1 }
var g = load()

println("never runs")

fn main() -> i32 { return g }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      main_and_statements.k:12:1: error [SC001E]: a file with 'fn main' cannot also have top-level statements; 'main' is where the program starts
// DIAG-NEXT: main_and_statements.k:14:1: note [SC001N]: 'main' is declared here
// DIAG-NOT: {{error|warning}}
