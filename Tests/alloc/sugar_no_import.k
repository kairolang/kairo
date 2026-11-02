// P91: `@create` / `@destroy` lower to alloc.k's create / destroy
// (::builtin::base::alloc), so a program that writes the sugar needs no
// import at all -- in every spelling. The name is bound at the lowering,
// not looked up: a local `create` does not capture it, and a hand-written
// `create<T>(...)` with no import is still undeclared (Inputs/bare_create.k).

static dropped: i32 = 0

class P {
    pub var a: i64
    fn P(self, a: i64) { self.a = a }
    fn op delete(self) { dropped = dropped + 1 }
    @move fn P(self, other: Self) = default
}

// Not what the sugar means.
fn create(x: i64) -> i64 { return x }

fn main() -> i32 {
    var *p = @create<P>(5i64)
    var *q = @create P(6i64)
    var *n = @create i32(7)
    var sum = p->a + q->a + (*n) as i64 + create(1i64)
    @destroy p
    @destroy(q)
    @destroy<i32>(n)
    // 5 + 6 + 7 + 1, and two P destructors ran.
    if sum != 19 { return 1 }
    return dropped + 40
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %S/Inputs/bare_create.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=BARE
// BARE: bare_create.k:{{[0-9]+}}:{{[0-9]+}}: error [R020E]: use of undeclared identifier 'create'

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
