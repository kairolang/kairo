ffi "c++" import "ffi_ref_return.h"

fn Widget::at(self, i: usize) -> ffi::ref<i32> { return self.items[i] }
fn Widget::at(const self, i: usize) -> i32 { return self.items[i] }
fn Widget::first(const self) -> ffi::ref<const i32> { return self.items[0] }
fn Widget::steal(self, i: usize) -> ffi::mref<i32> { return self.items[i] }
fn refs::slot(@inout a: i32) -> ffi::ref<i32> { return a }

fn main() -> i32 {
    var w = Widget()
    w.at(1) = 20
    var *p = &w.at(2)
    (*p) += 0
    var n: i32 = 1
    refs::slot(&n) += 1
    var c = w.first()
    return w.at(1) + (*p) + c + n
}

// --- lit wiring -----------------------------------------------------------
// Out-of-line definitions of members of a C++ class, and of a function in
// a C++ namespace, written with the C++ declaration's reference return
// (the `const` overload of `at` returns by value and is picked by its
// receiver). Each is emitted as the C++ declaration's definition:
// the writes through `w.at(1)`, `*p` and `refs::slot(&n)` land in the
// object, so the program returns 20 + 3 + 1 + 2 = 26. The call side types
// as it always did: an lvalue of T, `&w.at(2)` a `*i32`.
// Red on a compiler without `ffi::ref`.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA: SEMA fid {{[0-9]+}}: {{.*}}ffi_ref_return_out_of_line.k =====
// SEMA: -- out-of-line definitions --
// SEMA-NEXT: at @ 3:1 -> attached to Widget
// SEMA-NEXT: at @ 4:1 -> attached to Widget
// SEMA-NEXT: first @ 5:1 -> attached to Widget
// SEMA-NEXT: steal @ 6:1 -> attached to Widget
// SEMA-NEXT: slot @ 7:1 -> attached to refs
// SEMA: -- inferred decls --
// SEMA-DAG: p : *i32{{$}}
// SEMA-DAG: c : i32{{$}}
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR: signed int &(Widget::at)(decltype(sizeof(0)) i) {
// IR-NEXT: return this->items[i];
// IR: signed int(Widget::at)(decltype(sizeof(0)) i) const {
// IR: const signed int &(Widget::first)() const {
// IR: signed int &&(Widget::steal)(decltype(sizeof(0)) i) {
// IR-NEXT: return static_cast<signed int &&>(this->items[i]);
// IR: signed int &(refs::slot)(signed int & a) {
// IR-NEXT: return a;
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 26
