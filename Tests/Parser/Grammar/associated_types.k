// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// Inside an interface, `type N` is an ASSOCIATED type (interfaces.md,
// "Associated Types"): `=` gives an optional default and `impl X, Y` bounds
// it; the bounds are its requires clause, `N impl X && N impl Y`. Anywhere
// else `type` is an alias: `=` is required and `impl` means nothing.
//
// AST: InterfaceDecl Graph
// AST-NEXT: TypeAliasDecl Node
// AST-NEXT: TypeAliasDecl Edge impl Display
// AST-NEXT: TypeAliasDecl Weight impl Display, Numeric
// AST-NEXT: TypeAliasDecl Index = usize
// AST-NEXT: TypeAliasDecl Key impl Display = i32
// AST-NEXT: TypeAliasDecl Map
//
// DIAG: associated_types.k:36:1: error [S050E]: expected '=' in type alias declaration
// DIAG-NEXT: associated_types.k:36:1: note [I900N]: a 'type' with no '=' is an associated type, which is only declared inside an interface
// DIAG: associated_types.k:38:12: error [S001E]: 'impl' bounds an associated type, which is only declared inside an interface
// DIAG-NOT: error

interface Display { fn show(const self) -> i32 }
interface Numeric { fn num(const self) -> i32 }
interface Graph {
    type Node
    type Edge impl Display
    type Weight impl Display, Numeric
    type Index = usize
    type Key impl Display = i32
    type <K impl Display> Map
    fn edges(const self) -> i32
}

type Alias = i32

type Free

type Bound impl Display = i32
