// A string is a C++ literal type, so an `eval` binding of one is a constexpr
// variable clang accepts: its pointer field is a union of niche-filled
// nullable pointers, and every member of that record and of the niche trait
// is constexpr. An `eval fn` that builds a string from a literal, or takes
// one by value, is a constant expression.

eval LIT: string = "abc"
eval JOINED: string = "de" "f"
eval fn greet() -> string { return "hello" }
eval fn width(s: string) -> i32 { return 2 }
eval G = greet()
eval W = width("xy")

fn main() -> i32 {
    var g = greet()
    // 3 + 3 + 5 + 5 + 2 == 18
    return (LIT.size() + JOINED.size() + G.size() + g.size()) as i32 + W
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --type-check-only --print-cxx 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: static constexpr T* pattern(unsigned long) noexcept {
// CXX: constexpr Null() noexcept : __kairo_Value {

// REQUIRES: clang
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 18
