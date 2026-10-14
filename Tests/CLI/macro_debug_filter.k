// --macro-debug-filter narrows --macro-debug tracing to the macro whose name
// matches exactly: a matching filter keeps that expansion and drops the
// others, a non-matching one suppresses the trace entirely.

macro two!() { 2 }
macro three!() { 3 }
fn main() -> i32 { return two!() + three!() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only -v --macro-debug --macro-debug-filter=two 2>&1 || true; } | %FileCheck %s --check-prefix=HIT
// HIT:     [macro-debug] expand 'two!'
// HIT-NOT: [macro-debug] expand 'three!'
// RUN: { %kairo %s --type-check-only -v --macro-debug --macro-debug-filter=zz 2>&1 || true; } | %FileCheck %s --check-prefix=MISS
// MISS-NOT: [macro-debug]
