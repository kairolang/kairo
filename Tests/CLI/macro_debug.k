// --macro-debug logs each macro expansion, but through the verbose logger, so
// it only shows with -v; without the flag nothing is logged. Only the message
// tail is matched, the log prefix carries timestamps.

macro two!() { 2 }
fn main() -> i32 { return two!() }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --type-check-only -v --macro-debug 2>&1 | %FileCheck %s --check-prefix=ON
// ON: [macro-debug] expand 'two!' depth=0
// RUN: %kairo %s --type-check-only -v 2>&1 | %FileCheck %s --check-prefix=OFF
// OFF-NOT: [macro-debug]
