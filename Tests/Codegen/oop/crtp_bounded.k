// CRTP: the base is generic over the class deriving it and calls INTO that
// class through a bound -- C++'s static_cast<D*>(this)->impl(). The bound
// grants X's members; the pointer is reinterpreted, as C++ does it (a safe
// `&self as *X` is crtp_self_cast.k).
//
// XFAIL: *
// Waiting on codegen deferring a bound that names the class being defined.
// Kairo type-checks this. The `X impl Impl` bound is lowered to a C++
// requires-clause on Mixin, and clang evaluates it at
// `class Seven : Mixin<Seven>`, where Seven is still incomplete: CL001E
// "constraints not satisfied for class template 'Mixin'". The bound must be
// checked once X is complete (on the members, or after the class), not on
// the base-specifier.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

interface Impl {
    fn value(const self) -> i32
}

class <X derives Mixin<X> impl Impl> Mixin {
    fn doubled(const self) -> i32 {
        unsafe {
            var d = &self as unsafe *const X
            return d->value() * 2
        }
    }
}

class Seven derives Mixin<Seven> impl Impl {
    fn value(const self) -> i32 { return 7 }
}

class Five derives Mixin<Five> impl Impl {
    fn value(const self) -> i32 { return 5 }
}

fn main() -> i32 {
    var s = Seven()
    var f = Five()
    return s.doubled() + f.doubled()            // 14 + 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 24
