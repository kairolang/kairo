// A builtin type's own `op in (self) -> yield T` drives `for ... in`, as any
// record's does (RESOLUTION.md, "A builtin type's declared operator wins").
// The IterKind::Vector / String shapes are only the fallback for a builtin
// that declares no iteration form, and that fallback is still SC116E.
//
// Lib/builtin declares no operator on either type and is not this test's to
// change, so the operators come from extensions in this file. string runs:
// its literal constructor has a body. A vector has no constructor body yet
// (Lib/builtin's API is unwritten), so `sum` is never called: it is still
// compiled and linked, which is what proves the lowering, and its loop is
// checked in the emitted C++.

extend string {
    fn op in (self) -> yield u8 {
        var i: usize = 0
        while i < self.len {
            var b = self.data[i]
            yield b
            i = i + 1
        }
    }
}

extend <T> [T] {
    fn op in (self) -> yield T {
        var i: usize = 0
        while i < self.len {
            var e = self.data[i]
            yield e
            i = i + 1
        }
    }
}

fn sum(v: [i32]) -> i32 {
    var t: i32 = 0
    for x in v { t += x }
    return t
}

fn main() -> i32 {
    var n: i32 = 0
    for c in "abcd" { n += (c as i32) - 96 }    // 1 + 2 + 3 + 4
    var s = "xy"
    for c in s { n += 1 }                       // an lvalue receiver
    return n                                    // 12
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// Both loops call the declared operator; neither is the built-in shape.
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-NOT: Internal Compiler Error
// CXX: Yield<signed int> __kairo_it{{[0-9]+}} = {{.*}}Vector::__kairo_iter<signed int>(v);
// CXX: Yield<unsigned char> __kairo_it{{[0-9]+}} = {{.*}}string::__kairo_iter(__kairo_seq{{[0-9]+}});
// CXX: Yield<unsigned char> __kairo_it{{[0-9]+}} = {{.*}}string::__kairo_iter(s);

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
