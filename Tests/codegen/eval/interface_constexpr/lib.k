// Eval bindings an importer reads (EVAL.md 1.2b): definitions, in order.
pub eval fn cube(x: i32) -> i32 { return x * x * x }
pub eval NEXT: i32 = N + 1                  // reads N, declared below
pub eval N: i32 = cube(2)                   // C++ computes it: 8
pub eval K: i32 = 3                         // Sema folds it
pub eval TAG = "lib"
