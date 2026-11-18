ffi "c++" import "ffi_define_foreign.h"

fn Counter::get(self) -> i32 { return self.base }
fn Counter::add(const self, extra: i32) -> i32 { return self.base + extra }
static fn Counter::twice(x: i32) -> i32 { return x * 2 }
fn calc::inc(a: i32) -> i32 { return a + 1 }

fn main() -> i32 {
    var c = Counter()
    // C++: 1 + 101 + 6 + 2 = 110; Kairo: 1 + 2 = 3
    return from_cxx(&c) + c.get() + calc::inc(1)
}

// --- lit wiring -----------------------------------------------------------
// An out-of-line definition of a C++-declared member or namespace function
// is emitted as THAT function's definition: at global scope, under
// the C++ name, with the declaration's own parameter types (`const int&`
// stays `const int&` though Kairo reads `extra: i32`) and no `noexcept` the
// declaration lacks. Before, the members were never emitted (L002E
// "undefined symbol: Counter::get()") and `calc::inc` went out as a new
// function in a `<module>::calc` namespace with names read through the
// header's table.
//
// RUN: { %kairo %s --print-ir -o /dev/null 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR-NOT: namespace ffi_define_foreign::calc
// IR: signed int(Counter::get)() {
// IR-NEXT: return this->base;
// IR: signed int(Counter::add)(const signed int & extra) const {
// IR: signed int(Counter::twice)(signed int x) {
// IR: signed int(calc::inc)(signed int a) {
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 113
