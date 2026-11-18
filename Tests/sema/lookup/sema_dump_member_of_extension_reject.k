// --print-sema names the extended type for members of other extension
// shapes: a generic record's extension, `bool` and `string`; never an empty
// "[member of ]".

struct <T> Box { var v: T }

extend <T> Box<T> {
    fn get(const self) -> T = self.v
}

extend bool {
    fn flip(self) -> bool = !self
}

extend string {
    fn first_len(self) -> i32 = 1
}

fn use_it() -> i32 {
    var b = Box<i32> { v: 1 }
    var f = true
    var s: string = "x"
    if f.flip() { return 0 }
    return b.get() + s.first_len()
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --implicit-check-not="[member of ]"
// CHECK: member  .flip {{.*}}[member of bool]
// CHECK: member  .get {{.*}} -> fn get @ 8:5  [member of Box]
// CHECK: member  .first_len {{.*}}[member of string]
