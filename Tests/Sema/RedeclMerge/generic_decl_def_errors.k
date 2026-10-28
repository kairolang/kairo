// Generic redeclarations held to "must match exactly"
// (functions-declarations.mdx, Signature matching) once they are one
// function. A declaration and its definition that name different bounds
// for a parameter are an error at the later one with a note at the
// earlier. A different return type over the parameter is the ordinary
// return-type conflict, now that `-> A` and `-> B` compare as one type.
// Two DEFINITIONS that differ only in their bounds stay two overloads, as
// before, and so do two declarations whose parameter lists differ in kind
// (a value parameter against a type one) or in a value parameter's type.

interface Graph { fn first(const self) -> i32 }
interface Tree { fn root(const self) -> i32 }

fn <T impl Graph> g(x: T) -> i32
fn <T impl Tree> g(x: T) -> i32 { return x.root() }

fn <T derives Base> d(x: *T) -> i32
fn <T> d(x: *T) -> i32 { return 0 }

fn <A> r(v: A) -> A
fn <B> r(v: B) -> i32 { return 0 }

fn <T impl Graph> two(x: T) -> i32 { return x.first() }   // ok: overloads
fn <T impl Tree> two(x: T) -> i32 { return x.root() }

fn <eval N: usize> v(const a: [i32; N]) -> i32 { return 1 }     // ok: overloads
fn <eval N: u8> v(const a: [i32; N]) -> i32 { return 2 }

class Base { }

fn main() -> i32 { return 0 }

// --- lit wiring ---

// BEGIN-GENERATED-CHECKS(DIAG) mode=diag -- regenerate with Tests/gen_checks.py, do not hand-edit
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG: {{.*}}:15:1: error [R001E]: 'g' redeclared with different bounds on generic parameter 'T'; a declaration and its definition must name the same bounds
// DIAG-NEXT: {{.*}}:14:1: note [R001N]: previously declared here
// DIAG: {{.*}}:18:1: error [R001E]: 'd' redeclared with different bounds on generic parameter 'T'; a declaration and its definition must name the same bounds
// DIAG-NEXT: {{.*}}:17:1: note [R001N]: previously declared here
// DIAG: {{.*}}:21:19: error [R037E]: 'r' declared with a different return type; the parameter types are identical, so this is a redeclaration, not an overload
// DIAG-NEXT: {{.*}}:20:19: note [R037N]: previously declared with this return type
// END-GENERATED-CHECKS(DIAG)
