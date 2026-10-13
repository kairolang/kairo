// Discriminants are evaluated in Sema, and the C++ enum is written from the
// computed values, never from the source text: `Masked` names a Kairo
// constant whose spelling C++ does not know. `as` keeps the low bits
// (300 as u8 is 44; -1 as u64 is 2^64 - 1); a variant with no discriminant
// is one past the previous; an enum with no discriminant at all keeps C++'s
// own numbering and goes out bare.

const MASK: u8 = 0xF0;
const BIG: u32 = 300;
const MINUS_ONE: i64 = 0 - 1;

enum FileMode derives u8 { Read = 1 << 0, Write = 1 << 1, Exec = Read << 2, RW = Read | Write }

enum Mixed { Ok = 200, NotFound = 404, Teapot, Wrapped = BIG as u8, Masked = MASK | 0x0F }

enum Wide derives i64 { Min = 0 - 9223372036854775807 - 1, AfterMin, Neg = 0 - 5 }

enum Huge derives u64 { Max = MINUS_ONE as u64, Top = 18446744073709551614 }

enum Plain { A, B, C }

// Exact arithmetic on the infinite two's complement form: the bitwise
// operators see a negative as all ones above its low bits, and `>>` floors.
enum Ops derives i32 { Ones = ~0, Low = (0 - 1) & 0xFF, Floor = (0 - 5) >> 1, Flip = (0 - 1) ^ 1, Prod = (0 - 3) * 4, Mix = Low + Floor }

fn main() -> i32 {
    return (FileMode::Exec as u8) + (FileMode::RW as u8);   // 4 + 3
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      enum class FileMode : unsigned char {
// CXX-NEXT:     Read = 1, Write = 2, Exec = 4, RW = 3, };
// CXX:      enum class Mixed : unsigned int {
// CXX-NEXT:     Ok = 200, NotFound = 404, Teapot = 405, Wrapped = 44, Masked = 255, };
// CXX:      enum class Wide : signed long {
// CXX-NEXT:     Min ={{ ?}}(-{{ ?}}9223372036854775807 - 1), AfterMin = -{{ ?}}9223372036854775807, Neg = -{{ ?}}5, };
// CXX:      enum class Huge : unsigned long {
// CXX-NEXT:     Max = 18446744073709551615u, Top = 18446744073709551614u, };
// CXX:      enum class Plain : unsigned int {
// CXX-NEXT:     A, B, C, };
// CXX:      enum class Ops : signed int {
// CXX-NEXT:     Ones = -{{ ?}}1, Low = 255, Floor = -{{ ?}}3, Flip = -{{ ?}}2, Prod = -{{ ?}}12, Mix = 252, };

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -c --cache-dir %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 7
