// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
//
// An imported enum's enumerator is spelled through its enum's C++ name.
// It does not go out under the header's module, `::enum_spelling::ns::E::b`
// (and `::memory_order::std::memory_order::relaxed` for libc++'s), which
// names nothing in C++, so any use failed in clang (CL001E).

ffi "c++" import "enum_spelling.h"
ffi "c++" import "atomic"

fn main() -> i32 {
    var e = ns::E::b
    var u = ns::U::u2
    var g = G::g3
    var a: cxx::std::#atomic<i32>
    a.store(2, cxx::std::memory_order::relaxed)
    var n = a.load(cxx::std::memory_order::acquire)
    // 1 + 2 + 3 + 2 - 1 = 7
    return (e as i32) + (u as u32 as i32) + (g as i32) + n - 1
}

// IR: = ::ns::E::b;
// IR: = ::ns::U::u2;
// IR: = ::G::g3;
// IR: ::std::{{.*}}memory_order::relaxed
