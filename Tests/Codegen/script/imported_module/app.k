// Only the program's root file is a script. app.k is the root and may run
// statements; lib.k is imported, so its top-level statement is an error,
// reported at the statement in lib.k. app.k itself is fine.

import lib::*
import std::io::println

println(f"app {helper()}")

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG:      lib.k:9:1: error [SC001E]: a top-level statement runs only in the program's root file; this file is imported as a module
// DIAG-NEXT: lib.k:9:1: note [SC001N]: move it into a function, or into the file the program starts from
// DIAG-NOT: {{error|warning}}
