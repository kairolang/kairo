// A nested type named through an alias of a generic Kairo instance
// (`type Q = TQ<i32>; Q::Flags`): the instance's own table is empty
// until M2 fills it, so the walk reads the pattern, as `TQ<i32>::Flags` does.

class <T> TQ {
    pub type Flags = u32
    pub class Inner { pub var v: T }
    pub var f: Flags
}
type TypeQualifier = TQ<i32>

fn g(a: TypeQualifier::Flags, b: TypeQualifier::Inner) -> TypeQualifier::Flags { return a }

class Q {
    type TQA = TQ<i32>
    pub var x: TQA::Flags
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: R025E
// CHECK-NOT: error
