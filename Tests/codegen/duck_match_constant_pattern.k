// A constant pattern on a column whose type is a duck-generic parameter is
// an `==` test against the constant, as a literal there is; the instance's
// C++ picks the operator. so the match has a
// decision tree and EmitIR meets no "match MatchLowering left in place".
// Any other constructor head there (a variant) still has no domain
// to resolve against: SC116E.

struct P {
    var x: i32
    fn op ==(const self, const other: P) -> bool { return self.x == other.x }
}

const ONE: P = P { x: 1 }
eval TWO: i32 = 2

fn <T: type> k(p: T) -> i32 {
    match p {
        case ONE { return 1 }
        default { return 0 }
    }
}

fn <T: type> n(v: T) -> i32 {
    match v {
        case TWO { return 4 }
        default { return 0 }
    }
}

fn main() -> i32 {
    return k(P { x: 1 }) + k(P { x: 3 }) + n(2) + n(5) // 1 + 0 + 4 + 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
// RUN: printf 'enum E { A, B }\nfn <T: type> k(p: T) -> i32 {\n    match p {\n        case E::A { return 1 }\n        default { return 0 }\n    }\n}\nfn main() -> i32 { return k(E::A) }\n' > %t.v.k
// RUN: { %kairo %t.v.k -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK: .v.k:4:14: error [SC116E]: this pattern on a value whose type depends on a generic parameter is not yet supported
