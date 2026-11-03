// RUN: { %kairo %s --type-check-only --print-sema 2>&1 || true; } | %FileCheck %s --check-prefix=SEMA
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 21
//
// An imported function template returning a reference to its deduced
// parameter (`const T&`, `T&`, `T&&`): substituting the return type had no
// arm for a C++ reference, so the call typed as unknown with no diagnostic.
// `var req = std::max(a, b)` then reached codegen untyped (I011W) and the
// first member access through a value built from it was an EmitIR gate ICE
// ("unbound member step reached codegen"). Found compiling the migrated
// Memory/ArenaAllocator.k to an object (self-host phase 5.3).

ffi "c++" import "template_ref_return.h"

fn main() -> i32 {
    var n: i32 = 3
    var req = pick_max(n, 4)
    var b = make<Blk>(req)
    b->next = &null
    var m = 5
    var r = same(m)
    var k = moved(m)
    // 4 + 4 + 5 + 5 + 3 = 21
    return b->cap + req + r + k + n
}

// SEMA: SEMA fid {{[0-9]+}}: {{.*}}template_ref_return.k =====
// SEMA: -- inferred decls --
// SEMA-DAG: req : const i32&
// SEMA-DAG: r : i32&
// SEMA-DAG: k : i32&&
// SEMA-DAG: b : unsafe *Blk
