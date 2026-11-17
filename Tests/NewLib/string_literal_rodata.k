// A string literal of the two-word library is one read-only object,
// [cp_len: usize][bytes][0], and the string points at its bytes. Building a
// string from a literal is two constants and no call; the codepoint count
// of a literal is the word before its bytes; equal literals share an
// object, and so does every empty literal.

fn lit() -> string {
    return "héllo"
}

fn again() -> string {
    return "héllo"
}

fn empty_a() -> string {
    return ""
}

fn empty_b() -> string {
    return ""
}

fn main() -> i32 {
    var s = lit()
    if s.size() != 6 || s.codepoints() != 5 { return 1 }
    if !s.is_static() || s.is_owned() { return 2 }
    if s.data() != again().data() { return 3 }
    if empty_a().data() != empty_b().data() { return 4 }
    if empty_a().size() != 0 || empty_a().codepoints() != 0 { return 5 }

    // Writing through a literal-backed string copies it out first.
    var t = lit()
    t += "!"
    if !t.is_owned() || t.size() != 7 || t.codepoints() != 6 { return 6 }
    if lit().size() != 6 { return 7 }
    return 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe

// The object: a constant with a constant initializer, 5 codepoints, the
// six bytes and a NUL; the constructor takes its bytes member as it is.
// RUN: %kairo_new %s --print-ir 2>&1 | %FileCheck %s --check-prefix=IR
// IR:      template<decltype(sizeof(0)) N> struct __kairo_slit_t {
// IR-NEXT: decltype(sizeof(0)) cp;
// IR-NEXT: unsigned char b[N];
// IR:      inline constexpr::__kairo_slit_t<7> __kairo_slit_6_{{[0-9a-f]+}} = {
// IR-NEXT: 5, {
// IR-NEXT: 104, 195, 169, 108, 108, 111, 0
// IR:      inline constexpr::__kairo_slit_t<1> __kairo_slit_0_{{[0-9a-f]+}} = {
// IR-NEXT: 0, {
// IR-NEXT: 0
// IR:      string( ::__kairo_slit_6_{{[0-9a-f]+}}.b, 6, 5)
