// A static array field's initializer, and a field that is an array of
// arrays (classes.mdx, collections.mdx: a field default like any other).
// FieldInitLowering makes a thunk of each LEAF element, in row-major order
// (no C++ function returns an array); a static's thunks are static and its
// out-of-line definition lists their calls, and an array of arrays is braced
// per dimension from the field's type.

fn tick(x: i32) -> i32 { return x + 1 }

class C {
    pub static s: [i32; 3] = [1, tick(1), 3]
    pub var g: [[i32; 2]; 2] = [[1, tick(1)], [3, 4]]
    pub static t: [[[i32; 2]; 2]; 2] = [[[1, 2], [3, 4]], [[5, 6], [7, tick(7)]]]
}

struct P {
    pub var m: [[i32; 3]; 2] = [[1, 2, 3], [4, 5, tick(5)]]
}

fn main() -> i32 {
    var c = C()
    var p = P{}
    var r = 0
    if C::s[1] != 2       { r += 1 }
    if c.g[0][1] != 2     { r += 2 }
    if c.g[1][0] != 3     { r += 4 }
    if C::t[1][1][1] != 8 { r += 8 }
    if C::t[0][1][0] != 3 { r += 16 }
    if p.m[1][2] != 6     { r += 32 }
    if p.m[0][0] != 1     { r += 64 }
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      signed int g[2][2] = {
// CXX-NEXT:   {
// CXX-NEXT:     __kairo_init0_g(), __kairo_init1_g()
// CXX-NEXT:   }
// CXX-NEXT:   , {
// CXX-NEXT:     __kairo_init2_g(), __kairo_init3_g()
// CXX:      inline signed int C::s[3] = {
// CXX-NEXT:   __kairo_init0_s(), __kairo_init1_s(), __kairo_init2_s()
// CXX:      inline signed int C::t[2][2][2] = {
// CXX-NOT: {{(error|warning) @}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 0
