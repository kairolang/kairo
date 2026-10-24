// RUN: { %kairo %s --syntax-only --print-ast=tree 2>&1 || true; } | %FileCheck %s --check-prefix=AST
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
//
// An interface's `derives` clause is an expression over interfaces: `+`
// union, `-` difference, `&` intersection, with parentheses, and `A, B` as
// `A + B`. The expression parser reads it (its precedence: `+`/`-` bind
// tighter than `&`); the parser checks its shape and turns each leaf into
// the type derives_list resolves. A plain union prints as today's list; a
// clause using `-` or `&` prints as the expression, with the parentheses its
// tree needs.
//
// AST: InterfaceDecl Union derives X, Y
// AST: InterfaceDecl Plus derives X, Y
// AST: InterfaceDecl Diff derives X + (Y - Z)
// AST: InterfaceDecl Left derives X - Y - Z
// AST: InterfaceDecl Inter derives (X + Y) & Z
// AST: InterfaceDecl Gen derives G<i32> & X
// AST: InterfaceDecl Path derives m::Q - X
//
// Only an unparenthesized mix of `&` with `+`/`-` warns, with the fix-it.
// DIAG-NOT: warning
// DIAG: interface_algebra.k:38:24: warning [S001W]: '+' and '-' bind tighter than '&' in a 'derives' clause; parenthesize to say which you mean
// DIAG-NOT: warning

interface X { fn a(self) }
interface Y { fn b(self) }
interface Z { fn c(self) }
interface <E> G { fn get(self) -> E }
module m { pub interface Q { fn q(self) } }

interface Union derives X, Y { }
interface Plus derives X + Y { }
interface Diff derives X + (Y - Z) { }
interface Left derives X - Y - Z { }
interface Inter derives (X + Y) & Z { }
interface Gen derives G<i32> & X { }
interface Path derives m::Q - X { }
interface Warn derives X + Y & Z { }
