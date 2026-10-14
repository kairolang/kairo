// --macro-debug prints each macro expansion to stderr on its own; -v is no
// longer needed (it used to go through the verbose logger and was silent
// without it). This test still passes -v and matches only the message tail.

macro two!() { 2 }
fn main() -> i32 { return two!() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only -v --macro-debug 2>&1 | %FileCheck %s --check-prefix=ON
// ON: [macro-debug] expand 'two!' depth=0
// RUN: %kairo %s --type-check-only -v 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: [macro-debug]
