// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Bounds on a member function's own generic parameters, and `T::name` through
// an interface bound. A type body keeps its methods in the flat `methods`
// list, not in dc_decls, so a bound on a method's parameter is only seen if
// the bound passes walk that list. Every case here resolves at the template;
// the failing ones live in bounds_opaque.k.

interface Numeric {
    static fn zero() -> Self
    fn add(self, other: Self) -> Self
}

// --- free function: `::` reaches an interface static -------------------------

fn <T impl Numeric> zero_of() -> T { return T::zero() }

// --- method on a class -------------------------------------------------------

class Acc {
    fn <T impl Numeric> sum2(self, a: T, b: T) -> T { return a.add(b) }
    fn <T impl Numeric> start(self) -> T { return T::zero() }
    static fn <T impl Numeric> fresh() -> T { return T::zero() }
    fn <T> via_requires(self, a: T) -> T requires T impl Numeric { return a.add(a) }
}

// --- method on a struct ------------------------------------------------------
// A struct body holds no named functions (structures.md; S048E): its methods
// live in an `extend` block, whose methods the bound passes walk too.

struct Pt {
    var x: i32
}

extend Pt {
    fn <T impl Numeric> twice(self, a: T) -> T { return a.add(a) }
}

// --- method inside a visibility group ----------------------------------------

class Grouped {
    pub {
        fn <T impl Numeric> g(self) -> T { return T::zero() }
    }
}

// DIAG-NOT: error
// DIAG-NOT: warning

// SEMA:      member  ::zero {{.*}}-> fn zero {{.*}}[member of Numeric]
// SEMA:      member  .add {{.*}}-> fn add {{.*}}[member of Numeric]
// SEMA:      member  ::zero {{.*}}-> fn zero {{.*}}[member of Numeric]
// SEMA:      member  ::zero {{.*}}-> fn zero {{.*}}[member of Numeric]
// SEMA:      member  .add {{.*}}-> fn add {{.*}}[member of Numeric]
// SEMA:      member  .add {{.*}}-> fn add {{.*}}[member of Numeric]
// SEMA:      member  ::zero {{.*}}-> fn zero {{.*}}[member of Numeric]

// `Self` in a bound's signature is the parameter, statics included.
// SEMA: -- expression types --
// SEMA:      <tu>::zero_of
// SEMA:      CallExpr {{.*}} : T
