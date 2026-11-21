// In an eval context `a.size()` is the extent only when reading `a` runs
// nothing: through a run-time index it is the slice view's run-time call,
// and the eval context's rules apply to it. A constant index folds.

fn main() -> i32 {
    var g: [[i64; 2]; 2] = [[1, 2], [3, 4]]
    var i: usize = 1
    eval k = g[i].size()
    eval j = g[1].size()
    return (k + j) as i32
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not='error ['
// CHECK: fixed_array_size_eval_errors.k:8:14: error [SC189E]: an eval context can call only 'eval' functions; 'size' is a function that is not 'eval'
// CHECK: fixed_array_size_eval_errors.k:8:14: error [SC189E]: an eval context reads only compile-time values; 'g' is a run-time local
// CHECK: fixed_array_size_eval_errors.k:8:16: error [SC189E]: an eval context reads only compile-time values; 'i' is a run-time local
