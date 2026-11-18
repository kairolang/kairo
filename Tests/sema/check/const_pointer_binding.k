// `const p: *T` freezes the pointer, not the pointee: repointing it is an
// error, and a mutating method or an assignment through it is not.
// `const p: *const T` freezes both.

class W {
    pub var n: i32 = 0
    fn bump(self) {
        self.n += 1
    }
}

fn writes(const p: *W) {
    p->bump()
    *p = W()
    p->n = 3
}

fn repoints(const p: *W, q: *W) {
    p = q
}

fn both(const p: *const W) {
    p->n = 1
}

fn main() -> i32 {
    var w = W()
    const q: *W = &w
    q->bump()
    var o = W()
    q = &o
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s
// CHECK-NOT: const_pointer_binding.k:1{{[0-6]}}:{{.*}}error
// CHECK: const_pointer_binding.k:19:5: error [SC071E]: cannot assign to 'p': it is const
// CHECK: const_pointer_binding.k:23:{{[0-9]+}}: error [SC071E]
// CHECK: const_pointer_binding.k:31:5: error [SC071E]: cannot assign to 'q': it is const
