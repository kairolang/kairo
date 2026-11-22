// `@create T(args)` and `@create T { f: v }` allocate and construct.

class C {
    pub var v: i32
    fn C(self, v: i32) { self.v = v }
    @move fn C(self, other: Self) = default
}

struct P {
    pub var x: i32
    pub var y: i32
}

fn main() -> i32 {
    var *a = @create C(10)
    var *p = @create P { x: 3, y: 4 }
    var *n = @create i32(5)
    var r = a->v + p->x + p->y + (*n)
    @destroy a
    @destroy(p)
    @destroy n
    if r != 22 { return 1 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
