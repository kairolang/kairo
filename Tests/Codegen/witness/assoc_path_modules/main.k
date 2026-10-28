// witness/assoc_path_modules/main.k -- exit 47
// The general associated-type path across three TUs: the interfaces and the
// bounded bodies naming `T::Item::Inner`, `T::Item::Inner::make()` and the
// generic `T::Map<i32>` (shapes), the conformers and their aliases, a
// generic one included (impls), and the instantiating module (this one).
// The bound cache an associated type carries, and the witness's member
// alias template, are read in a TU other than the one that formed them.
import shapes
import impls::*
fn main() -> i32 {
    return shapes::deep(Bank()) + shapes::round(Bank(), 40)   // (5 + 2) + 40
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 47
