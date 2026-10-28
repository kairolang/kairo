// std::c_char as a value (Lib/std/ctypes.k): a character, not a number.
// A literal takes it in 0..=127, where C's signed and unsigned char agree;
// `as` converts it to and from the integers; `==` and `<` compare it; it
// formats as its code (as u8, so 0..=255 on every target); a generic takes
// it as T; and `200u8 as c_char` round-trips through the target's char.

import std::io::println
import std::c_char

fn <T> echo(x: T) -> T { return x }

fn is_digit(c: c_char) -> bool { return (c >= 48) && (c <= 57) }

fn main() -> i32 {
    var r = 0
    var a: c_char = 65
    var z: c_char = 0
    if a == 65 { r += 1 }
    if (a > z) && (z < 1) { r += 2 }
    if (a as i32) == 65 { r += 4 }
    var hi = 200u8 as c_char                    // the byte, whatever char's sign
    if (hi as u8) == 200 { r += 8 }
    if (hi as i8) == -56 { r += 16 }
    if echo(a) == a { r += 32 }
    if is_digit(55) && (!is_digit(a)) { r += 64 }
    println(f"{a} {z} {hi} {echo(a)}")
    return r
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX: template<class T> T echo(T x) noexcept;
// CXX: bool is_digit(char c) noexcept;
// CXX: char hi = static_cast<char>((static_cast<unsigned char>(200)));

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d 2>&1 | %FileCheck %s --check-prefix=BUILD --allow-empty
// BUILD-NOT: {{error|warning}}
// RUN: %t.exe > %t.out; test $? -eq 127
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: 65 0 200 65
