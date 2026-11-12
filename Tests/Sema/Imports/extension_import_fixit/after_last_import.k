import self::other
import self::other::one
fn main() -> i32 { return 3.twice() - 6 + one() - 1 }

// --- lit wiring -----------------------------------------------------------
// The fix-it goes after the import that ends last in the text. The TU's
// import list is not in source order: the prelude's import, which the file
// did not write, comes last with a range at the file's first byte, so the
// insertion landed at the end of line 1.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: after_last_import.k:3:29: error [R025E]: no member named 'twice' in 'i32'
// CHECK: fix-it:"{{.*}}after_last_import.k":{2:24-2:24}:"\nimport self::twice"
