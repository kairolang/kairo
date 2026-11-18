// The bytes each escape form decodes to, as lowering hands them to codegen:
// the one-letter escapes, octal with one to three digits, `\x` with exactly
// two hex digits, `\u` with four and `\U` with eight (each written as
// UTF-8, `\xff` and `\377` included), a raw segment copied as written, and
// adjacent segments joined with each segment's own raw-ness. The lengths
// after each literal are its bytes and its code points. A string pattern is
// decoded the same way.
fn take(const s: string) -> usize { return s.size() }
fn main() -> i32 {
    var n: usize = 0
    n += take("simple: \n\r\t\v\f\a\b")
    n += take("quotes: \' \" \\")
    n += take("octal: \0 \7 \12 \101 \377 \1019")
    n += take("hex: \x00 \x41 \x7f \xff \x4a4")
    n += take("u4: A é € ￿")
    n += take("u8: \U00000041 \U0001F600 \U0010FFFF")
    n += take(r"raw: \n \x41 \101 \\ end")
    n += take("utf8: é € 😀")
    n += take("chain: \x41" "\102" r"\n" "C")
    n += take(r"raw head \t" "cooked \t" r"raw \t")
    n += take("")
    n += take("" "tail\n")
    match "a\tb" {
        case "a\tb" { n += 1 }
        case "\x41" "\102" r"\n" { n += 2 }
        case r"\x41" { n += 3 }
        default { }
    }
    return (n % 251) as i32
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --print-ir -c -o /dev/null --emit-scope=inputs -A S025W | %FileCheck %s
// CHECK: ("simple: \012\015\011\013\014\007\010"), 15, 15)
// CHECK: ("quotes: ' \" \\"), 13, 13)
// CHECK: ("octal: \000 \007 \012 A \303\277 A9"), 20, 19)
// CHECK: ("hex: \000 A \177 \303\277 J4"), 16, 15)
// CHECK: ("u4: A \303\251 \342\202\254 \357\277\277"), 16, 11)
// CHECK: ("u8: A \360\237\230\200 \364\217\277\277"), 15, 9)
// CHECK: ("raw: \\n \\x41 \\101 \\\\ end"), 24, 24)
// CHECK: ("utf8: \303\251 \342\202\254 \360\237\230\200"), 17, 11)
// CHECK: ("chain: AB\\nC"), 12, 12)
// CHECK: ("raw head \\tcooked \011raw \\t"), 25, 25)
// CHECK: (""), 0, 0)
// CHECK: ("tail\012"), 5, 5)
// CHECK: ("a\011b"), 3, 3)
// CHECK: ("a\011b"), 3) == 0
// CHECK: ("AB\\n"), 4) == 0
// CHECK: ("\\x41"), 4) == 0
