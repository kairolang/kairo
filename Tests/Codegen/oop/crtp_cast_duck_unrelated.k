// A duck (`: type`) CRTP downcast at an instance whose T does NOT derive
// the mixin: Kairo accepts the body (D1: C++ checks a `: type` body per
// instance), and the static_cast it wrote is clang's error at the
// instance -- never a reinterpret that would read a U out of a Holder.
// crtp_cast_duck.k is the working side.

class <T: type> M {
    fn d(self) -> *T { return &self as *T }
}

class U {
    pub var u: i32 = 1
}

class Holder derives M<U> {
}

fn main() -> i32 {
    var h = Holder()
    return h.d()->u
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: { %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: error [CL001E]: static_cast from '{{.*}}M<{{.*}}U> *' to '{{.*}}U *', which are not related by inheritance, is not allowed
// CXX: note [I900N]: in instantiation of member function '{{.*}}M<{{.*}}U>::d' requested here
