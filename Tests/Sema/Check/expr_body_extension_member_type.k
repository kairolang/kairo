// The body of an expression-bodied extension member is checked against the
// member's return type like any other body, so a literal of the wrong type
// is rejected where the member is declared.

interface Named {
    fn tag(const self) -> i32
}

class M {
    pub var base: i32 = 0
    pub fn M(self) { }
}

extend M impl Named {
    pub fn tag(const self) -> i32 = "seven"
}

fn <T impl Named> get(a: T) -> i32 { return a.tag() }

fn main() -> i32 {
    return get(M())
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: expr_body_extension_member_type.k:15:37: error [SC028E]: cannot convert 'string' to 'i32'
