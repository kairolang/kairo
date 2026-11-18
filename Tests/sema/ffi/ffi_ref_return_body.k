ffi "c++" import "ffi_ref_return.h"

var g_cell: i32 = 0

fn Widget::at(self, i: usize) -> ffi::ref<i32> { var copy = self.items[i]; return copy }
fn Widget::first(const self) -> ffi::ref<const i32> { return self.items[0] + 1 }
fn Widget::steal(self, i: usize) -> ffi::mref<i32> { var arr: [i32; 2] = [1, 2]; return arr[0] }
fn refs::slot(@inout a: i32) -> ffi::ref<i32> { return 5 }

class D derives Base {
    pub var mine: i32 = 1
    override fn pick(self) -> ffi::ref<i32> { return g_cell }
    override fn peek(const self) -> ffi::ref<const i32> { var w = self.mine; return (w) }
    override fn take(self) -> ffi::mref<i32> { return self.mine }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// The body of a reference return returns a place that outlives the call:
// not a temporary (lines 6, 8), not a local or a part of one (5, 7, 13).
// A global (12) and a field of self (14) are fine. Red on a compiler
// without `ffi::ref`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: ffi_ref_return_body.k:5:83: error [SC295E]: 'copy' is a local variable, so the reference returned would outlive it
// DIAG-NEXT: ffi_ref_return_body.k:5:50: note [SC295N]: 'copy' is declared here and ends with the call
// DIAG: ffi_ref_return_body.k:6:62: error [SC295E]: a reference return returns a place, and this is a temporary: the caller would be left a reference to nothing
// DIAG: ffi_ref_return_body.k:7:89: error [SC295E]: 'arr' is a local variable, so the reference returned would outlive it
// DIAG: ffi_ref_return_body.k:8:56: error [SC295E]: a reference return returns a place, and this is a temporary
// DIAG: ffi_ref_return_body.k:13:86: error [SC295E]: 'w' is a local variable, so the reference returned would outlive it
