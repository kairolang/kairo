// `ptr as usize` reads the address (casting.md, Pointer to integer): safe,
// no `unsafe` block, and the second base of a class sits at a different
// address than the first.
//
// XFAIL: *
// Waiting on codegen: the cast is emitted as static_cast<size_t>(p), which
// clang rejects (CL001E "static_cast from 'int *' to ... 'unsigned long' is
// not allowed"); it needs reinterpret_cast or __builtin_bit_cast.
// When it lands this test XPASSes; delete the XFAIL -- the run below is
// already the real assertion.

class R { prot var a: i32  virtual fn r(self) -> i32 { return 1 } }
class W { prot var b: i32  virtual fn w(self) -> i32 { return 2 } }
class F derives R, W { }

fn main() -> i32 {
    var r = 0
    var x: i32 = 5
    var *p = &x
    if (p as usize) != 0 { r += 1 }
    var f = F()
    var pr: *R = &f
    var pw: *W = &f
    if (pr as usize) == (&f as usize) { r += 2 }
    if (pw as usize) > (pr as usize) { r += 4 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 7
