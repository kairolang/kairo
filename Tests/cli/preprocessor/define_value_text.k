// A --define value is every byte after the first `=`: a value longer than
// one token, one that itself holds `=`, and an empty one (the macro expands
// to nothing).

fn main() -> i32 {
    var a = WIDE!
    var b = EQ!
    var c = 3 EMPTY!
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed --define=WIDE=40+2 --define=EQ=x==y --define=EMPTY= | %FileCheck %s
// CHECK: var a = 40 + 2
// CHECK-NEXT: var b = x == y
// CHECK-NEXT: var c = 3
// CHECK-NOT: EMPTY
