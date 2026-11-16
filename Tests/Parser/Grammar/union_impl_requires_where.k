// A union head reads what a struct head reads: an `impl` list, a `requires`
// clause (on its own line too), and a `where` clause is refused with the
// fix to `requires`, naming the union.

interface Same {
    fn op ==(const self, o: Self) -> bool
}

union Bits impl Same {
    var word: u32

    fn op ==(const self, o: Bits) -> bool { return self.word == o.word }
}

union <T> Wide
    requires T impl Same {
    var value: T
    var raw:   u64
}

union <T> Bad where T impl Same {
    var value: T
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s
// CHECK: |-UnionDecl Bits impl Same
// CHECK: |-UnionDecl Wide
// CHECK: `-UnionDecl Bad
// CHECK: -- 1 error(s), 0 warning(s) --
// CHECK: union_impl_requires_where.k:21:15: error [S045E]: 'where' is not allowed on a union; runtime-conditional dispatch is only valid on functions. Use 'requires' for a compile-time constraint instead
// CHECK-NOT: error [
