// --macro-debug prints its expansion trace to stderr on its own; it must not
// need -v. The filter narrows the trace to one macro (name without the `!`).

macro two!() { 2 }
macro three!() { 3 }
fn main() -> i32 { return two!() + three!() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only --macro-debug 2>&1 | %FileCheck %s --check-prefix=ON
// ON: [macro-debug] expand 'two!' depth=0
// ON: [macro-debug] expand 'three!' depth=0
// RUN: %kairo %s --type-check-only --macro-debug --macro-debug-filter=three 2>&1 | %FileCheck %s --check-prefix=FILT
// FILT-NOT: expand 'two!'
// FILT: [macro-debug] expand 'three!'
// RUN: %kairo %s --type-check-only 2>&1 | %FileCheck %s --check-prefix=OFF --allow-empty
// OFF-NOT: [macro-debug]
