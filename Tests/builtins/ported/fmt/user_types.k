// Holes whose value is not a builtin type: a record with `op as` to string, one with `repr()`, one with both, one
// with neither (printed by address), a plain enum (printed as its integer), pointers, null pointers, nullable values
// whose non-null state is known, and generic holes. A user type reaches the formatter as the string its conversion
// returns, so its width, fill, alignment and precision are applied to that string; it has no other way to see them.
// Rules asserted (Compiler/Spec/FormatStrings.md, Hole facts: `repr()` is preferred, then `op as` returning string,
// `?` skips `op as`, a record with no conversion prints its address, a plain enum its underlying integer, a proven
// non-null nullable its value; Lib/builtin2/fmt/fmt_buf.k put_ptr: `<name> @ 0x<hex>` or `&null`; website
// language/generics.mdx, f-strings in a generic body: a hole is formatted per instance with the rules of a concrete
// value; spec grammar comment above `_parse_spec` in Compiler/Sema/Type/LiteralTyping.k: a record takes width,
// alignment and precision).
// Not asserted because the docs do not state them: the quoted text of `{x:?}` on a type with `repr()`, and the name
// printed for a type with no conversion beyond its prefix.
// Cases from Rust library/coretests/tests/fmt/mod.rs (test_format_macro_interface: user Display / LowerHex impls and pad_integral)
// Cases from Rust library/alloctests/tests/fmt.rs (padding applied to user formatters)
// Cases from the {fmt} library test/format-test.cc (user-defined formatter, enum and pointer tests)

import std::io::*

var CODE: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn starts(const s: string, const p: string, id: i32, const name: string) {
    if !s.starts_with(p) {
        println(f"FAIL {name}: got [{s}] want a prefix [{p}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

// A hex number after `prefix`, nothing else.
fn address_after(const s: string, const prefix: string) -> bool {
    if !s.starts_with(prefix) || s.size() == prefix.size() {
        return false
    }

    var b = s.bytes()
    for var i: usize = prefix.size(); i < b.size(); i += 1 {
        var c = b[i]
        if !((c >= 48 && c <= 57) || (c >= 97 && c <= 102)) {
            return false
        }
    }

    return true
}

struct WithOpAs {
    var n: i32
    fn op as(self) -> string { return f"n={self.n}" }
}

struct WithRepr {
    var n: i32
}

extend WithRepr {
    fn repr(self) -> string { return f"R{self.n}" }
}

struct Both {
    var n: i32
    fn op as(self) -> string { return "opas" }
}

extend Both {
    fn repr(self) -> string { return "repr" }
}

struct Wide {
    var n: i32
    fn op as(self) -> string { return f"<{self.n:>4}>" }
}

struct Accent {
    var tag: i32
    fn op as(self) -> string { return "héllo☃" }
}

struct Empty {
    var tag: i32
    fn op as(self) -> string { return "" }
}

struct Bare {
    var v: i32
}

enum Color {
    Red,
    Green = 5,
    Blue,
}

enum Small derives u8 {
    Lo = 3,
    Hi = 250,
}

fn <T> show(x: T) -> string {
    return f"{x}"
}

fn conversions() {
    var a = WithOpAs { n: 3 }
    var r = WithRepr { n: 4 }
    var b = Both { n: 1 }
    ck(f"{a}", "n=3", 1, "op as")
    ck(f"[{a}]", "[n=3]", 1, "op as in text")
    ck(f"{r}", "R4", 1, "repr")
    ck(f"{b}", "repr", 1, "repr before op as")
    starts(f"{a:?}", "WithOpAs @ 0x", 1, "? skips op as")
    starts(f"{r:?}", "\"R4\"", 1, "? uses repr")
    var wide = Wide { n: 7 }
    ck(f"{wide}", "<   7>", 1, "conversion that pads itself")
    ck(f"{wide:>9}", "   <   7>", 1, "outer width past the inner")
    ck(f"{wide:3}", "<   7>", 1, "outer width below the inner never truncates")
    ck(f"{Empty { tag: 1 }}", "", 1, "empty text")
    ck(f"{Empty { tag: 1 }:*^5}", "*****", 1, "empty text padded")
}

fn width_on_conversions() {
    var a = WithOpAs { n: 3 }
    var r = WithRepr { n: 4 }
    var h = Accent { tag: 0 }
    ck(f"{a:>8}", "     n=3", 2, "op as right")
    ck(f"{a:<8}|", "n=3     |", 2, "op as left")
    ck(f"{a:8}|", "n=3     |", 2, "op as default is left")
    ck(f"{a:^7}", "  n=3  ", 2, "op as centre")
    ck(f"{a:*^7}", "**n=3**", 2, "op as centre fill")
    ck(f"{a:→>6}", "→→→n=3", 2, "op as multi-byte fill")
    ck(f"{a:.2}", "n=", 2, "op as precision")
    ck(f"{a:6.2}|", "n=    |", 2, "op as width and precision")
    ck(f"{r:>6}", "    R4", 2, "repr right")
    ck(f"{r:*<6}", "R4****", 2, "repr left fill")
    ck(f"{r:.1}", "R", 2, "repr precision")
    ck(f"{r:😀^6}", "😀😀R4😀😀", 2, "repr emoji fill")
    ck(f"{h}", "héllo☃", 2, "multi-byte text")
    ck(f"{h:>8}", "  héllo☃", 2, "width counts code points")
    ck(f"{h:<8}|", "héllo☃  |", 2, "width counts code points, left")
    ck(f"{h:.3}", "hél", 2, "precision counts code points")
    ck(f"{h:-^9.5}", "--héllo--", 2, "precision then fill")
    ck(f"{h:-^11.5}", "---héllo---", 2, "precision then a wider fill")
    ck(f"{h:.0}", "", 2, "precision zero")
}

fn plain_enums() {
    var g = Color::Green
    ck(f"{g}", "5", 3, "enum with an explicit value")
    ck(f"{Color::Red}", "0", 3, "first enumerator")
    ck(f"{Color::Blue}", "6", 3, "enumerator after an explicit value")
    ck(f"{g:>4}", "   5", 3, "enum width")
    ck(f"{g:#x}", "0x5", 3, "enum in hex")
    ck(f"{g:03}", "005", 3, "enum zero padded")
    ck(f"{Small::Hi}", "250", 3, "enum on u8")
    ck(f"{Small::Hi:x}", "fa", 3, "enum on u8, hex")
    ck(f"{Small::Lo:b}", "11", 3, "enum on u8, binary")
}

fn addresses() {
    var z = Bare { v: 1 }
    var s = f"{z}"
    if !address_after(s, "Bare @ 0x") {
        println(f"FAIL record with no conversion: got [{s}]")
        CODE = if CODE == 0 => 4 else => CODE
    }

    var x: i32 = 9
    var p: unsafe *i32 = unsafe &x
    var ps = f"{p}"
    if !address_after(ps, "i32 @ 0x") {
        println(f"FAIL pointer: got [{ps}]")
        CODE = if CODE == 0 => 4 else => CODE
    }

    var np: unsafe *i32 = &null
    ck(f"{np}", "&null", 4, "null pointer")
    ck(f"[{np}]", "[&null]", 4, "null pointer in text")
    var q: unsafe *i32 = &null
    unsafe {
        q = 0x1234 as unsafe *i32
    }

    ck(f"{q}", "i32 @ 0x1234", 4, "pointer from an address")
    ck(f"{q}{q}", "i32 @ 0x1234i32 @ 0x1234", 4, "two pointers")
    var big: unsafe *u8 = &null
    unsafe {
        big = 0xdeadbeef as unsafe *u8
    }

    ck(f"{big}", "u8 @ 0xdeadbeef", 4, "pointer, lowercase hex")
}

fn nullables() {
    var n: i32? = 5
    if n != null {
        ck(f"{n}", "5", 5, "non-null nullable")
        ck(f"{n:>4}", "   5", 5, "non-null nullable width")
    }

    var m? = 7
    if m? {
        ck(f"{m:+}", "+7", 5, "narrowed nullable")
    }

    var s? = "text"
    if s? {
        ck(f"{s:>6}", "  text", 5, "narrowed nullable string")
    }
}

fn generic_holes() {
    var a = WithOpAs { n: 3 }
    ck(show(5), "5", 6, "generic i32")
    ck(show(-5), "-5", 6, "generic negative")
    ck(show(7u8), "7", 6, "generic u8")
    ck(show("s"), "s", 6, "generic string")
    ck(show(1.5), "1.5", 6, "generic f64")
    ck(show(true), "true", 6, "generic bool")
    ck(show('é'), "é", 6, "generic char")
    ck(show(a), "n=3", 6, "generic op as")
    ck(show(Color::Green), "5", 6, "generic plain enum")
    ck(show(show(12)), "12", 6, "generic of generic")
}

fn main() -> i32 {
    conversions()
    width_on_conversions()
    plain_enums()
    addresses()
    nullables()
    generic_holes()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
