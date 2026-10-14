// --cmax-token-count caps the tokens the preprocessor may produce; exceeding
// it is S065E naming the limit and the flag. A generous limit compiles.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --cmax-token-count=5 2>&1 || true; } | %FileCheck %s
// CHECK: error [S065E]: preprocessor token budget exceeded in '{{.*}}cmax_token_count.k' (limit 5); raise it with --cmax-token-count=N
// RUN: %kairo %s --type-check-only --cmax-token-count=1000000
