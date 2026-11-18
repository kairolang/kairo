// ConstraintExtraction and ChainBinding run after the late fold (EVAL.md
// 4.2b): the bounds filed and the member steps bound are the kept branch's.
// The kept method's `a.add(a)` binds through its own `requires`; the
// discarded one names a member no bound provides, which would be an error if
// anything after the fold still saw it. The two share one signature and one
// bound, so R(a) would also call them one member declared twice.
struct Plain { var x: i32 }

interface Numeric {
    static fn zero() -> Self
    fn add(self, other: Self) -> Self
}

class Acc {
    eval if is_trivially_copyable!(Plain) {
        fn <T> twice(self, a: T) -> T requires T impl Numeric { return a.add(a) }
    } else {
        fn <T> twice(self, a: T) -> T requires T impl Numeric { return a.no_such_member(a) }
    }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
