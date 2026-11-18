// How f-strings compose: expressions in holes, an f-string inside an f-string (with its own quotes and a spec on the
// result), holes evaluated once, left to right, adjacent literals joined, `\{` and `\}` for literal braces, many holes
// of different types in one string, and a string hole that stays usable afterwards.
// Rules asserted (Compiler/Spec/FormatStrings.md, The rewrite: holes are bound in source order, inner f-strings are
// rewritten first, a string hole is read where it is; website language/primitives.mdx, Strings: adjacent literals are
// one string with holes evaluated left to right, and `\{` `\}` are the braces in an f-string).
// Not asserted because the docs do not state them: `{{` and `}}` as braces (Kairo spells them `\{` `\}`), the `{x=}`
// self-documenting form, positional or named arguments, and a width or precision taken from another argument; Kairo's
// spec takes literal numbers only.
// Cases from Rust library/coretests/tests/fmt/mod.rs (test_order, test_once, test_format_args, escaping)
// Cases from Rust library/alloctests/tests/fmt.rs (nested format_args)
// Cases from the {fmt} library test/format-test.cc (compile-time and nested format tests; named and positional arguments have no Kairo spelling)

import std::io::*

var CODE: i32 = 0
var COUNTER: i32 = 0

fn ck(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn next() -> i32 {
    COUNTER += 1
    return COUNTER
}

fn sq(x: i32) -> i32 {
    return x * x
}

fn make() -> string {
    return "made"
}

struct Pt {
    var x: i32
    var y: i32
}

fn literals() {
    ck(f"", "", 1, "empty f-string")
    ck(f"abc", "abc", 1, "text only")
    ck(f"héllo ☃ 日本 😀", "héllo ☃ 日本 😀", 1, "multi-byte text")
    ck(f"{7}", "7", 1, "a hole alone")
    ck(f"{7}{8}{9}", "789", 1, "adjacent holes")
    ck(f"a{1}b{2}c", "a1b2c", 1, "text around holes")
    ck(f"100% : ; , . - + # 0 ? [ ] ( ) < > = ~ ! @ ^ & * | / _", "100% : ; , . - + # 0 ? [ ] ( ) < > = ~ ! @ ^ & * | / _", 1, "punctuation in text")
    ck(f"\{7\}", "{7}", 1, "escaped braces")
    ck(f"\{\{", "{{", 1, "two escaped open braces")
    ck(f"\}\}", "}}", 1, "two escaped close braces")
    ck(f"\{{7}\}", "{7}", 1, "escaped braces around a hole")
    ck(f"a\{b\}c{1}", "a{b}c1", 1, "escaped braces and a hole")
    ck(f"tab\there\nnew \"quoted\" back\\slash", "tab\there\nnew \"quoted\" back\\slash", 1, "string escapes in the text")
    ck(f"é\x41\U0001F600", "éA😀", 1, "unicode escapes in the text")
    var n = 3
    ck("total: " f"{n}" " items", "total: 3 items", 1, "adjacent literals, f-string in the middle")
    ck("a" f"{n}" "b" f"{n + 1}", "a3b4", 1, "adjacent literals, two f-strings")
    ck("total: " f"{n}" r" \items", "total: 3 \\items", 1, "adjacent raw literal")
    ck(f"{n}" f"{n:>3}", "3  3", 1, "adjacent f-strings")
}

fn expressions() {
    var a = 3
    var b = 4
    var pt = Pt { x: 5, y: 6 }
    var arr = [10, 20, 30]
    var s = "héllo"
    ck(f"{a + b * 2}", "11", 2, "arithmetic")
    ck(f"{(a + 1):>5}", "    4", 2, "parenthesised expression with a spec")
    ck(f"{-a}", "-3", 2, "unary minus")
    ck(f"{-a:+}", "-3", 2, "negative with plus")
    ck(f"{sq(4)}", "16", 2, "call")
    ck(f"{sq(sq(2)):>4}", "  16", 2, "nested call with a spec")
    ck(f"{s.size()} {s.codepoints()}", "6 5", 2, "method calls")
    ck(f"{pt.x},{pt.y}", "5,6", 2, "fields")
    ck(f"{arr[1]}", "20", 2, "index")
    ck(f"{a > b}", "false", 2, "comparison")
    ck(f"{a < b && b < 5}", "true", 2, "logical and")
    ck(f"{a as f64}", "3", 2, "cast")
    ck(f"{a as i64:#x}", "0x3", 2, "cast with a spec")
    ck(f"{if a > 1 => "big" else => "small"}", "big", 2, "conditional expression with strings")
    ck(f"{if a > 5 => 1 else => 2:>3}", "  2", 2, "conditional expression with a spec")
    ck(f"{"lit"}", "lit", 2, "string literal")
    ck(f"{"lit":>5}", "  lit", 2, "string literal with a spec")
    ck(f"{'x'}", "x", 2, "char literal")
    ck(f"{make()}", "made", 2, "call returning a string")
    ck(f"{make():*^8}", "**made**", 2, "call returning a string with a spec")
    ck(f"{1.5 + 1.0}", "2.5", 2, "float arithmetic")
    ck(f"{pt.x * pt.y:05}", "00030", 2, "expression then zero padding")
}

fn nesting() {
    var n = 5
    var s = "in"
    ck(f"a{f"b{n}c"}d", "ab5cd", 3, "one level")
    ck(f"a{f"b{f"c{n}d"}e"}f", "abc5def", 3, "two levels")
    ck(f"{f"{f"{f"{n}"}"}"}", "5", 3, "four levels")
    ck(f"{f"{n}-{n}":>7}", "    5-5", 3, "spec on a nested f-string")
    ck(f"{f"{n}-{n}":*^9}", "***5-5***", 3, "centre spec on a nested f-string")
    ck(f"{f"{s}":>5}|{f"{s}":<5}|", "   in|in   |", 3, "two nested f-strings with specs")
    ck(f"{f"é{n}☃":-^7}", "--é5☃--", 3, "multi-byte nested result")
    ck(f"{f"{n:03}"}{f"{n:x}"}", "0055", 3, "nested holes with their own specs")
    ck(f"{f"{"quoted"}"}", "quoted", 3, "string literal inside a nested f-string")
    ck(f"[{f"{s}"}][{f"{s}{s}"}]", "[in][inin]", 3, "two nested f-strings in text")
    ck(f"{sq(f"{n}".size() as i32)}", "1", 3, "nested f-string as a call argument")
}

fn order() {
    COUNTER = 0
    ck(f"{next()}{next()}{next()}", "123", 4, "three calls")
    ck(f"{next():>3}|{next():<3}|{next():03}", "  4|5  |006", 4, "three calls with specs")
    ck(f"{next()}-{f"{next()}+{next()}"}-{next()}", "7-8+9-10", 4, "calls through a nested f-string")
    ck(f"{COUNTER}", "10", 4, "the value after the calls")
    COUNTER = 0
    var a = f"{next()}"
    var b = f"{next()}"
    a += b
    ck(a, "12", 4, "one call per f-string")
}

fn mixed() {
    var i: i8 = -5
    var u: u16 = 65535
    var l: i64 = -9000000000
    var f: f32 = 0.5
    var d = 2.25
    var t = true
    var c: char = 'é'
    var s = "str"
    var by: byte = 255
    var e: u8 = 251
    ck(f"{i}|{u}|{l}|{f}|{d}|{t}|{c}|{s}|{by}", "-5|65535|-9000000000|0.5|2.25|true|é|str|ff", 5, "every kind in one string")
    ck(f"{i:>4}|{u:<7}|{l:^15}|{f:7}|{d:+}|{t:>6}|{c:*^3}|{s:.2}|{by:#}", "  -5|65535  |  -9000000000  |    0.5|+2.25|  true|*é*|st|0xff", 5, "every kind with a spec")
    ck(f"{e:x}{u:x}{u:X}{u:o}{u:b}", "fb" "ffff" "FFFF" "177777" "1111111111111111", 5, "bases one after another")
}

fn string_holes() {
    var s = "abc"
    var t = f"{s}{s}"
    ck(t, "abcabc", 6, "a string hole twice")
    ck(s, "abc", 6, "the string is still there")
    ck(f"{s}", "abc", 6, "read again")
    var owned = "ab"
    owned += "cd"
    var u = f"<{owned}>"
    owned += "e"
    ck(u, "<abcd>", 6, "the result is its own string")
    ck(owned, "abcde", 6, "the source is unchanged by the f-string")
    var out = ""
    for var i = 0; i < 5; i += 1 {
        out += f"{i},"
    }

    ck(out, "0,1,2,3,4,", 6, "built in a loop")
    var v = [1, 2, 3]
    var parts = ""
    for x in v {
        parts += f"[{x:>2}]"
    }

    ck(parts, "[ 1][ 2][ 3]", 6, "a for loop")
}

fn main() -> i32 {
    literals()
    expressions()
    nesting()
    order()
    mixed()
    string_holes()
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
