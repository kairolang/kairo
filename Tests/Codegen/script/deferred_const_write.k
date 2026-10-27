// XFAIL: *
// Waiting on ConstChecking (Sema.k, `TODO(sema): ConstChecking`): no pass
// rejects a write to a `const` binding yet, in a script or anywhere else
// (`const x = 1; x = 2` in a function body is accepted too; TICKETS.TXT).
// When this XPASSes, delete these five lines and fix the line number below.
//
// A deferred `const` keeps its constness at the source level: its storage
// is writable only because main assigns it at its line, and an assignment
// the user writes is still an error.

fn load() -> i32 { return 5 }

const LIMIT: i32 = load()
LIMIT = 6

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG: deferred_const_write.k:14:{{[0-9]+}}: error [{{[A-Z]+[0-9]+E}}]:
