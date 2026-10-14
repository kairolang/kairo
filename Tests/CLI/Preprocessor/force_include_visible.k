// --force-include <file> behaves as if the main file began with
// `import <file>::*`: the file's public declarations are visible without any
// import statement. Before the fix the file was parsed but its names never
// reached the entry TU, so `helper` was reported undeclared (R020E).

fn main() -> i32 { return helper() }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only --force-include=%S/Inputs/helper_prelude.k 2>&1 || true; } | %FileCheck %s --allow-empty
// CHECK-NOT: error
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=NOFLAG
// NOFLAG: error [R020E]
