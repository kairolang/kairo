// --force-include names a file the driver must load before the entry file.
// A path that does not exist is a driver-level fatal (no source location),
// so a typo is reported as such instead of the flag being silently ignored.
// Only the missing-file behaviour is pinned; whether a force-included file's
// symbols reach the entry TU's scope is not asserted here.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --force-include=/nonexistent/x.k 2>&1 || true; } | %FileCheck %s
// CHECK: fatal [I005F]: no such file: '/nonexistent/x.k'
