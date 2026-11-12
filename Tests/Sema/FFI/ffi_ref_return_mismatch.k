ffi "c++" import "ffi_ref_return.h"

fn Widget::at(self, i: usize) -> ffi::ref<i64> { return self.items[i] }
fn Widget::at(const self, i: usize) -> ffi::ref<i32> { return self.items[i] }
fn Widget::first(const self) -> i32 { return self.items[0] }
fn Widget::steal(self, i: usize) -> ffi::ref<i32> { return self.items[i] }
fn refs::slot(@inout a: i32) -> ffi::mref<i32> { return a }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// A definition or override must return exactly what C++ declares: `T&` is
// `ffi::ref<T>`, `const T&` is `ffi::ref<const T>`, `T&&` is
// `ffi::mref<T>`. Each mismatch is one SC294E whose fix-it is the right
// spelling. `at` (line 4) picks the `const` overload by its receiver,
// which returns `int` by value. Overrides: ffi_ref_return_override_mismatch.k.
// Red on a compiler without `ffi::ref`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: ffi_ref_return_mismatch.k:3:34: error [SC294E]: 'at' returns 'ffi::ref<i64>', but its C++ declaration returns 'ffi::ref<i32>'
// DIAG-NEXT: fix-it:{{.*}}:{3:34-3:47}:"ffi::ref<i32>"
// DIAG-NEXT: ffi_ref_return.h:{{[0-9]+}}:{{[0-9]+}}: note [SC294N]: the C++ declaration, whose return it must match
// DIAG: ffi_ref_return_mismatch.k:4:40: error [SC294E]: 'at' returns 'ffi::ref<i32>', but its C++ declaration returns 'i32'
// DIAG-NEXT: fix-it:{{.*}}:{4:40-4:53}:"i32"
// DIAG: ffi_ref_return_mismatch.k:5:33: error [SC294E]: 'first' returns 'i32', but its C++ declaration returns 'ffi::ref<const i32>'
// DIAG-NEXT: fix-it:{{.*}}:{5:33-5:36}:"ffi::ref<const i32>"
// DIAG: ffi_ref_return_mismatch.k:6:37: error [SC294E]: 'steal' returns 'ffi::ref<i32>', but its C++ declaration returns 'ffi::mref<i32>'
// DIAG-NEXT: fix-it:{{.*}}:{6:37-6:50}:"ffi::mref<i32>"
// DIAG: ffi_ref_return_mismatch.k:7:33: error [SC294E]: 'slot' returns 'ffi::mref<i32>', but its C++ declaration returns 'ffi::ref<i32>'
// DIAG-NEXT: fix-it:{{.*}}:{7:33-7:47}:"ffi::ref<i32>"
