// --emit-headers DIR writes the generated headers into DIR, creating it. The
// builtin header is always written, and this file's own: an input is a module
// like any import (decision C), so it has a header -- without `main`, which
// is the program's global `int main`, declared by no header.

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.hdr
// RUN: %kairo %s --type-check-only --emit-headers %t.hdr
// RUN: test -f %t.hdr/builtin.hh
// RUN: test -f %t.hdr/emit_headers.hh
// RUN: %FileCheck %s --input-file=%t.hdr/emit_headers.hh
// CHECK: #pragma once
// CHECK-NOT: main
