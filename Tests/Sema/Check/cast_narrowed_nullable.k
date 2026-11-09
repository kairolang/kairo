// After `if ptr == &null { return }`, an `as` cast reads the narrowed
// `*B` as member access there does: `ptr as unsafe *B` was SC026E
// "'*B?' is neither a pointer nor an integer". An unproven nullable still
// does not convert.

class B { var x: i32 = 7 }

fn raw(ptr: *B?) -> unsafe *B {
    if ptr == &null { return &null }
    var a = ptr->x
    return unsafe (ptr as unsafe *B)
}

fn unproven(ptr: *B?) -> unsafe *B {
    return unsafe (ptr as unsafe *B)
}

fn main() -> i32 {
    var b = B()
    return unsafe raw(&b)->x
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG-NOT: {{error|warning}}
// DIAG: cast_narrowed_nullable.k:15:20: error [SC026E]: only a pointer or an integer can be cast to 'unsafe *B'; '*B?' is neither
// DIAG-NOT: {{error|warning}}
