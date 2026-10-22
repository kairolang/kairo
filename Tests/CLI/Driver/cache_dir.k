// --cache-dir re-roots every object path the link line names (the program's
// own object included), so two builds with different cache dirs cannot
// clobber each other's objects. --print-ld-args shows it without linking.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// REQUIRES: default-sysroot
// The dir must exist: the builtin objects are compiled into it first.
// RUN: mkdir -p %t.cd
// RUN: %kairo %s --print-ld-args --cache-dir=%t.cd | %FileCheck %s
// CHECK: {{[^ ]*}}cache_dir.k.tmp.cd/{{[^ ]*}}.o
