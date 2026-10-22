// -l / --link append libraries after the objects and before the default
// library group; static:NAME in a static link degrades to plain -lNAME, and
// dynamic:NAME cannot be satisfied there and is rejected.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: sysroot-x86_64-linux-musl
// RUN: %kairo %s --target=x86_64-linux-musl --print-ld-args -lm --link static:foo | %FileCheck %s --check-prefix=OK
// OK: -lm -lfoo
// RUN: { %kairo %s --target=x86_64-linux-musl --print-ld-args -l dynamic:bar 2>&1 || true; } | %FileCheck %s --check-prefix=DYN
// DYN: error [L001E]: -l dynamic:bar cannot be satisfied by a static link
