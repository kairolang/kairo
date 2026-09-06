// XFAIL: *
//
// KNOWN COMPILER BUG, already tracked in the design doc: RESOLUTION.md
// §2.7 and Compiler/Sema/IMPORTS.md §4.3, "Reopened namespaces [BROKEN ->
// two edits]". Two `module Foo { ... }` blocks with the same name in one
// TU are supposed to be ONE module reopened twice (like a C++ namespace),
// but N(a) currently treats the second `module Util { }` as a plain
// REDEFINITION of the same DeclKind, because ModuleDecl goes through the
// generic `_link_group::<ModuleDecl>` redeclarable-chain path, which
// (per IMPORTS.md §4.2/§4.3) does not yet special-case module reopening:
// `non_function_count` does not skip ModuleHandle/FfiAnchor candidates,
// and ChainBinding has no multi-scope Module anchor to search every
// physical `module Util { }` block for a name. The fix is specified in
// IMPORTS.md §4.3 (a multi-scope `Anchor.scopes: vec<*DeclContext>` for
// ChainBinding, plus a `non_function_count` skip) but not implemented.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/namespace.cpp (the "reopen and
//   add a member visible to the reopened namespace's siblings" half)
//   Lib/llvm-runtimes/clang/test/CXX/basic/basic.scope/basic.scope.namespace/
//
// What SHOULD happen (and does not, yet): `module Util { fn a() }` and a
// later `module Util { fn b() }` merge into one scope; `b`'s body can see
// `a` unqualified (same scope), and both members are reachable through
// EITHER `Util::` qualification, exactly as if both fn's had been written
// in a single `module Util { }` block.

module Util {
    fn a() -> i32 { return 1 }
}

module Util {
    // Wanted: `a` resolves unqualified, because this is the SAME module
    // reopened, not a new one. Currently: N(a) reports the whole second
    // `module Util { }` block as a redefinition of the first, and its body
    // is never bound into Util's scope at all, so `a` is reported
    // "undeclared" too.
    fn b() -> i32 { return a() + 1 }
}

fn use_util() -> i32 {
    return Util::a() + Util::b()
}

// This file encodes the DESIRED behavior (reopening is legal, `a` resolves
// unqualified inside the reopened block) and is expected to FAIL against
// today's compiler, which instead reports:
//   error: redefinition of 'Util'
//   note: previous definition of 'Util' is here
//   error: use of undeclared identifier 'a'
// -- exactly the symptom IMPORTS.md §4.3 names. Once that fix lands, drop
// the XFAIL.
// DIAG-NOT: error
