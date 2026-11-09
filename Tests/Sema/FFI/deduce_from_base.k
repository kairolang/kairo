// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 15
//
// [temp.deduct.call]/4.3: P a class template-id, A a class derived from an
// instance of it -- T deduces from that base. `get(d)` against `get(Base<T>&)`
// was SC063E "cannot convert argument of type 'Derived'", which is every
// std::getline / operator>> on a stream. And a dependent `Base<T>&&` that is
// not a forwarding reference takes no lvalue: `pick(d)` is the `&` overload,
// not a tie with the `&&` one.

ffi "c++" import "deduce_from_base.h"

fn main() -> i32 {
    var d: Derived
    d.v = 4
    // get: 4 + 1 = 5; pick(d): 10
    return get(&d) + pick(&d)
}

// DIAG-NOT: error
