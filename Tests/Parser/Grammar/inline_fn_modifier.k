// `inline` is a leading function modifier, not only the `inline "c++"` ffi
// block introducer. It must work at decl scope and in type/extend bodies.
// RUN: %kairo %s --syntax-only 2>&1 | %FileCheck %s --check-prefix=OK --allow-empty
// OK-NOT: error
inline fn free_fn() -> i32 { return 1 }

class C {
    var v: i32
    inline fn get(self) -> i32 = self.v
    inline static fn make() -> i32 { return 0 }
}

struct <T> S { var v: T }

extend <T> S {
    inline fn get(self) -> T = self.v
}
