// A literal is the borrowed constructor: static bytes, byte and codepoint
// counts, cap 0. Every escape the lexer accepts decodes here; adjacent parts
// are one literal; raw copies verbatim.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn main() -> i32 {
    var s = "Hello, Kairo! 📣"            // 18 bytes, 15 codepoints
    var t = "a" "b"                       // 2, 2
    var u = "\x27\n\U0001F4E3"            // 1 + 1 + 4 bytes, 3 codepoints
    var r = r"\n"                         // 2 raw bytes
    // 18 + 15 + 2 + 6 + 3 + 2 + 1 == 47
    return ((s.length() + s.codepoints() + t.length() + u.length() + u.codepoints() + r.length()) as i32) + chk(s.capacity() == 0)
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: CODEGEN C++: {{.*}}strings/literal.k
// The literals are emitted as one static record each: codepoint count, then the bytes and a NUL.
// IR: __kairo_slit_t<19> __kairo_slit_18_{{[0-9a-f]+}} = {
// IR-NEXT: 15, {
// IR-NEXT: 72, 101, 108, 108, 111, 44, 32, 75, 97, 105, 114, 111, 33, 32, 240, 159, 147, 163, 0
// IR: __kairo_slit_t<3> __kairo_slit_2_{{[0-9a-f]+}} = {
// IR-NEXT: 2, {
// IR-NEXT: 97, 98, 0
// IR: __kairo_slit_t<7> __kairo_slit_6_{{[0-9a-f]+}} = {
// IR-NEXT: 3, {
// IR-NEXT: 39, 10, 240, 159, 147, 163, 0
// IR: __kairo_slit_t<3> __kairo_slit_2_{{[0-9a-f]+}} = {
// IR-NEXT: 2, {
// IR-NEXT: 92, 110, 0

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 47
