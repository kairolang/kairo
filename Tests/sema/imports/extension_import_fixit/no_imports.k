import self::noimp
import self::twice
fn main() -> i32 { return noimp::six() - 6 }

// --- lit wiring -----------------------------------------------------------
// noimp.k uses an extension it does not import (this file loads
// twice.k into the build). With no import of its own to follow, the fix-it
// goes after the comment block the file opens with, not at the end of its
// first line (where the prelude's import, which has the file's first byte as
// its range, would put it).
// RUN: cd %S && { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --implicit-check-not="error ["
// CHECK: noimp.k:4:32: error [R025E]: no member named 'twice' in 'i32'
// CHECK: fix-it:"{{.*}}noimp.k":{2:74-2:74}:"\n\nimport self::twice"
