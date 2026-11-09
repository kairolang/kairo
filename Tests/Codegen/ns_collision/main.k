// A file named main.k is module `main`, and its decls other
// than `fn main` would open C++ `namespace main` beside the program's
// global `int main` ("redefinition of 'main' as different kind of
// symbol"). The namespace is renamed by the fixed rule: one `_` appended,
// `main_` (Compiler/Spec/Codegen.md, Top-level namespace collisions). Kairo
// source still calls it `main`.

fn helper() -> i32 { return 40 }
fn other() -> i32 { return 2 }

fn main() -> i32 {
    return helper() + other()
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: { %kairo %s -o %t.exe --cache-dir %t.d --print-ir 2>&1 || true; } | %FileCheck %s
// RUN: %t.exe; test $? -eq 42
// CHECK: namespace main_ {
// CHECK: ::main_::helper()
// CHECK: ::main_::other()
