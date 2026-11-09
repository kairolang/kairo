// RUN: { %kairo %s -I %S --type-check-only --error-format=basic 2>&1 || true; } | %FileCheck %s --allow-empty
//
// Members a C++ class inherits (`size`, `push_back`, `data`) were
// "no member named" (R025E) when the template's FIRST header set only
// declared it (this file, decl.h: as <clang/Lex/DependencyDirectivesScanner.h>
// declares SmallString) while the demanding TU's set (ext.k, def.h) holds the
// definition. The primary's set could not complete the instance and the fill
// gave up instead of retrying in the demanding TU's set.
// CHECK-NOT: error

ffi "c++" import "decl.h"
import ext::*

fn main() -> i32 { return count() as i32 }
