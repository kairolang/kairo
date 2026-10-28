// CRTP: the base is generic over the class deriving it and calls INTO that
// class through a bound -- C++'s static_cast<D*>(this)->impl(). The bound
// grants X's members; the pointer is reinterpreted, as C++ does it (a safe
// `&self as *X` is crtp_self_cast.k).
//
// The `X impl Impl` bound is checked by Kairo at `derives Mixin<Seven>`,
// once Seven is complete (D0). It used to be emitted as a requires-clause
// on Mixin's class head as well, and clang evaluates that at
// `class Seven : Mixin<Seven>`, where Seven is still incomplete: CL001E
// "constraints not satisfied for class template 'Mixin'". A primary
// record's head carries no interface bound now; the home pins it with a
// static_assert after the explicit instantiation (crtp_bounded_shapes.k).

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
