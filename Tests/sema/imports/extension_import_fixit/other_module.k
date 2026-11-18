import lib
fn main() -> i32 { return 3.thrice() + lib::shown() - 4 }

// --- lit wiring -----------------------------------------------------------
// lib/inner.k is a `priv import` of lib/module.k, a file of another
// module that the module does not export, an implementation detail of it.
// The fix-it offers only what the module exports, so there is none here: a
// note says the module does not export the file.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error [" --implicit-check-not=fix-it
// CHECK: other_module.k:2:29: error [R025E]: no member named 'thrice' in 'i32'
// CHECK: inner.k:1:5: note [I900N]: an extension of 'i32' in 'inner.k' declares 'thrice'; import it to use it
// CHECK: note [I900N]: 'inner.k' is not exported by module 'lib': its module.k does not `pub import` it
