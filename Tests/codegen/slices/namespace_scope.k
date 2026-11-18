// A slice literal that initializes a namespace-scope variable (a
// file-scope `var`, a `const`, a variable in a `module` block, a slice of
// slices) gets a namespace-scope backing array, defined just ahead of the
// owner in the same scope. It was an ICE: at file scope EmitIR found no
// immediate table for the minted local (it had no scope), and in a module
// block ListLiteralLowering had nowhere to put it. A later namespace-scope
// variable reads the slice in its own initializer, which C++ runs after the
// owner's (definition order within a TU).

var top: [i32;] = [1, 2, 3]
var nested: [[i32;];] = [[4, 5], [6]]
const fixed: [i32;] = [10, 20]

module m {
    pub var inner: [i32;] = [7, 8, 9]
    pub var more: [i32;] = [100]
}

var after: i32 = top[2] + 1

fn main() -> i32 {
    var s = top[0] + top[1] + top[2]              // 6
    s += nested[0][1] + nested[1][0]              // 11
    s += m::inner[2] + m::more[0]                 // 109
    s += fixed[1] + after                         // 24
    s += (nested.len + m::inner.len) as i32       // 5
    return s - 150                                // 5
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Each backing is a namespace-scope array named after its owner, defined
// before it in the owner's namespace.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: namespace_scope {
// IR: __kairo_slice_top_{{[0-9]+}}[3] = {
// IR: ::builtin::containers::slice::Slice<signed int> top =
// IR: namespace_scope::m {
// IR: __kairo_slice_inner_{{[0-9]+}}[3] = {
// IR: ::builtin::containers::slice::Slice<signed int> inner =

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 5
