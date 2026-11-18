// XFAIL: *
// `null as *Animal?` ends in an internal compiler error in EmitIR ("`as` on a
// record value; OperatorLowering owns op as / ctor casts") instead of either
// compiling or a diagnostic. nullables.mdx (Nullable Types): a bare `null` is
// a nullable's null and never converts to a pointer, so this cast needs an
// error; no input may reach an internal compiler error.

class Animal { pub virtual fn name(self) -> i32 { return 1 } pub fn Animal(self) { } }

fn main() -> i32 {
    var *a? = null as *Animal?
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='internal compiler error'
