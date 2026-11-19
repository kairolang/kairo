// Strings with width, fill, alignment and precision over ASCII, 2-, 3- and 4-byte content and multi-byte fill characters, and `?` quoting.
// Rules asserted (website library/core/formatting.mdx, FmtBuf.put_str / put_bool / put_char / put_byte): a string hole is
// padded by width, fill and alignment, default left; the precision truncates to that many code points; width counts code
// points (Compiler/Spec/FormatStrings.md, Capacity bound: "Width pads in codepoints"), never bytes or display columns.
// `?` quotes and escapes (put_str; put_char); a `byte` prints as two lowercase hex digits and `#` adds `0x`.
// Expected texts come from a Python oracle on Python strings (code points).
// Not asserted because the docs do not state them: the spelling of control characters under `?`, a precision together
// with `?`, and the split of an odd amount of padding by `^`.
// Cases from Rust library/coretests/tests/fmt/mod.rs (test_format_macro_interface: string width, precision, fill, alignment)
// Cases from Rust library/alloctests/tests/fmt.rs (padding and precision of strings and chars)
// Cases from the {fmt} library test/format-test.cc (string, char and bool width / fill / alignment cases)

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

fn strings() {
    var s0 = ""
    var s1 = "a"
    var s2 = "aa"
    var s3 = "abc"
    var s4 = "héllo"
    var s5 = "☃"
    var s6 = "日本語"
    var s7 = "😀x😀"
    var s8 = "a😀"
    var s9 = "naïve café"
    ck(f"{s0}", "", 1, "string \"\" {}")
    ck(f"{s0:1}", " ", 1, "string \"\" {1}")
    ck(f"{s0:4}", "    ", 1, "string \"\" {4}")
    ck(f"{s0:9}", "         ", 1, "string \"\" {9}")
    ck(f"{s0:<9}", "         ", 1, "string \"\" {<9}")
    ck(f"{s0:>9}", "         ", 1, "string \"\" {>9}")
    ck(f"{s0:^10}", "          ", 1, "string \"\" {^10}")
    ck(f"{s0:*>9}", "*********", 1, "string \"\" {*>9}")
    ck(f"{s0:→<9}", "→→→→→→→→→", 1, "string \"\" {→<9}")
    ck(f"{s0:日>8}", "日日日日日日日日", 1, "string \"\" {日>8}")
    ck(f"{s0:😀^8}", "😀😀😀😀😀😀😀😀", 1, "string \"\" {😀^8}")
    ck(f"{s0:.0}", "", 1, "string \"\" {.0}")
    ck(f"{s0:.1}", "", 1, "string \"\" {.1}")
    ck(f"{s0:.3}", "", 1, "string \"\" {.3}")
    ck(f"{s0:.100}", "", 1, "string \"\" {.100}")
    ck(f"{s0:6.2}", "      ", 1, "string \"\" {6.2}")
    ck(f"{s0:>8.3}", "        ", 1, "string \"\" {>8.3}")
    ck(f"{s0:/^10.8}", "//////////", 1, "string \"\" {/^10.8}")
    ck(f"{s0:_>12.4}", "____________", 1, "string \"\" {_>12.4}")
    ck(f"{s1}", "a", 1, "string \"a\" {}")
    ck(f"{s1:1}", "a", 1, "string \"a\" {1}")
    ck(f"{s1:4}", "a   ", 1, "string \"a\" {4}")
    ck(f"{s1:9}", "a        ", 1, "string \"a\" {9}")
    ck(f"{s1:<9}", "a        ", 1, "string \"a\" {<9}")
    ck(f"{s1:>9}", "        a", 1, "string \"a\" {>9}")
    ck(f"{s1:*>9}", "********a", 1, "string \"a\" {*>9}")
    ck(f"{s1:.0}", "", 1, "string \"a\" {.0}")
    ck(f"{s1:.1}", "a", 1, "string \"a\" {.1}")
    ck(f"{s1:.3}", "a", 1, "string \"a\" {.3}")
    ck(f"{s1:.100}", "a", 1, "string \"a\" {.100}")
    ck(f"{s1:6.2}", "a     ", 1, "string \"a\" {6.2}")
    ck(f"{s1:>8.3}", "       a", 1, "string \"a\" {>8.3}")
    ck(f"{s1:_>12.4}", "___________a", 1, "string \"a\" {_>12.4}")
    ck(f"{s2}", "aa", 1, "string \"aa\" {}")
    ck(f"{s2:1}", "aa", 1, "string \"aa\" {1}")
    ck(f"{s2:4}", "aa  ", 1, "string \"aa\" {4}")
    ck(f"{s2:9}", "aa       ", 1, "string \"aa\" {9}")
    ck(f"{s2:<9}", "aa       ", 1, "string \"aa\" {<9}")
    ck(f"{s2:>9}", "       aa", 1, "string \"aa\" {>9}")
    ck(f"{s2:^10}", "    aa    ", 1, "string \"aa\" {^10}")
    ck(f"{s2:*>9}", "*******aa", 1, "string \"aa\" {*>9}")
    ck(f"{s2:😀^8}", "😀😀😀aa😀😀😀", 1, "string \"aa\" {😀^8}")
    ck(f"{s2:.0}", "", 1, "string \"aa\" {.0}")
    ck(f"{s2:.1}", "a", 1, "string \"aa\" {.1}")
    ck(f"{s2:.3}", "aa", 1, "string \"aa\" {.3}")
    ck(f"{s2:.100}", "aa", 1, "string \"aa\" {.100}")
    ck(f"{s2:6.2}", "aa    ", 1, "string \"aa\" {6.2}")
    ck(f"{s2:>8.3}", "      aa", 1, "string \"aa\" {>8.3}")
    ck(f"{s2:/^10.8}", "////aa////", 1, "string \"aa\" {/^10.8}")
    ck(f"{s2:_>12.4}", "__________aa", 1, "string \"aa\" {_>12.4}")
    ck(f"{s3}", "abc", 1, "string \"abc\" {}")
    ck(f"{s3:1}", "abc", 1, "string \"abc\" {1}")
    ck(f"{s3:4}", "abc ", 1, "string \"abc\" {4}")
    ck(f"{s3:9}", "abc      ", 1, "string \"abc\" {9}")
    ck(f"{s3:<9}", "abc      ", 1, "string \"abc\" {<9}")
    ck(f"{s3:>9}", "      abc", 1, "string \"abc\" {>9}")
    ck(f"{s3:*>9}", "******abc", 1, "string \"abc\" {*>9}")
    ck(f"{s3:→<9}", "abc→→→→→→", 1, "string \"abc\" {→<9}")
    ck(f"{s3:日>8}", "日日日日日abc", 1, "string \"abc\" {日>8}")
    ck(f"{s3:.0}", "", 1, "string \"abc\" {.0}")
    ck(f"{s3:.1}", "a", 1, "string \"abc\" {.1}")
    ck(f"{s3:.3}", "abc", 1, "string \"abc\" {.3}")
    ck(f"{s3:.100}", "abc", 1, "string \"abc\" {.100}")
    ck(f"{s3:6.2}", "ab    ", 1, "string \"abc\" {6.2}")
    ck(f"{s3:>8.3}", "     abc", 1, "string \"abc\" {>8.3}")
    ck(f"{s3:_>12.4}", "_________abc", 1, "string \"abc\" {_>12.4}")
    ck(f"{s4}", "héllo", 1, "string \"héllo\" {}")
    ck(f"{s4:1}", "héllo", 1, "string \"héllo\" {1}")
    ck(f"{s4:4}", "héllo", 1, "string \"héllo\" {4}")
    ck(f"{s4:9}", "héllo    ", 1, "string \"héllo\" {9}")
    ck(f"{s4:<9}", "héllo    ", 1, "string \"héllo\" {<9}")
    ck(f"{s4:>9}", "    héllo", 1, "string \"héllo\" {>9}")
    ck(f"{s4:*>9}", "****héllo", 1, "string \"héllo\" {*>9}")
    ck(f"{s4:→<9}", "héllo→→→→", 1, "string \"héllo\" {→<9}")
    ck(f"{s4:日>8}", "日日日héllo", 1, "string \"héllo\" {日>8}")
    ck(f"{s4:.0}", "", 1, "string \"héllo\" {.0}")
    ck(f"{s4:.1}", "h", 1, "string \"héllo\" {.1}")
    ck(f"{s4:.3}", "hél", 1, "string \"héllo\" {.3}")
    ck(f"{s4:.100}", "héllo", 1, "string \"héllo\" {.100}")
    ck(f"{s4:6.2}", "hé    ", 1, "string \"héllo\" {6.2}")
    ck(f"{s4:>8.3}", "     hél", 1, "string \"héllo\" {>8.3}")
    ck(f"{s4:_>12.4}", "________héll", 1, "string \"héllo\" {_>12.4}")
    ck(f"{s5}", "☃", 1, "string \"☃\" {}")
    ck(f"{s5:1}", "☃", 1, "string \"☃\" {1}")
    ck(f"{s5:4}", "☃   ", 1, "string \"☃\" {4}")
    ck(f"{s5:9}", "☃        ", 1, "string \"☃\" {9}")
    ck(f"{s5:<9}", "☃        ", 1, "string \"☃\" {<9}")
    ck(f"{s5:>9}", "        ☃", 1, "string \"☃\" {>9}")
    ck(f"{s5:*>9}", "********☃", 1, "string \"☃\" {*>9}")
    ck(f"{s5:→<9}", "☃→→→→→→→→", 1, "string \"☃\" {→<9}")
    ck(f"{s5:日>8}", "日日日日日日日☃", 1, "string \"☃\" {日>8}")
    ck(f"{s5:.0}", "", 1, "string \"☃\" {.0}")
    ck(f"{s5:.1}", "☃", 1, "string \"☃\" {.1}")
    ck(f"{s5:.3}", "☃", 1, "string \"☃\" {.3}")
    ck(f"{s5:.100}", "☃", 1, "string \"☃\" {.100}")
    ck(f"{s5:6.2}", "☃     ", 1, "string \"☃\" {6.2}")
    ck(f"{s5:>8.3}", "       ☃", 1, "string \"☃\" {>8.3}")
    ck(f"{s5:_>12.4}", "___________☃", 1, "string \"☃\" {_>12.4}")
    ck(f"{s6}", "日本語", 1, "string \"日本語\" {}")
    ck(f"{s6:1}", "日本語", 1, "string \"日本語\" {1}")
    ck(f"{s6:4}", "日本語 ", 1, "string \"日本語\" {4}")
    ck(f"{s6:9}", "日本語      ", 1, "string \"日本語\" {9}")
    ck(f"{s6:<9}", "日本語      ", 1, "string \"日本語\" {<9}")
    ck(f"{s6:>9}", "      日本語", 1, "string \"日本語\" {>9}")
    ck(f"{s6:*>9}", "******日本語", 1, "string \"日本語\" {*>9}")
    ck(f"{s6:→<9}", "日本語→→→→→→", 1, "string \"日本語\" {→<9}")
    ck(f"{s6:日>8}", "日日日日日日本語", 1, "string \"日本語\" {日>8}")
    ck(f"{s6:.0}", "", 1, "string \"日本語\" {.0}")
    ck(f"{s6:.1}", "日", 1, "string \"日本語\" {.1}")
    ck(f"{s6:.3}", "日本語", 1, "string \"日本語\" {.3}")
    ck(f"{s6:.100}", "日本語", 1, "string \"日本語\" {.100}")
    ck(f"{s6:6.2}", "日本    ", 1, "string \"日本語\" {6.2}")
    ck(f"{s6:>8.3}", "     日本語", 1, "string \"日本語\" {>8.3}")
    ck(f"{s6:_>12.4}", "_________日本語", 1, "string \"日本語\" {_>12.4}")
    ck(f"{s7}", "😀x😀", 1, "string \"😀x😀\" {}")
    ck(f"{s7:1}", "😀x😀", 1, "string \"😀x😀\" {1}")
    ck(f"{s7:4}", "😀x😀 ", 1, "string \"😀x😀\" {4}")
    ck(f"{s7:9}", "😀x😀      ", 1, "string \"😀x😀\" {9}")
    ck(f"{s7:<9}", "😀x😀      ", 1, "string \"😀x😀\" {<9}")
    ck(f"{s7:>9}", "      😀x😀", 1, "string \"😀x😀\" {>9}")
    ck(f"{s7:*>9}", "******😀x😀", 1, "string \"😀x😀\" {*>9}")
    ck(f"{s7:→<9}", "😀x😀→→→→→→", 1, "string \"😀x😀\" {→<9}")
    ck(f"{s7:日>8}", "日日日日日😀x😀", 1, "string \"😀x😀\" {日>8}")
    ck(f"{s7:.0}", "", 1, "string \"😀x😀\" {.0}")
    ck(f"{s7:.1}", "😀", 1, "string \"😀x😀\" {.1}")
    ck(f"{s7:.3}", "😀x😀", 1, "string \"😀x😀\" {.3}")
    ck(f"{s7:.100}", "😀x😀", 1, "string \"😀x😀\" {.100}")
    ck(f"{s7:6.2}", "😀x    ", 1, "string \"😀x😀\" {6.2}")
    ck(f"{s7:>8.3}", "     😀x😀", 1, "string \"😀x😀\" {>8.3}")
    ck(f"{s7:_>12.4}", "_________😀x😀", 1, "string \"😀x😀\" {_>12.4}")
    ck(f"{s8}", "a😀", 1, "string \"a😀\" {}")
    ck(f"{s8:1}", "a😀", 1, "string \"a😀\" {1}")
    ck(f"{s8:4}", "a😀  ", 1, "string \"a😀\" {4}")
    ck(f"{s8:9}", "a😀       ", 1, "string \"a😀\" {9}")
    ck(f"{s8:<9}", "a😀       ", 1, "string \"a😀\" {<9}")
    ck(f"{s8:>9}", "       a😀", 1, "string \"a😀\" {>9}")
    ck(f"{s8:^10}", "    a😀    ", 1, "string \"a😀\" {^10}")
    ck(f"{s8:*>9}", "*******a😀", 1, "string \"a😀\" {*>9}")
    ck(f"{s8:😀^8}", "😀😀😀a😀😀😀😀", 1, "string \"a😀\" {😀^8}")
    ck(f"{s8:.0}", "", 1, "string \"a😀\" {.0}")
    ck(f"{s8:.1}", "a", 1, "string \"a😀\" {.1}")
    ck(f"{s8:.3}", "a😀", 1, "string \"a😀\" {.3}")
    ck(f"{s8:.100}", "a😀", 1, "string \"a😀\" {.100}")
    ck(f"{s8:6.2}", "a😀    ", 1, "string \"a😀\" {6.2}")
    ck(f"{s8:>8.3}", "      a😀", 1, "string \"a😀\" {>8.3}")
    ck(f"{s8:/^10.8}", "////a😀////", 1, "string \"a😀\" {/^10.8}")
    ck(f"{s8:_>12.4}", "__________a😀", 1, "string \"a😀\" {_>12.4}")
    ck(f"{s9}", "naïve café", 1, "string \"naïve café\" {}")
    ck(f"{s9:1}", "naïve café", 1, "string \"naïve café\" {1}")
    ck(f"{s9:4}", "naïve café", 1, "string \"naïve café\" {4}")
    ck(f"{s9:9}", "naïve café", 1, "string \"naïve café\" {9}")
    ck(f"{s9:<9}", "naïve café", 1, "string \"naïve café\" {<9}")
    ck(f"{s9:>9}", "naïve café", 1, "string \"naïve café\" {>9}")
    ck(f"{s9:^10}", "naïve café", 1, "string \"naïve café\" {^10}")
    ck(f"{s9:*>9}", "naïve café", 1, "string \"naïve café\" {*>9}")
    ck(f"{s9:😀^8}", "naïve café", 1, "string \"naïve café\" {😀^8}")
    ck(f"{s9:.0}", "", 1, "string \"naïve café\" {.0}")
    ck(f"{s9:.1}", "n", 1, "string \"naïve café\" {.1}")
    ck(f"{s9:.3}", "naï", 1, "string \"naïve café\" {.3}")
    ck(f"{s9:.100}", "naïve café", 1, "string \"naïve café\" {.100}")
    ck(f"{s9:6.2}", "na    ", 1, "string \"naïve café\" {6.2}")
    ck(f"{s9:>8.3}", "     naï", 1, "string \"naïve café\" {>8.3}")
    ck(f"{s9:/^10.8}", "/naïve ca/", 1, "string \"naïve café\" {/^10.8}")
    ck(f"{s9:_>12.4}", "________naïv", 1, "string \"naïve café\" {_>12.4}")
}

fn debug_strings_and_chars() {
    var s0 = ""
    var s1 = "hi"
    var s2 = "a\"b"
    var s3 = "back\\slash"
    var s4 = "héllo ☃ 日本"
    var s5 = "it's"
    var s6 = "\""
    var s7 = "\\"
    var s8 = "😀"
    ck(f"{s0:?}", "\"\"", 2, "string debug \"\"")
    ck(f"{s1:?}", "\"hi\"", 2, "string debug \"hi\"")
    ck(f"{s2:?}", "\"a\\\"b\"", 2, "string debug \"a\\\"b\"")
    ck(f"{s3:?}", "\"back\\\\slash\"", 2, "string debug \"back\\\\slash\"")
    ck(f"{s4:?}", "\"héllo ☃ 日本\"", 2, "string debug \"héllo ☃ 日本\"")
    ck(f"{s5:?}", "\"it's\"", 2, "string debug \"it's\"")
    ck(f"{s6:?}", "\"\\\"\"", 2, "string debug \"\\\"\"")
    ck(f"{s7:?}", "\"\\\\\"", 2, "string debug \"\\\\\"")
    ck(f"{s8:?}", "\"😀\"", 2, "string debug \"😀\"")
    ck(f"{'a':?}", "'a'", 2, "char debug 'a'")
    ck(f"{'é':?}", "'é'", 2, "char debug 'é'")
    ck(f"{'☃':?}", "'☃'", 2, "char debug '☃'")
    ck(f"{'😀':?}", "'😀'", 2, "char debug '😀'")
    ck(f"{'\'':?}", "'\\''", 2, "char debug '\\''")
    ck(f"{'\\':?}", "'\\\\'", 2, "char debug '\\\\'")
    ck(f"{'"':?}", "'\"'", 2, "char debug '\"'")
}

fn main() -> i32 {
    strings()
    debug_strings_and_chars()
    if CODE == 0 {
        println("ok")
    }

    return CODE
}

// --- lit wiring ---
// RUN: rm -rf %t.d %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK-NOT: FAIL
// CHECK: ok
