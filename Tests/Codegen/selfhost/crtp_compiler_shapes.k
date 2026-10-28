// The CRTP shapes Compiler/ is written with (93 `class X derives
// Y::<X>` sites over 7 mixin templates, ~1,300 `self.dyn()->` calls),
// reduced to their Stage-1 spelling under `: type` (-fduck-generics, MONO.md
// D1) and run:
//
//  - RecursiveASTVisitor / ASTWriter: a dispatcher in the mixin that calls
//    hooks through `self.dyn()->`, a hook with a default the leaf overrides,
//    one it does not, and the mixin's own state;
//  - ExprTyper: several mixins on one class, a generic INTERMEDIATE mixin
//    (`StmtTyping<T> derives RecursiveASTVisitor<T>`), siblings calling
//    each other through dyn(), a static member through `T::`, a field of
//    the leaf read through dyn();
//  - VisibilityAnnotation / FFILinkage: a data mixin (fields + const
//    queries) that is not the first base, read directly off the leaf.
//
// Every `dyn()` is `&self as *T`: a static_cast, which is what keeps a
// mixin at a nonzero offset correct (crtp_cast_duck.k). NOT covered, known:
// Compiler/'s StmtTyping declares its own `dyn` beside the one it inherits
// from RecursiveASTVisitor, and a same-name method on the derived type is
// ambiguous with the base's (SC064E; Tests/Codegen/oop/override_direct_call.k,
// XFAIL), so the intermediate mixin here names its helper `sdyn`.

class Node {
    pub var kind: i32
    pub var val: i32
    fn Node(self, kind: i32, val: i32) { self.kind = kind; self.val = val }
}

// --- RecursiveASTVisitor ----------------------------------------------------
class <D: type> Rav {
    pub var visited: i32 = 0
    fn dyn(self) -> *D { return &self as *D }
    fn dispatch(self, n: *Node) -> i32 {
        self.visited += 1
        if n->kind == 0 { return self.dyn()->traverse_lit(n) }
        return self.dyn()->traverse_neg(n)
    }
    fn traverse_lit(self, n: *Node) -> i32 { return self.dyn()->walkup_lit(n) }
    fn traverse_neg(self, n: *Node) -> i32 { return 0 - self.dyn()->walkup_lit(n) }
    fn walkup_lit(self, n: *Node) -> i32 { return n->val }
}

// --- the ExprTyper family ---------------------------------------------------
class <T: type> Stmts derives Rav<T> {
    fn sdyn(self) -> *T { return &self as *T }
    fn stmt(self, n: *Node) -> i32 { return self.sdyn()->expr(n) + T::bias() }
}

class <T: type> Exprs {
    fn dyn(self) -> *T { return &self as *T }
    fn expr(self, n: *Node) -> i32 { return self.dyn()->dispatch(n) * self.dyn()->scale }
}

class <T: type> Lits {
    pub var lits: i32 = 0
    fn ldyn(const self) -> *const T { return &self as *const T }
    fn lit_scale(const self) -> i32 { return self.ldyn()->scale + self.lits }
}

// --- VisibilityAnnotation ---------------------------------------------------
class <T: type> Vis {
    pub var visibility: i32 = 0
    fn is_public(const self) -> bool { return self.visibility == 3 }
    fn set_visibility(self, v: i32) { self.visibility = v }
}

class Typer derives Stmts<Typer>, Exprs<Typer>, Lits<Typer>, Vis<Typer> {
    pub var scale: i32 = 3
    static fn bias() -> i32 { return 1 }
    fn walkup_lit(self, n: *Node) -> i32 { return n->val + 10 }   // the leaf's hook
}

// --- ASTWriter: a second leaf over the same visitor, no overrides -----------
class Writer derives Rav<Writer> {
    pub var lines: i32 = 0
}

fn main() -> i32 {
    var r = 0
    var t = Typer()
    var lit = Node(0, 2)
    var neg = Node(1, 5)
    if t.stmt(&lit) == 37 { r += 1 }              // (2 + 10) * 3 + 1
    if t.stmt(&neg) == 0 - 44 { r += 2 }          // -(5 + 10) * 3 + 1
    if t.visited == 2 { r += 4 }
    t.lits = 4
    if t.lit_scale() == 7 { r += 8 }
    t.set_visibility(3)
    if t.is_public() && (t.visibility == 3) { r += 16 }

    var w = Writer()
    if (w.dispatch(&lit) == 2) && (w.dispatch(&neg) == 0 - 5) && (w.visited == 2) { r += 32 }
    return r                                      // 63
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -fduck-generics --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -fduck-generics -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 63
