// RUN: { %kairo %s --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s
//
// An if-expression arm is a value: a C++ `T&` arm (`v[i]`) beside a `T` arm
// joins as T. Before G78 this was SC039E "'u64&' ... does not unify with
// the earlier 'u64'" (ImportProbe.k).

ffi "c++" import "vector"

fn pick(c: bool, i: usize) -> u64 {
    var v: cxx::std::vector<u64>
    v.push_back(1)
    var a: u64 = if c => v[i] else => 0
    var b: u64 = if c => 0 else => v[i]
    return a + b
}

fn bad(c: bool, i: usize) -> u64 {
    var v: cxx::std::vector<u64>
    return if c => v[i] else => "s"
}

// CHECK-NOT: if_expr_ref_branch.k:1{{[0-3]}}:{{.*}}error
// CHECK: if_expr_ref_branch.k:[[#]]:{{[0-9]+}}: error [SC039E]
