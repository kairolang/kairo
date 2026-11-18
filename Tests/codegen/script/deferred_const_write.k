//
// A deferred `const` keeps its constness at the source level: its storage
// is writable only because main assigns it at its line, and an assignment
// the user writes is still an error.

fn load() -> i32 { return 5 }

const LIMIT: i32 = load()
LIMIT = 6

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: deferred_const_write.k:9:{{[0-9]+}}: error [SC071E]: cannot assign to 'LIMIT': it is const
