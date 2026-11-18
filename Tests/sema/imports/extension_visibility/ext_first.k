import ext::*
import user::*
import viahub::*
fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// A file sees an `extend` block only from its own file, a file its
// imports reach (viahub.k through hub.k's `pub import ext::*`), the file
// declaring the extended type (shapes.k's `half`), or the builtin files.
// user.k imports shapes.k alone, so ext.k's `twice` (an `extend ... impl`
// member) and its `op +` are not visible there in EITHER import order of
// this main; before the fix the result depended on whether ext.k had been
// checked first. The note names the extending file and the fix-it imports it.
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK:      user.k:3:13: error [SC066E]: no operator '+' for operands 'Point' and 'Point'
// CHECK-NEXT: user.k:4:14: error [R025E]: no member named 'twice' in 'Point'
// CHECK-NEXT: fix-it:"{{.*}}user.k":{1:17-1:17}:"\nimport self::ext"
// CHECK-NEXT: ext.k:3:1: note [I900N]: an extension of 'Point' in 'ext.k' declares 'twice'; import it to use it
