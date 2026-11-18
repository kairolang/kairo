// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 10
//
// `ns::Name<args>::member` names the INSTANCE, as `Name<args>::member` does
// at the head of a chain. The `::` step anchored the pattern instead, so a
// member the instance gets from a base that depends on its arguments was
// R025E "no member named 'value'" -- every standard trait's `::value`
// (`cxx::std::is_same<A, B>::value`), since libc++ derives them from
// integral_constant over a builtin of the arguments.

ffi "c++" import "generic_scope_step.h"
ffi "c++" import "type_traits"

fn main() -> i32 {
    var n = 0
    if q::Size4<i32>::value { n += 1 }
    if !q::Size4<i64>::value { n += 1 }
    if q::Trivial<i32>::value { n += 1 }
    if cxx::std::is_same<i32, i32>::value { n += 0 }
    if cxx::std::is_trivially_destructible<i32>::value { n += 0 }
    return n + q::Echo<i32>::value
}

// DIAG-NOT: error
