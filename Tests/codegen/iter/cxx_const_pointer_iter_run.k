// A pointer binder over a C++ range reached read-only (a field of a const
// parameter) whose iterator is a raw pointer: `begin() const` returns a
// `const T*`, so `*x` and `const *x` bind a pointer to const. Over a
// mutable range the same loop binds `*T` and writes through it.

ffi "c++" import "vector"
ffi "c++" import "cxx_const_pointer_iter.h"

struct Spec {
    var a: usize = 0
}

struct Ctx {
    var ptrs: cp::PtrVec<Spec>
    var vec:  cxx::std::vector<Spec>
}

class Walk {
    var base: usize = 0

    struct Inner {
        var specs: cp::PtrVec<Spec>
    }

    pub fn sum(self, const c: Self::Inner) -> usize {
        var t = self.base
        for const *s in c.specs {
            t += s->a
        }

        return t
    }
}

fn sum_const(const c: Ctx) -> usize {
    var t: usize = 0
    for const *s in c.ptrs {
        t += s->a
    }

    for *s in c.ptrs {
        t += s->a
    }

    for const *s in c.vec {
        t += s->a
    }

    for *s in c.vec {
        t += s->a
    }

    return t
}

fn sum_default(c: Ctx) -> usize {
    var t: usize = 0
    for const *s in c.ptrs {
        t += s->a
    }

    for *s in c.ptrs {
        t += s->a
    }

    return t
}

fn bump(@inout c: Ctx) {
    for *s in c.ptrs {
        s->a += 10
    }
}

fn main() -> i32 {
    var c = Ctx{}
    c.ptrs.push_back(Spec { a: 1 })
    c.ptrs.push_back(Spec { a: 2 })
    c.vec.push_back(Spec { a: 4 })
    var t = sum_const(c) // 3 + 3 + 4 + 4 = 14
    t += sum_default(c)  // 20
    bump(&c)             // ptrs: 11 12
    t += sum_default(c)  // 66
    var w = Walk{}
    var i = Walk::Inner{}
    i.specs.push_back(Spec { a: 5 })
    t += w.sum(i) // 71
    return t as i32
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 71
