// The declared panic set `panic(E1, E2)` (PANIC.md §2.2) in every position
// the specifier takes: a function header, a method, an interface
// requirement, a closure, and a `fn` type. Each prints back as written, in
// the tree and in the flat source form. Before the set parsed, `(E1, E2)`
// after `panic` read as a tuple literal (S054E). Only syntax is asserted
// here: the checks on the sets are Tests/Sema/Panic/.

class E1 { var a: i32 }
class E2 { var b: i32 }

fn free(x: i32) panic(E1, E2) -> i32 { return x }
fn one() panic(E1) { }
fn generic_elem() panic([E1], *E2) -> i32 { return 0 }
fn <T> pack_param(x: T) panic(T) -> T { return x }
fn bare() panic -> i32 { return 0 }

class C {
    var k: i32
    fn m(self) panic(E1) -> i32 { return self.k }
}

interface I {
    fn req(self) panic(E1, E2) -> i32
}

fn takes(cb: fn(i32) panic(E1) -> i32, w: fn() panic(E2) async) { }

fn main() -> i32 {
    var c = fn (x: i32) panic(E1) -> i32 { return x }
    var d = fn (x: i32) panic(E1, E2) = x
    var t: fn(i32) panic(E1, E2) -> i32
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE:      FunctionDecl  free(x: i32) panic(E1, E2) -> i32
// TREE:      FunctionDecl  one() panic(E1)
// TREE:      FunctionDecl  generic_elem() panic([E1], *E2) -> i32
// TREE:      FunctionDecl <T> pack_param(x: T) panic(T) -> T
// TREE:      FunctionDecl  bare() panic -> i32
// TREE:      FunctionDecl  m(self) panic(E1) -> i32
// TREE:      FunctionDecl  req(self) panic(E1, E2) -> i32
// TREE:      FunctionDecl  takes(cb: fn(i32) panic(E1) -> i32, w: fn() async panic(E2))
// TREE:      ClosureExpr panic(E1) ->  i32
// TREE:      ClosureExpr panic(E1, E2)
// TREE:      VariableDecl var t: fn(i32) panic(E1, E2) -> i32
// TREE:      -- 0 error(s), 0 warning(s) --
//
// RUN: { %kairo %s --type-check-only --print-ast=flat 2>&1 || true; } | %FileCheck %s --check-prefix=FLAT
// FLAT:      fn free(x: i32) panic(E1, E2) -> i32 { return x }
// FLAT:      fn one() panic(E1) {}
// FLAT:      fn takes(cb: fn(i32) panic(E1) -> i32, w: fn() async panic(E2)) {}
// FLAT:      var c = fn(x: i32) panic(E1) -> i32 { return x }; var d = fn(x: i32) panic(E1, E2) = x; var t: fn(i32) panic(E1, E2) -> i32
// FLAT-NOT:  error [S0
