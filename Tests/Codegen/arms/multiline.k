fn pick(c: i32) -> i32 = if c == 0
    => 10
    else if c > 5
    => 20
    else
    => 30

fn f2(x: i32, y: i32) -> i32 = x + y

fn main() -> i32 {
    var a = pick(0) + pick(9) + pick(3)
    var d = f2(if a > 0 =>
        1
    else =>
        0, 2)
    var e = if a < 0 =>
        0
    else =>
        a +
        1
    return a + d + e - 114
}

// --- lit wiring -----------------------------------------------------------
// values.k with every arm split across lines: `=>` opening a line, `else`
// opening a line, the value on the line after `=>`, and a value continued
// after a trailing operator. Same exit code, and the same lowering: the C++
// preamble and the emitted bodies match values.k once the module name (taken
// from the file name) is normalized.
//
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %S/values.k --print-cxx 2>&1 || true; } | sed -e 's/namespace values /namespace MOD /; s/::values::/::MOD::/g; s|arms/values\.k|arms/MOD.k|' > %t.values.cxx
// RUN: { %kairo %s --print-cxx 2>&1 || true; } | sed -e 's/namespace multiline /namespace MOD /; s/::multiline::/::MOD::/g; s|arms/multiline\.k|arms/MOD.k|' > %t.multiline.cxx
// RUN: diff %t.values.cxx %t.multiline.cxx
// RUN: { %kairo %S/values.k --print-ir 2>&1 || true; } | sed -e 's/namespace values /namespace MOD /; s/::values::/::MOD::/g; s|arms/values\.k|arms/MOD.k|' > %t.values.ir
// RUN: { %kairo %s --print-ir 2>&1 || true; } | sed -e 's/namespace multiline /namespace MOD /; s/::multiline::/::MOD::/g; s|arms/multiline\.k|arms/MOD.k|' > %t.multiline.ir
// RUN: diff %t.values.ir %t.multiline.ir

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 10
