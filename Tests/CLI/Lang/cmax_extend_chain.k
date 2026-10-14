// --cmax-extend-chain errors on the extend block that makes a type's count in
// one file exceed the limit. Two blocks on i32: a limit of 2 accepts, 1
// rejects (at the second block).

extend i32 {
    fn first(self) -> i32 = 1
}

extend i32 {
    fn second(self) -> i32 = 2
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo --type-check-only --cmax-extend-chain=2 %s
// RUN: { %kairo --type-check-only --cmax-extend-chain=1 %s 2>&1 || true; } | %FileCheck %s
// CHECK: cmax_extend_chain.k:9:{{[0-9]+}}: error [SC001E]: type has too many extend blocks (2, limit 1)
