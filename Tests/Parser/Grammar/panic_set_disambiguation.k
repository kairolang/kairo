// Where `panic (` is the declared set and where it is something else
// (PANIC.md §2.2, TypeParse::parse_panic_set). The rule: in a specifier
// position -- after a function's or closure's parameter list, or after a
// `fn` type's -- `panic` followed by `(` ON THE SAME LINE opens the set.
// Nothing else can follow a specifier there, so the list is never a tuple.
// Everywhere else `panic` is the statement, and `panic (x)` panics with a
// parenthesized value.

class E1 { var a: i32 }

fn h() { }

// Statement position: `panic (expr)` is the panic statement, never a set.
fn stmt() panic -> i32 {
    panic (E1(a: 1))
}

// A newline ends the specifier: `fn() panic` is a complete type, and the
// next line is a call expression statement, not a set.
fn newline_ends_type() {
    var t: fn() panic
    (h)()
}

// A tuple after `->` is the return type, as it always was.
fn tuple_ret() panic -> (i32, i32) { return (1, 2) }
fn tuple_ret_set() panic(E1) -> (i32, i32) { return (1, 2) }

// A `fn` type with a set inside a parameter list, before a tuple return.
fn nested(cb: fn(i32) panic(E1) -> (i32, i32)) { }

// `= panic ...` after a header is not a specifier position: it is rejected
// as a misplaced specifier, as before (S047E).
fn expr_body() = panic (E1(a: 2))

// --- lit wiring ---
// RUN: { %kairo %s --type-check-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=TREE
// TREE:      FunctionDecl  stmt() panic -> i32
// TREE-NEXT: `-CompoundStmt (1)
// TREE-NEXT:   `-PanicStmt
// TREE-NEXT:     `-CallExpr (1 args)
// TREE:      FunctionDecl  newline_ends_type()
// TREE-NEXT: `-CompoundStmt (2)
// TREE-NEXT:   |-DeclStmt
// TREE-NEXT:   | `-VariableDecl var t: fn() panic
// TREE-NEXT:   `-ExpressionStmt
// TREE-NEXT:     `-CallExpr (0 args)
// TREE:      FunctionDecl  tuple_ret() panic -> (i32, i32)
// TREE:      FunctionDecl  tuple_ret_set() panic(E1) -> (i32, i32)
// TREE:      FunctionDecl  nested(cb: fn(i32) panic(E1) -> (i32, i32))
// TREE:      -- 1 error(s), 0 warning(s) --
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// DIAG:     panic_set_disambiguation.k:34:18: error [S047E]: panic functions must be declared with the 'panic' modifier
// DIAG-NOT: error
