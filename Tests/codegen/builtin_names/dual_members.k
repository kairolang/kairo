// The string members that read the same on the four-word and the two-word
// library: a range subscript, `to_owned`, `push` of a character and
// `push_str`. A range is checked: it lies inside the string and cuts no
// multibyte character. `s.data()[i]` is the byte at offset i on both.
import std::io::println

fn hex(const s: string) -> string {
    var digits = "0123456789abcdef"
    var out: string = ""
    for var i: usize = 0; i < s.size(); ++i {
        var b = s.data()[i]
        out.push(digits.data()[(b >> 4) as usize])
        out.push(digits.data()[(b & 15) as usize])
    }

    return out
}

fn main() -> i32 {
    var src = "naïve café"
    println(src[2..4])
    println(src[7..])
    println(src[..2].to_owned())
    println(src[0..=1])
    println(f"{src[12..].size()} {src[4..4].size()}")

    var s: string = ""
    s.push('a')
    var b: u8 = 0x41
    s.push(b)
    s.push('é')
    s.push('€')
    s.push('𝄞')
    s.push_str("xy")
    s.push_str(src[2..4])
    println(f"{hex(s)} {s.size()} {s.codepoints()}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// CHECK:      ï
// CHECK-NEXT: café
// CHECK-NEXT: na
// CHECK-NEXT: na
// CHECK-NEXT: 0 0
// CHECK-NEXT: 6141c3a9e282acf09d849e7879c3af 15 8
