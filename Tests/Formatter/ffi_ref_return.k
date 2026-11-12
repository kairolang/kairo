// RUN: %kfmt --stdout %s | diff -u %S/Expected/ffi_ref_return.k -
// RUN: %kfmt --check %S/Expected/ffi_ref_return.k
//
// `ffi::ref<T>`, `ffi::ref<const T>` and `ffi::mref<T>` (P872) print back
// as written, inside the usual parameter layout and with the `;` dropped.

ffi "c++" import "widget.h"

fn Widget::at(self, i: usize) -> ffi::ref<i32> { return self.items[i]; }
fn Widget::first(const self) -> ffi::ref<const i32> { return self.items[0]; }
fn Widget::steal(self, i: usize) -> ffi::mref<Vector<i32>> { return self.lists[i]; }
fn Widget::a_member_with_a_long_name(self, first_index: usize, second_index: usize) -> ffi::ref<const i32> {
    return self.items[first_index];
}
