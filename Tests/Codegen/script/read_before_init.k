// A read of a deferred script variable that main's own order proves comes
// before its line is a compile error, not a runtime abort: in main's
// statements (`early`), in the variable's own initializer (`self_ref`), and
// through a DIRECT call from main of a function that reads it on every path
// (`show`). A function that reads it only on some path (`maybe`) is left to
// the runtime guard, and so is a call made after the line (`late`).

import std::io::println

fn load() -> i32 { return 1 }
fn show() { println(f"{late}") }
fn maybe(b: bool) { if b { println(f"{late}") } }

println(f"{early}")
var early = load()
var self_ref: i32 = self_ref + load()
show()
maybe(false)
var late = load()
show()

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      read_before_init.k:14:12: error [SC001E]: script variable 'early' is read before the line that gives it a value has run
// DIAG-NEXT: read_before_init.k:15:1: note [SC001N]: 'early' is given its value here
// DIAG-NOT: {{error|warning}}
// DIAG:      read_before_init.k:16:21: error [SC001E]: script variable 'self_ref' is read before the line that gives it a value has run
// DIAG-NEXT: read_before_init.k:16:1: note [SC001N]: 'self_ref' is given its value here
// DIAG-NOT: {{error|warning}}
// DIAG:      read_before_init.k:17:1: error [SC001E]: 'show' reads script variable 'late' before the line that gives it a value has run
// DIAG-NEXT: read_before_init.k:11:24: note [SC001N]: 'show' reads 'late' here
// DIAG-NEXT: read_before_init.k:19:1: note [SC001N]: 'late' is given its value here, later
// DIAG-NOT: {{error|warning}}
