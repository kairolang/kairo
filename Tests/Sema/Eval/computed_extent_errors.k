eval fn twice(x: usize) -> usize { return x * 2 }
fn plain(x: usize) -> usize { return x }
eval HALF = twice(2)

class Holder {
    pub var a: [i32; twice(2)]
}

fn takes(a: [i32; HALF]) -> i32 { return 0 }

class <eval N: usize> Dep {
    pub var a: [i32; twice(N)]
}

class <eval N: usize> Buf { pub var v: i32 }

fn main() -> i32 {
    var n: usize = 3
    var x: [i32; plain(3)]
    var y: [i32; n]
    var z = Buf<plain(1)>()
    return 0
}

// EVAL.md 0.2. An extent or value argument C++ computes from an eval call
// or an eval constant that does not fold is accepted in a function body;
// in a declaration's type (a field, a parameter) C++ would read it before
// any consteval body is defined, so it is SC116E there, a value
// parameter's dependence notwithstanding. A call of a function that is not
// `eval` is an error with a fix-it; a run-time variable is one too.
// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: computed_extent_errors.k:6:22: error [SC116E]: an array length computed by C++ from an 'eval' call or an 'eval' constant that does not fold is not yet supported in a declaration's type; write it inside a function body, or make the constant fold
// CHECK: computed_extent_errors.k:9:19: error [SC116E]: an array length computed by C++
// CHECK: computed_extent_errors.k:12:22: error [SC116E]: an array length computed by C++
// CHECK: computed_extent_errors.k:19:18: error [SC001E]: an array length can call only 'eval' functions; 'plain' is not 'eval'
// CHECK-NEXT: fix-it:"{{.*}}computed_extent_errors.k":{2:1-2:1}:"eval "
// CHECK-NEXT: computed_extent_errors.k:2:1: note [SC001N]: 'plain' is declared here
// CHECK: computed_extent_errors.k:20:18: error [SC001E]: an array length must be an 'eval' constant; 'n' is a variable
// CHECK: computed_extent_errors.k:21:17: error [SC001E]: a generic value argument can call only 'eval' functions; 'plain' is not 'eval'
