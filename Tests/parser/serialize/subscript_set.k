// `op []=` in a serialized AST: the operator is three tokens, and its
// identity is their kinds (DeclName::op_name_of keys `[` `]` `=` apart from
// `op []`). A reloaded tree must rebuild the same table: the explicit call
// `b.op []=(1)` finds the place form by that key, and `b.op [](1)` the read
// form, so a reload that keyed the place form as `op []` would turn the
// second call ambiguous or the first unresolved. Covers a class, a generic
// class, an interface requirement and an out-of-line definition.

class Buf {
    var d: [i32; 4]
    fn Buf(self) { }
    fn op [] (const self, i: usize) -> *const i32 { return &self.d[i] }
    fn op []= (self, i: usize) -> *i32 { return &self.d[i] }
}

class <T> Box {
    var d: [T; 2]
    fn Box(self) { }
    fn op []= (self, i: usize) -> *T { return &self.d[i] }
}

interface Store {
    fn op []= (self, i: usize) -> *i32
}

class Late {
    var d: [i32; 2]
    fn Late(self) { }
    fn op []= (self, i: usize) -> *i32
}

fn Late::op []= (self, i: usize) -> *i32 { return &self.d[i] }

fn main() -> i32 {
    var b = Buf()
    var *p = b.op []=(1)
    var *q = b.op [](1)
    var x = Box<i32>()
    var *r = x.op []=(0)
    var l = Late()
    var *s = l.op []=(1)
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --syntax-only --verify-ast-roundtrip 2>&1 || true; } | %FileCheck %s --check-prefix=VERIFY --allow-empty
// VERIFY-NOT: I002F
// RUN: { %kairo %s --syntax-only --print-ast=tree 2>/dev/null || true; } > %t.parsed
// RUN: { %kairo %s --syntax-only --print-ast=tree --ast-roundtrip 2>/dev/null || true; } > %t.reloaded
// RUN: diff %t.parsed %t.reloaded
// RUN: %FileCheck %s < %t.reloaded
// CHECK: FunctionDecl op []= (self, i: usize) -> *i32
// CHECK: Step .op[]=
// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } > %t.diag.parsed
// RUN: { %kairo %s --type-check-only --print-sema --ast-roundtrip 2>&1 || true; } > %t.diag.reloaded
// RUN: diff %t.diag.parsed %t.diag.reloaded
// RUN: %FileCheck %s --check-prefix=SEMA < %t.diag.reloaded
// SEMA-NOT: error [
// SEMA: op []=
