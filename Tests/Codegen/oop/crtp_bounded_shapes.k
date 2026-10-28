// A CRTP base whose parameter carries an interface bound, beyond
// crtp_bounded.k's one shape. Kairo checks `X impl I` at the use, once X is
// complete (D0); the C++ class template carries no `requires` on its head,
// because clang would check it at `class S : Mixin<S>`, where S is still
// incomplete. The home TU pins the bound with a static_assert after the
// explicit instantiation instead.
//
//  - a conformer that is structural (no `impl Impl` written);
//  - two bounded mixins on one class, the second at a nonzero offset;
//  - a generic record with an ordinary (non-CRTP) bound keeps working.

interface Valued {
    fn value(const self) -> i32
}

interface Named {
    fn id(const self) -> i32
}

class <X derives Doubler<X> impl Valued> Doubler {
    fn doubled(const self) -> i32 {
        return (&self as *const X)->value() * 2
    }
}

class <X derives Tagger<X> impl Named> Tagger {
    pub var tag: i32 = 1000
    fn tagged(const self) -> i32 {
        return self.tag + (&self as *const X)->id()
    }
}

// Structural: Valued and Named are met by the members, not declared.
class Both derives Doubler<Both>, Tagger<Both> {
    pub var v: i32 = 21
    fn value(const self) -> i32 { return self.v }
    fn id(const self) -> i32 { return 7 }
}

class <T impl Valued> Box {
    pub var t: T
    fn get(const self) -> i32 { return self.t.value() }
}

class Lit {
    pub var n: i32
    fn Lit(self, n: i32) { self.n = n }
    fn value(const self) -> i32 { return self.n }
}

fn main() -> i32 {
    var b = Both()
    var x = Box<Lit> { t: Lit(5) }
    return b.doubled() + b.tagged() - 1000 + x.get()    // 42 + 7 + 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// The heads are unconstrained; the bounds are asserted per instance at home.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: requires{{.*}}class Doubler
// CXX-NOT: requires{{.*}}class Box
// CXX: template class{{ ?}}::crtp_bounded_shapes::Doubler<{{ ?}}::crtp_bounded_shapes::Both>;
// CXX-NEXT: static_assert({{ ?}}::crtp_bounded_shapes::Valued_c<{{ ?}}::crtp_bounded_shapes::Both>,
// CXX: template class{{ ?}}::crtp_bounded_shapes::Tagger<{{ ?}}::crtp_bounded_shapes::Both>;
// CXX-NEXT: static_assert({{ ?}}::crtp_bounded_shapes::Named_c<{{ ?}}::crtp_bounded_shapes::Both>,
// CXX: template class{{ ?}}::crtp_bounded_shapes::Box<{{ ?}}::crtp_bounded_shapes::Lit>;
// CXX-NEXT: static_assert({{ ?}}::crtp_bounded_shapes::Valued_c<{{ ?}}::crtp_bounded_shapes::Lit>,

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 54
