// A member type of an imported template's instance over a generic
// parameter (`traits<T>::size_type`) is dependent: the Kairo generic that
// names it is emitted as a template whose C++ says `typename
// traits<T>::size_type`, which clang resolves per instance.

ffi "c++" import "traits_typedef.h"

fn <T> gen(x: traits<T>::size_type) -> traits<T>::size_type { return x }

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s -I %S/../sema/ffi --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: %kairo %s -I %S/../sema/ffi --print-ir 2>/dev/null | %FileCheck %s --check-prefix=IR
// IR: typename{{.*}}traits<T>::size_type gen(typename{{.*}}traits<T>::size_type x)

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -I %S/../sema/ffi -o %t.exe --cache-dir %t.d
// RUN: %t.exe
