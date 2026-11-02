// Heap allocation with `@create T(args)` in expression position
// (attributes.mdx; modules.mdx: `var *p = @create i32(42)`). The sugar is a
// call of alloc.k's create (P91, Sema/Expand/AllocSugarDesugar.k), so alloc.k
// must be visible: the builtin prelude does not re-export it.

import builtin::base::alloc::*

fn main() -> i32 {
    var *p = @create i32(42)
    return *p
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
