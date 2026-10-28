// What the CRTP downcast (`&self as *X` through `X derives Mixin<X>`) does
// NOT extend to: only a `derives` bound that is the source record, or
// reaches it, relates a parameter to a record. Everything else is the
// unrelated-pointer error (SC091E) it always was, and a bound that proves
// the relation still cannot drop `const` (SC030E). crtp_cast_bound.k is the
// working side.

class Other { }

// No bound at all: nothing says X is a NoBound<X>.
class <X> NoBound {
    fn f(self) -> *X { return &self as *X }
}

// The bound is on a different parameter.
class <X, Y derives OtherParam<X, Y>> OtherParam {
    fn f(self) -> *X { return &self as *X }
}

// A `derives` bound naming an unrelated record.
class <X derives Other> Wrong {
    fn f(self) -> *X { return &self as *X }
}

// Proven, but from a const self to a mutable pointer.
class <X derives Drop<X>> Drop {
    fn f(const self) -> *X { return &self as *X }
}

// A non-record pointee is never related to a parameter.
class <X derives Ints<X>> Ints {
    pub var v: i32 = 0
    fn f(self) -> *X { return &self.v as *X }
}

// An `impl` bound grants members, not a base: still unrelated.
interface Marker { fn mark(const self) -> i32 }
class <X impl Marker> ImplOnly {
    fn f(self) -> *X { return &self as *X }
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:12:31: error [SC091E]: pointer cast between unrelated types '*NoBound<X>' and '*X'; use 'as unsafe *' to reinterpret
// DIAG: {{.*}}:17:31: error [SC091E]: pointer cast between unrelated types '*OtherParam<X, Y>' and '*X'; use 'as unsafe *' to reinterpret
// DIAG: {{.*}}:22:31: error [SC091E]: pointer cast between unrelated types '*Wrong<X>' and '*X'; use 'as unsafe *' to reinterpret
// DIAG: {{.*}}:27:37: error [SC030E]: cast from '*const Drop<X>' to '*X' drops 'const' from the pointee 'const Drop<X>'
// DIAG-NEXT: {{.*}}:27:37: note [I900N]: 'as' can add 'const' to a pointee, never remove it, and cannot add it on one level while removing it on another; that is a reinterpret: 'as unsafe *T' inside an 'unsafe' block
// DIAG: {{.*}}:33:31: error [SC091E]: pointer cast between unrelated types '*i32' and '*X'; use 'as unsafe *' to reinterpret
// DIAG: {{.*}}:39:31: error [SC091E]: pointer cast between unrelated types '*ImplOnly<X>' and '*X'; use 'as unsafe *' to reinterpret
// END-GENERATED-CHECKS(DIAG)
