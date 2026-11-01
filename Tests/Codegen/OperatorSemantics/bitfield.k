// OperatorSemantics: a compound assignment or `++` on an imported
// bit-field wraps at the field's width. No `auto&` binds a bit-field, so the
// object is bound instead (when it has an effect) and the field re-read
// through it; a plain object is simply read twice.

ffi "c" import "bitfield.h"

fn main() -> i32 {
    var b: Bits
    b.s = 15
    b.u = 7
    b.s += 1                                        // 16 at 5 signed bits: -16
    unsafe { pass_bits(&b as unsafe *Bits)->u += 1 } // 8 at 3 unsigned bits: 0
    b.u++                                           // 1
    return (b.s * 10 + (b.u as i32)) + 159          // -160 + 1 + 159 == 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: (b.s = static_cast<signed int>(static_cast<unsigned int>(b.s) + static_cast<unsigned int>(1)));
// CXX: auto && __kairo_p0 =({{.*}}pass_bits(
// CXX-NEXT: __kairo_p0->u = static_cast<unsigned int>(static_cast<unsigned int>(__kairo_p0->u) + static_cast<unsigned int>(1));
