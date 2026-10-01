// rule: `Lib/std` is a root NAMED `kairo::std` and SPELLED `std`. The name is
// its identity, so every declaration in it is `kairo::std::…` and emits into
// `::kairo::std` -- a namespace that can never collide with C++'s own `std`.
// The spelling is what source writes to import it. There is no std prelude:
// std_no_import.k is the other half of this rule.

import std
import std::io

fn use_std() -> void {
    io::println("7")          // `import std::io` binds `io`
    std::io::println("8")     // `import std` binds `std`, its module.k re-exports `io`
}

// --- lit wiring -----------------------------------------------------------
//
// 1. both spellings resolve into std's own files: `std` binds the root's
//    module.k through the overlay, and both `println` steps reach the one
//    decl in io.k. The NAME (`kairo::std`) is check 3's; --print-sema prints
//    decls by their leaf name and never shows a module path.
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}Lib/std/io.k
// SEMA:      ===== SEMA fid {{[0-9]+}}: {{.*}}std_root.k
// SEMA:      member  ::println   @ 11:9     -> fn println @ 20:5
// SEMA:      use     std         @ 12:5     -> module std @ 1:1  [import overlay]
// SEMA:      member  ::println   @ 12:14    -> fn println @ 20:5
//
// 2. builtin is the only prelude; std arrives through the file's own imports.
// RUN: { %kairo %s --type-check-only --print-imports 2>/dev/null || true; } | %FileCheck %s --check-prefix=IMP
// IMP: <prelude> import builtin::*
// IMP-NOT: <prelude> import kairo::std
//
// 3. the emitted spelling carries the NAME, never the spelling. `::std::io`
//    here would mean kairo's standard library had been emitted into C++'s
//    namespace, which is the collision this whole design exists to prevent.
// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: namespace kairo::std::io {
// CXX: println
//
// 4. nothing is diagnosed in the ordinary case.
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}} [
//
// 5. --no-stdlib removes the root, so `import std` is an ordinary unresolved
//    import -- the point being that `std` is a root like any other, with no
//    special case anywhere to keep it alive.
// RUN: { %kairo %s --type-check-only --no-stdlib 2>&1 || true; } | %FileCheck %s --check-prefix=NOSTD
// NOSTD: error [R011E]
// NOSTD-SAME: 'std'
