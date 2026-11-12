// `as` reaches every conversion cxx_implicit_conv_split.k exercises, under
// all four settings of -f[no-]implicit-conv x -f[no-]cxx-implicit-conv.
// Under -fno-implicit-conv the builtin library itself does not type-check
// (Tests/CLI/Lang/fimplicit_conv.k), so those two runs assert only that
// this file's lines have no error.
ffi "c++" import "cxx_user_conversion.h"
ffi "c++" import "cxx_implicit_conv_split.h"

fn wide(x: i64) -> i64 { return x }

fn main() -> i32 {
    var a = A(7)
    var k: i32 = 3
    var n = len("hello" as View)
    n += take(a as B)
    var v: View = "hi" as View
    n += takew(k as i64 as Wide)
    return n + len(v) + (wide(k as i64) as i32)
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d1 %t.d2
// RUN: %kairo %s -o %t1.exe --cache-dir %t.d1
// RUN: %t1.exe; test $? -eq 20
// RUN: %kairo %s -fcxx-implicit-conv -o %t2.exe --cache-dir %t.d2
// RUN: %t2.exe; test $? -eq 20
// RUN: { %kairo %s --type-check-only -fno-implicit-conv 2>&1 || true; } | %FileCheck %s
// RUN: { %kairo %s --type-check-only -fno-implicit-conv -fcxx-implicit-conv 2>&1 || true; } | %FileCheck %s
// CHECK: {{error}}
// CHECK-NOT: cxx_implicit_conv_split_as.k:{{[0-9]+}}:{{[0-9]+}}: error
