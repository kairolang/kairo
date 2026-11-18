// A write through a `*const T` got no Kairo diagnostic, only clang's
// CL001E. pointers.mdx, "Const Pointers": `*c = 10` through a `*const i32`
// is an error. The `for *x` binder over a const C++ range is a `*const T`
// too, so a write through it is the same error.
ffi "c++" import "set"

fn main() -> i32 {
    var x: i32 = 1
    var p: *const i32 = &x
    *p = 9
    *p += 1
    var s: cxx::std::set<i32>
    s.insert(3)
    for *e in s {
        *e = 9
    }

    var q: *i32 = &x
    *q = 2
    return x
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: const_pointee_write_rejected.k:10:5: error [SC071E]: cannot assign to '*p': 'p' points to const
// CHECK: const_pointee_write_rejected.k:9:9: note [I900N]: 'p' declared as a pointer to const here
// CHECK: const_pointee_write_rejected.k:11:5: error [SC071E]: cannot update '*p': 'p' points to const
// CHECK: const_pointee_write_rejected.k:15:9: error [SC071E]: cannot assign to '*e': 'e' points to const
// CHECK: const_pointee_write_rejected.k:14:10: note [I900N]: 'e' declared as a pointer to const here
// CHECK-NOT: error
