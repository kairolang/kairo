// `T?` is the Null lang item to C++. With no builtin root to declare it,
// a written `T?` is the same error as any other missing lang item (R055E),
// at the type, rather than a codegen abort.

fn main() -> i32? { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d && mkdir -p %t.d/builtin
// RUN: { %kairo %s --type-check-only --builtins-dir=%t.d/builtin 2>&1 || true; } | %FileCheck %s
// CHECK: nullable_no_builtin_root.k:5:14: error [R055E]: lang item 'Null' is not declared in the builtin root
// CHECK-NOT: Internal Compiler Error
