// A fatal in a batch aborts the whole batch whether or not --cmax-errors has
// already been reached: the cap limits what is shown, never what is counted.
// The fatal here is an input that does not exist (the one fatal a later input
// can raise before any TU is processed), so the property pinned is that the
// cap neither hides the fatal's effect nor lets the other inputs go on into
// Sema.

fn main() -> i32 { var a: i32 = u1; var b: i32 = u2; return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d
// RUN: printf 'pub fn g() -> i32 { return 1 }\n' > %t.d/ok.k
// RUN: { %kairo %s %t.d/missing.k %t.d/ok.k --type-check-only --print-sema --cmax-errors=1 2>&1 || true; } | %FileCheck %s --implicit-check-not='-- sema:'
// CHECK: fatal [I005F]: no such file: '{{.*}}missing.k'
// RUN: not %kairo %s %t.d/missing.k %t.d/ok.k --type-check-only --cmax-errors=1 2> /dev/null
// The same batch with no cap fails the same way.
// RUN: not %kairo %s %t.d/missing.k %t.d/ok.k --type-check-only 2> /dev/null
