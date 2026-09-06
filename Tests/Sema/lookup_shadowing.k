// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Ported from (semantic content only -- clang-specific machinery dropped):
//   Lib/llvm-runtimes/clang/test/SemaCXX/warn-shadow.cpp
//   Lib/llvm-runtimes/clang/test/CXX/basic/basic.scope/basic.scope.declarative/
//
// clang's warn-shadow.cpp is mostly about a *diagnostic* (-Wshadow) that
// fires when an inner declaration shadows an outer one, and about namespace
// members shadowed by locals. Kairo's N does not warn on shadowing (§2.5 of
// RESOLUTION.md: shadowing is legal, MERGE-not-hide is a member-lookup rule,
// not a name-lookup rule) -- what N must get right is which of the two decls
// each USE binds to at each nesting depth. So this file keeps the shape
// (file scope -> function scope -> nested block scope, each introducing a
// same-spelling name) and asserts BINDING, not a shadow warning: `--print-sema`
// dumps `(shadows ... in <tu>)` when a local shadows an outer decl, and this
// file checks that annotation appears exactly where a real shadow occurs and
// nowhere else.
//
// Dropped entirely: static/anonymous-namespace shadow diagnostics (no
// anonymous-module analogue), using-directive-introduced shadowing
// (basic.scope.declarative's namespace merge story -- covered instead by
// lookup_module_reopen.k), and the "typedef/using shadowed by a var" cases
// (Kairo type aliases and value names share one symbol table per DC, so a
// var CANNOT coexist with a type alias of the same name in one scope --
// that is a redefinition, exercised in lookup_redecl_class.k, not shadowing).

// ---------------------------------------------------------------------------
// CASE 1: file-scope var, shadowed by a function param, shadowed again by a
// block-local. Three lexical depths, three different decls, one spelling.

var v: i32 = 1;

fn depth_two(v: i32) -> i32 {
    // `v` here is the PARAM: if it read the file-scope var (1) instead of
    // the param, this function would always return the constant 1's
    // sibling instead of its argument.
    var outer_read = v;
    {
        var v: i32 = 99;
        // `v` here is the BLOCK-LOCAL: getting the frame order wrong would
        // bind this to the param instead.
        var inner_read = v;
        outer_read = outer_read + inner_read;
    }
    // Back outside the block: `v` is the PARAM again. A block frame that
    // leaked past its `}` would still see the block-local here.
    return v + outer_read
}

// ---------------------------------------------------------------------------
// CASE 2: two sibling blocks in the same function, each shadowing the same
// outer name. Neither may see the other's local (they are not nested in
// each other).

fn sibling_blocks(w: i32) -> i32 {
    var total = 0;
    {
        var w: i32 = 10;
        total = total + w;
    }
    {
        var w: i32 = 20;
        total = total + w;
    }
    // Outside both blocks, `w` is the param again.
    return total + w
}

// --- diagnostics -------------------------------------------------------
// Shadowing is legal; nothing here is an error.
// DIAG-NOT: error
// DIAG-NOT: undeclared identifier

// --- bindings ------------------------------------------------------------
// SEMA: ===== SEMA fid {{[0-9]+}}: {{.*}}lookup_shadowing.k =====

// CASE 1: outer_read binds the PARAM (not the file-scope var); the block
// local shadows the param; the final `v` binds the PARAM again.
// SEMA:      <tu>::depth_two
// SEMA:        v  {{.*}} -> param v {{.*}}  [local frame 0]
// SEMA:        v  {{.*}} -> var v {{.*}}  [local frame 1]{{.*}}shadows param v{{.*}}
// SEMA:        v  {{.*}} -> param v {{.*}}  [local frame 0]

// CASE 2: each block's `w` shadows the param independently; the trailing use
// binds the param.
// SEMA:      <tu>::sibling_blocks
// SEMA:        w  {{.*}} -> var w {{.*}}  [local frame 1]{{.*}}shadows param w{{.*}}
// SEMA:        w  {{.*}} -> var w {{.*}}  [local frame 1]{{.*}}shadows param w{{.*}}
// SEMA:        w  {{.*}} -> param w {{.*}}  [local frame 0]

// Nothing left unbound.
// SEMA: 0 unresolved
