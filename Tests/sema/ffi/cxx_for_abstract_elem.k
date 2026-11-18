// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// `for x in r` over a C++ range of an abstract class is a Kairo error
// at the binding, with the `for *x` fix-it, not clang's "variable type is
// an abstract class" in emitted code. By pointer: cxx_for_abstract_elem_ptr.k.
// CHECK: cxx_for_abstract_elem.k:14:9: error [SC001E]: cannot bind 'x' by value: 'Shape' is abstract; iterate by pointer
// CHECK-NEXT: fix-it:{{.*}}cxx_for_abstract_elem.k":{14:9-14:9}:"*"
// CHECK-NEXT: cxx_for_abstract_elem.h:4:8: note [I900N]: 'Shape' is declared abstract here
// CHECK-NOT: CL001E
ffi "c++" import "cxx_for_abstract_elem.h"

fn main() -> i32 {
    var r = Shapes()
    var n: i32 = 0
    for x in r {
        n += x.area()
    }
    return n
}
