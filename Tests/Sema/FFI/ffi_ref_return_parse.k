ffi "c++" import "ffi_ref_return.h"

fn Widget::at(self, i: usize) -> ffi::reference<i32> { return self.items[i] }
fn Widget::first(const self) -> ffi::ref { return self.items[0] }
fn Widget::steal(self, i: usize) -> ffi::mref<i32, i64> { return self.items[i] }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// After `ffi::` a type is `ref<T>` or `mref<T>`: one S092E for any other
// name, a missing argument list, or more than one argument.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: ffi_ref_return_parse.k:3:39: error [S092E]: expected 'ref' or 'mref' after 'ffi::'; a C++ reference return is written 'ffi::ref<T>', 'ffi::ref<const T>' or 'ffi::mref<T>'
// DIAG: ffi_ref_return_parse.k:4:38: error [S092E]: 'ffi::ref' takes the referenced type: 'ffi::ref<T>'
// DIAG: ffi_ref_return_parse.k:5:37: error [S092E]: 'ffi::mref' takes exactly one type, the referenced one: 'ffi::mref<T>'
