// A builtin type that declares no applicable operator keeps its built-in
// shape (RESOLUTION.md, "A builtin type's declared operator wins"): `v[i]`,
// `m[k]` and `s[i]` type as the element with no `op []` in scope, and
// iterating a builtin container with no `op in (self) -> yield T` is still
// the SC116E gate. An `op in (self, x)` -- containment -- is no iteration
// form, so declaring one changes nothing for `for ... in`.
//
// Type-check only: the shapes have no lowering yet (EmitIR ICEs on `v[i]`,
// IterLowering on the containers), which is what the gate is for.

extend <T> {T} {
    fn op in (self, x: T) -> bool { return false }
}

fn index(v: [i32], m: {i32: i32}, s: string) -> i32 {
    var a: i32 = v[0]
    var b: i32 = m[1]
    var c: char = s[0]
    return a + b
}

fn walk(v: [i32], st: {i32}, s: string) {
    for x in v { 0 }
    for x in st { 0 }
    for c in s { 0 }
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --implicit-check-not=error
// DIAG: builtin_ops_fallback.k:23:14: error [SC116E]: iterating a vector is not yet supported
// DIAG: builtin_ops_fallback.k:24:14: error [SC116E]: iterating a set is not yet supported
// DIAG: builtin_ops_fallback.k:25:14: error [SC116E]: iterating a string is not yet supported
