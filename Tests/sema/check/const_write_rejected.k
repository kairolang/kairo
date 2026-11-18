// `++`, `--` and `op=` on a const binding are Kairo errors, not only clang's
// (CL001E), and so is a write to a `const` pointer parameter, whose
// top-level const is not emitted. variables.mdx, "The `const`
// Binding Rule": a const binding is never written. Sema rejects every write
// (SC071E) with a note at the binding and, for a `const` local, a fix-it.

fn bump(const c: *i32) -> i32 {
    c += 1
    ++c
    return 0
}

fn main() -> i32 {
    const n: i32 = 1
    ++n
    n += 2
    n--
    n = 4
    var x: i32 = 0
    return bump(&x) + n
}

// A const record binding (a string) was assigned with no Kairo error.
fn strings() -> i32 {
    const s: string = "a"
    s = "x"
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK: const_write_rejected.k:8:5: error [SC071E]: cannot update 'c': it is const
// CHECK: const_write_rejected.k:7:15: note [I900N]: 'c' declared const here
// CHECK: const_write_rejected.k:9:5: error [SC071E]: cannot increment or decrement 'c': it is const
// CHECK: const_write_rejected.k:15:5: error [SC071E]: cannot increment or decrement 'n': it is const
// CHECK: fix-it:{{.*}}:{14:5-14:10}:"var"
// CHECK: const_write_rejected.k:14:11: note [I900N]: 'n' declared const here
// CHECK: const_write_rejected.k:16:5: error [SC071E]: cannot update 'n': it is const
// CHECK: const_write_rejected.k:17:5: error [SC071E]: cannot increment or decrement 'n': it is const
// CHECK: const_write_rejected.k:18:5: error [SC071E]: cannot assign to 'n': it is const
// CHECK: const_write_rejected.k:26:5: error [SC071E]: cannot assign to 's': it is const
// CHECK: fix-it:{{.*}}:{25:5-25:10}:"var"
// CHECK: const_write_rejected.k:25:11: note [I900N]: 's' declared const here
// CHECK-NOT: error
