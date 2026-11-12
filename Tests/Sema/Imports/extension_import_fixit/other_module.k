import lib
fn main() -> i32 { return 3.thrice() + lib::shown() - 4 }

// --- lit wiring -----------------------------------------------------------
// P945: lib/inner.k is a `priv import` of lib/module.k, a file of another
// module that the module does not export. Importing it directly is not a fix
// this file should be offered, so there is no fix-it: a note says where its
// extensions come from instead.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not=fix-it
// CHECK: other_module.k:2:29: error [R025E]: no member named 'thrice' in 'i32'
// CHECK: inner.k:1:5: note [I900N]: an extension of 'i32' in 'inner.k' declares 'thrice'; import it to use it
// CHECK: note [I900N]: 'inner.k' is a file of module 'lib': from outside it, its extensions come through what the module re-exports (its module.k's `pub import`s), not by importing the file
