// `fn op panic` (PANIC.md §1.5) has no C++ operator to become, so it is a
// named member, minted through LowerTargets::op_panic like `op await`: a
// type's own as a method, an extension's as the scope's static member
// (CODEGEN.md §7b). Nothing calls it yet -- the C++ view's what() will
// (P7) -- so this only pins that a program declaring it compiles, links
// and runs. Before the name existed, an extension `op panic` was an ICE in
// CXXSpell ("has no C++ non-member form").

class ConfigError {
    var key: i32
    fn op panic (const self) -> string { return "missing config key" }
}

struct Plain { var n: i32 }

extend Plain {
    fn op panic (const self) -> string { return "plain" }
}

fn main() -> i32 {
    var e = ConfigError()
    return 0
}

// --- lit wiring ---
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:     ::builtin::string::string __kairo_op_panic() const noexcept;
// CXX:     ::builtin::string::string ConfigError::__kairo_op_panic() const noexcept {
// CXX-NOT: operatorpanic
//
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
