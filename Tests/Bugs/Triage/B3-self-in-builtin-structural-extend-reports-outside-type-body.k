//  build: kairo B3-self-in-builtin-structural-extend-reports-outside-type-body.k --print-sema --type-check-only
// version: kairo-0.1.1+dev.20260907
//
// ### Expected behavior
// Widen `selfs` to accept a type (not just a decl), or add a parallel
// self_types stack that's consulted before the decl stack, so `Self`
// resolves correctly inside extensions of builtins and structural types —
// consistent with what name resolution already reports (the name-binding
// trace shows Self DOES resolve correctly even though this diagnostic
// fires).
//
// ### Additional context
// Source: Compiler/Sema/Resolve/TypeResolve.k. Last run: fires
// [R001E] 'Self' used outside of a type body at the `-> Self` return-type
// position, even though --print-sema's own name-binding trace shows Self
// resolving fine ("use Self @ ... -> extend @ 1:1 [scope <anon scope>]").
// The diagnostic looks like it comes from a separate check walking a
// decl-only `selfs` stack that disagrees with name resolution. Note:
// plain `extend i32 { fn foo(self) -> i32 { return Self } }` (a builtin
// target, no generics) did NOT reproduce this the fault is specifically
// tied to the structural/generic extension target (`extend <T> [T]`).

extend <T> [T] {
    fn first(self) -> Self {
        return Self
    }
}
