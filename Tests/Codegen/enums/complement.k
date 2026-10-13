// `~` complements in its operand's type, not on the infinite two's
// complement form the other bitwise operators use: a discriminant's literal
// takes the underlying type, so `~0` is that type's all-ones value, 2^32 - 1
// in a u32 enum and 255 in a u8 one, and -1 only in a signed one. An earlier
// variant reads as the underlying integer too, so `~A` flips its 32 bits.

enum Flags derives u32 { None = 0, A = 1, All = ~0, NotA = ~A }

enum Small derives u8 { None = 0, All = ~0, NotBit2 = ~(1 << 2) }

enum Signed derives i32 { Ones = ~0, NotFive = ~5 }

fn main() -> i32 {
    var r: i32 = 0;
    if (Flags::All as u32) == 4294967295 { r = r + 1; }
    if (Small::All as u8) == 255 { r = r + 2; }
    if (Signed::Ones as i32) == (0 - 1) { r = r + 4; }
    return r;   // 7
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      enum class Flags : unsigned int {
// CXX-NEXT:     None = 0, A = 1, All = 4294967295, NotA = 4294967294, };
// CXX:      enum class Small : unsigned char {
// CXX-NEXT:     None = 0, All = 255, NotBit2 = 251, };
// CXX:      enum class Signed : signed int {
// CXX-NEXT:     Ones = -{{ ?}}1, NotFive = -{{ ?}}6, };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
