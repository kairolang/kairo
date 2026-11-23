// RUN: { %kairo %S/inputs/reserved_mod/lib.k --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=MOD
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=TOP
//
// A plain leading underscore (SC005W) is reported only on a declaration C++
// code can name: `pub` anywhere, and an unmarked or `prot` one in a file under
// a module.k, which the directory's C++ files see. `priv`, parameters and
// locals draw nothing, and in a file with no module.k an unmarked declaration
// is private, so it draws nothing either.

pub fn _top_pub() -> i32 {
    return 1
}

fn _top_plain() -> i32 {
    return 2
}

// MOD-DAG: lib.k:1:8: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// MOD-DAG: lib.k:5:4: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// MOD-DAG: lib.k:9:9: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// MOD-DAG: lib.k:19:13: warning [SC005W]: field name begins with an underscore, and C++ code can name it
// MOD-NOT: begins with an underscore,

// TOP: cxx_reserved_exported.k:10:8: warning [SC005W]: function name begins with an underscore, and C++ code can name it
// TOP-NOT: begins with an underscore,
