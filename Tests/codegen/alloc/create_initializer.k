// `@create T { field: value }` allocates a T through the allocator in effect
// and builds it from the initializer: it is sugar for
// `create<T>(T { field: value })`, needing no import, as `@create T(args)`
// is. The head may be a generic application or a `::` path; a field left
// out takes its default, and a move-only record moves from the initializer
// into the storage.

struct Point {
    pub var x: i32
    pub var y: i32 = 10
}

struct Named {
    pub var s: string
    pub var n: i32
}

struct <T> Pair {
    pub var a: T
    pub var b: T
}

struct Outer {
    pub struct In {
        pub var k: i32
    }

    pub var z: i32 = 0
}

fn main() -> i32 {
    var *p = @create Point { x: 1 }
    var *m = @create Named { s: "abc", n: 5 }
    var *g = @create Pair<i32> { a: 3, b: 4 }
    var *o = @create Outer::In { k: 2 }
    var r = p->x + p->y + m->n + g->a + g->b + o->k + (m->s.size() as i32)
    @destroy p
    @destroy m
    @destroy g
    @destroy o
    // 1 + 10 + 5 + 3 + 4 + 2 + 3 = 28
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 28
