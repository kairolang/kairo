import self::loader
import lib2::two::two_v
fn main() -> i32 { return 3.quad() + two_v() + loader::loaded() - 14 }

// --- lit wiring -----------------------------------------------------------
// lib2/quad.k is a file of another module that the module exports
// (lib2/module.k has `pub import self::quad`), so the fix-it imports the
// module, not the file. loader.k brings lib2 into the build through a
// `priv import`, which carries nothing here.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: module_exports.k:3:29: error [R025E]: no member named 'quad' in 'i32'
// CHECK: fix-it:"{{.*}}module_exports.k":{2:24-2:24}:"\nimport self::lib2"
