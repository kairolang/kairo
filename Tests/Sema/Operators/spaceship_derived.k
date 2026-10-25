// A type that declares `op <=>` gets all six comparisons from it: `<` `<=`
// `>` `>=` as `(a <=> b) <op> 0`, and -- when no `op ==` answers -- `==`
// and `!=` the same way. A comparison the type declares itself wins every
// use, and is warned about as shadowing the derived one, whether it sits in
// the body or in an extension. `!=` prefers a declared `op ==` (`!(==)`)
// over `<=>`.

class Ver {
    pub var v: i32
    fn Ver(self, v: i32) { self.v = v }
    pub fn op <=> (const self, other: Ver) -> Ordering { return Ordering::Equal }
}

class Mixed {
    pub var v: i32
    fn Mixed(self, v: i32) { self.v = v }
    pub fn op <=> (const self, other: Mixed) -> Ordering { return Ordering::Equal }
    pub fn op < (const self, other: Mixed) -> bool { return false }
    pub fn op == (const self, other: Mixed) -> bool { return true }
}

class Ext {
    pub var v: i32
    fn Ext(self, v: i32) { self.v = v }
    pub fn op <=> (const self, other: Ext) -> Ordering { return Ordering::Equal }
}

extend Ext {
    fn op >= (const self, other: Ext) -> bool { return true }
}

fn derived(a: Ver, b: Ver) -> bool {
    var x = a < b
    var y = a <= b
    var z = a > b
    var w = a >= b
    var e = a == b
    var n = a != b
    var m = a not_eq b
    return x && y && z && w && e && n && m
}

fn shadowed(a: Mixed, b: Mixed, c: Ext, d: Ext) -> bool {
    var x = a < b
    var y = a > b
    var e = a == b
    var n = a != b
    var g = c >= d
    var l = c <= d
    return x && y && e && n && g && l
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not="error [" --implicit-check-not="warning ["
// DIAG:      spaceship_derived.k:18:9: warning [SC001W]: 'op <' shadows the '<' derived from 'op <=>'; every '<' calls this declaration instead
// DIAG-NEXT: spaceship_derived.k:17:9: note [{{[A-Z0-9]+}}]: 'op <=>' is declared here; it already derives '<', '<=', '>', '>=', '==' and '!='
// DIAG:      spaceship_derived.k:19:9: warning [SC001W]: 'op ==' shadows the '==' derived from 'op <=>'; every '==' calls this declaration instead
// DIAG-NEXT: spaceship_derived.k:17:9: note
// DIAG:      spaceship_derived.k:29:5: warning [SC001W]: 'op >=' shadows the '>=' derived from 'op <=>'; every '>=' calls this declaration instead
// DIAG-NEXT: spaceship_derived.k:25:9: note

// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA-LABEL: SEMA fid {{[0-9]+}}: {{.*}}spaceship_derived.k =====
// SEMA:       BinaryOperatorExpr @ 33:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 34:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 35:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 36:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 37:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 38:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 39:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 44:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 45:13 : bool [rewrite: <=> vs 0]
// SEMA:       BinaryOperatorExpr @ 46:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 47:13 : bool [rewrite: !(==)]
// SEMA:       BinaryOperatorExpr @ 48:13 : bool{{$}}
// SEMA:       BinaryOperatorExpr @ 49:13 : bool [rewrite: <=> vs 0]
