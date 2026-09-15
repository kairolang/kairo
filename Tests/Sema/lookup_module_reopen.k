module Util {
    fn a() -> i32 { return 1 }
    class P { var n: i32; }
}

module Util {
    fn b() -> i32 { return a() + 1 }
    fn uses_p() -> i32 { var p: *P = &null; return 0 }
}

fn use_util() -> i32 {
    var p: *Util::P = &null;
    return Util::a() + Util::b()
}

// --- lit wiring -----------------------------------------------------------
// Two `module Util { }` blocks in one TU are ONE module reopened, like a C++
// namespace (RESOLUTION.md §2.7, IMPORTS.md §4.3):
//
//   - N(a) links them into one redecl ring and does NOT report a
//     redefinition: every module block is a definition, and a module has no
//     ODR definition to duplicate (NameResolution::_reopenable).
//   - Unqualified lookup inside a block sees every block of the ring
//     (NameLookup::module_scopes via unqualified): `a()` in block 2 binds to
//     block 1's `a`, and `P` in block 2 to block 1's class. There is no
//     declaration-order rule -- "as if both were written as one block".
//   - `Util::` reaches both blocks. N collapses `Util` to the canonical (the
//     first block), so the Module anchor expands a single decl to its ring:
//     `Util::b` finds block 2's `b`. Type position (`*Util::P`) goes through
//     TypeResolve::_append_module_scopes, the same expansion.
//
// Ported from (semantic content only):
//   Lib/llvm-runtimes/clang/test/SemaCXX/namespace.cpp (the "reopen and
//   add a member visible to the reopened namespace's siblings" half)
//   Lib/llvm-runtimes/clang/test/CXX/basic/basic.scope/basic.scope.namespace/
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// DIAG-NOT: {{error|warning}} [
//
// SEMA:      phase: Checked
// SEMA:      <tu>::Util [redecl chain x2]
// SEMA-NEXT: - module Util @ 1:1 [definition] [canonical]
// SEMA-NEXT: - module Util @ 6:1 [definition]
// SEMA:      -- name bindings --
// SEMA:      <tu>::Util::b
// SEMA-NEXT: a @ 7:{{[0-9]+}} -> fn a @ 2:5 [scope Util]
// SEMA:      <tu>::use_util
// SEMA:      ::a @ 13:{{[0-9]+}} -> fn a @ 2:5
// SEMA:      ::b @ 13:{{[0-9]+}} -> fn b @ 7:5
