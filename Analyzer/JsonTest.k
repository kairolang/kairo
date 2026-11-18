/// --- The Kairo Project ---------------------------- Analyzer/JsonTest.k --- ///
///
///   Tests for Json.k, the language server's JSON reader and writer. The
///   members of JsonDoc are `prot` in the Analyzer module, so the tests live
///   in the module; Tests/analyzer/json/*.k drive them.
///
///   Oracle: the rules of RFC 8259 (section numbers in the case names), each
///   case written by hand. A case states ACCEPT or REJECT and the sentence
///   of the RFC it rests on. Where the reader deviates from the RFC, the case
///   sits in a Known* function that is not called by Test(); the
///   Tests/analyzer/json/bug_*.k files call those and are XFAIL.
///
///   Part of the Kairo Project, under the Apache License v2.0 with the
///   Kairo Runtime Library Exception.
///
///   See: https://www.kairolang.org/LICENSE
///   SPDX-License-Identifier: Apache-2.0 WITH AdditionRef-Kairo-Runtime-exception
///   Copyright (c) 2026 Dhruvan Kartik
///
/// ------------------------------------------------------------------------ ///

import Json::*
import std::io

/// "ACCEPT" or "REJECT <error>" for one document; what the corpus script
/// drives.
pub fn probe(const text: string) -> string {
    var d = JsonDoc()
    if d.parse(text) {
        return "ACCEPT"
    }

    return f"REJECT {d.error}"
}

/// The bytes of `a` as a string (the reader takes raw bytes, not only valid
/// UTF-8).
fn bytes(const a: [u8]) -> string {
    var s = string()
    for var i: usize = 0; i < a.size(); ++i {
        s.push_back(a[i])
    }

    return s
}

/// `n` copies of `c`.
fn repeat(c: u8, n: usize) -> string {
    var s = string()
    for var i: usize = 0; i < n; ++i {
        s.push_back(c)
    }

    return s
}

/// The first `n` bytes of `s`.
fn prefix(const s: string, n: usize) -> string {
    var r = string()
    for var i: usize = 0; i < n; ++i {
        r.push_back(s[i])
    }

    return r
}

/// `"` + body + `"`, so a case spells only what is inside the quotes.
fn quoted(const body: string) -> string {
    var s = string()
    s.push_back('"' as u8)
    s += body
    s.push_back('"' as u8)
    return s
}

class Checker {
    var fails: i32 = 0
    var cases: i32 = 0

    fn Checker(self) = default

    fn fail(self, const name: string, const why: string) {
        ++self.fails
        io::println(f"FAIL {name}: {why}")
    }

    fn ok(self, const name: string, cond: bool) {
        ++self.cases
        if !cond {
            self.fail(name, "condition is false")
        }
    }

    fn eq_i(self, const name: string, got: i64, want: i64) {
        ++self.cases
        if got != want {
            self.fail(name, f"got {got}, want {want}")
        }
    }

    fn eq_s(self, const name: string, const got: string, const want: string) {
        ++self.cases
        if got != want {
            self.fail(name, f"got '{got}', want '{want}'")
        }
    }

    /// The text must parse.
    fn acc(self, const name: string, const text: string) {
        ++self.cases
        var d = JsonDoc()
        if !d.parse(text) {
            self.fail(name, f"rejected: {d.error}")
        }
    }

    /// The text must be refused, with a message, and the root must be
    /// JSON_NONE.
    fn rej(self, const name: string, const text: string) {
        ++self.cases
        var d = JsonDoc()
        if d.parse(text) {
            self.fail(name, "accepted")
            return
        }

        if d.error.is_empty() {
            self.fail(name, "rejected without a message")
        }

        if d.root != JSON_NONE() {
            self.fail(name, "root is not JSON_NONE after a failed parse")
        }
    }

    /// The text parses and its top-level string is `want` byte for byte.
    fn str_is(self, const name: string, const text: string, const want: string) {
        ++self.cases
        var d = JsonDoc()
        if !d.parse(text) {
            self.fail(name, f"rejected: {d.error}")
            return
        }

        if d.kind(d.root) != JsonKind::String {
            self.fail(name, "not a string")
            return
        }

        if d.str(d.root) != want {
            self.fail(
                name,
                f"got '{d.str(d.root)}' ({d.str(d.root).size()} bytes)",
            )
        }
    }

    /// The text parses as a number whose `num()` is within `tol` of `want`.
    fn num_is(self, const name: string, const text: string, want: f64, tol: f64) {
        ++self.cases
        var d = JsonDoc()
        if !d.parse(text) {
            self.fail(name, f"rejected: {d.error}")
            return
        }

        if !d.is_number(d.root) {
            self.fail(name, "not a number")
            return
        }

        var diff = d.num(d.root) - want
        if diff < 0.0 {
            diff = 0.0 - diff
        }

        if diff > tol {
            self.fail(name, f"got {d.num(d.root)}, want {want}")
        }
    }

    // --- RFC 8259 section 2: structure ----------------------------------

    fn structure(self) {
        // Section 2: a JSON text is any value, and a value is one of the
        // three literals, an object, an array, a number or a string.
        self.acc("top-level object", "{}")
        self.acc("top-level array", "[]")
        self.acc("top-level number", "1")
        self.acc("top-level string", "\"x\"")
        self.acc("top-level true", "true")
        self.acc("top-level false", "false")
        self.acc("top-level null", "null")

        // Section 5: an array holds zero or more values, an object zero or
        // more members.
        self.acc("empty array with ws", "[ \t\r\n]")
        self.acc("empty object with ws", "{ \t\r\n}")
        self.acc("nested empty arrays", "[[],[[]],[[],[]]]")
        self.acc("nested empty objects", "{\"a\":{},\"b\":{\"c\":{}}}")
        self.acc(
            "mixed nesting",
            "{\"a\":[1,{\"b\":[true,null,\"s\"]}],\"c\":{\"d\":[]}}",
        )

        // Structural characters may be surrounded by insignificant
        // whitespace (space, tab, LF, CR) and by nothing else.
        self.acc(
            "ws around every token",
            " \t\r\n{ \"a\" \t: \r\n[ 1 , 2 ] , \"b\" : null }\n ",
        )

        var d = JsonDoc()
        self.ok("parse array", d.parse("[1,2,3]"))
        self.eq_i("array count", d.count(d.root) as i64, 3)
        self.eq_i("array element 1", d.as_int(d.next(d.first(d.root))), 2)
        self.ok("array kind", d.kind(d.root) == JsonKind::Array)
        self.ok("parse object", d.parse("{\"a\":1,\"b\":[],\"c\":\"x\"}"))
        self.ok("object kind", d.is_object(d.root))
        self.eq_i("object count", d.count(d.root) as i64, 3)
        self.eq_s("first key", d.key(d.first(d.root)), "a")
        self.eq_i("get a", d.get_int(d.root, "a"), 1)
        self.eq_s("get c", d.get_str(d.root, "c"), "x")
        self.ok("missing key is NONE", d.get(d.root, "zz") == JSON_NONE())
        self.ok(
            "get on array is NONE",
            d.get(d.get(d.root, "b"), "x") == JSON_NONE(),
        )

        // Section 4: names SHOULD be unique; a parser that gets a duplicate
        // has to do something. The reader keeps every member in order and
        // `get` returns the first.
        self.ok("parse duplicate keys", d.parse("{\"a\":1,\"a\":2}"))
        self.eq_i("duplicate keys are all kept", d.count(d.root) as i64, 2)
        self.eq_i("get returns the first duplicate", d.get_int(d.root, "a"), 1)
        self.eq_i(
            "second duplicate by walking",
            d.as_int(d.next(d.first(d.root))),
            2,
        )

        // Parsing again on the same document replaces the previous contents.
        self.ok("reparse after success", d.parse("[true]"))
        self.eq_i("reparse count", d.count(d.root) as i64, 1)
        self.ok("failed parse reports false", !d.parse("[1,"))
        self.ok("failed parse clears root", d.root == JSON_NONE())
        self.ok("parse works after a failure", d.parse("{}"))
        self.ok("error cleared", d.error.is_empty())

        // The accessors accept JSON_NONE and a wrong kind and answer empty.
        var none = JSON_NONE()
        self.eq_i("none count", d.count(none) as i64, 0)
        self.eq_s("none str", d.str(none), "")
        self.eq_i("none int", d.as_int(none), 0)
        self.ok("none kind is Null", d.kind(none) == JsonKind::Null)
        self.ok("none first", d.first(none) == JSON_NONE())
        self.ok("none next", d.next(none) == JSON_NONE())
        self.ok("none bool", !d.boolean(none))
        self.ok("str of a number", d.parse("5") && d.str(d.root) == "")
        self.ok("int of a string", d.parse("\"5\"") && d.as_int(d.root) == 0)
    }

    fn structure_errors(self) {
        // Section 2: a value is required where one is expected, commas
        // separate elements and members, and nothing follows the value.
        self.rej("empty input", "")
        self.rej("only whitespace", " \t\r\n")
        self.rej("lone open bracket", "[")
        self.rej("lone close bracket", "]")
        self.rej("lone open brace", "{")
        self.rej("lone close brace", "}")
        self.rej("trailing comma in array", "[1,]")
        self.rej("leading comma in array", "[,1]")
        self.rej("double comma in array", "[1,,2]")
        self.rej("comma only array", "[,]")
        self.rej("trailing comma in object", "{\"a\":1,}")
        self.rej("comma only object", "{,}")
        self.rej("missing colon", "{\"a\" 1}")
        self.rej("missing value", "{\"a\":}")
        self.rej("only a key", "{\"a\"}")
        self.rej("double colon", "{\"a\"::1}")
        self.rej("unquoted key", "{a:1}")
        self.rej("single-quoted key", "{'a':1}")
        self.rej("number key", "{1:1}")
        self.rej("missing comma in array", "[1 2]")
        self.rej("missing comma in object", "{\"a\":1 \"b\":2}")
        self.rej("mismatched close, object by bracket", "{\"a\":1]")
        self.rej("mismatched close, array by brace", "[1}")
        self.rej("unterminated array", "[1,2")
        self.rej("unterminated object", "{\"a\":1")
        self.rej("unterminated nested", "[[[]]")
        self.rej("colon in array", "[\"a\":1]")
        self.rej("array as key", "{[]:1}")
        self.rej("bare colon", ":")
        self.rej("bare comma", ",")

        // Garbage after the value: the whole text must be one value.
        self.rej("two objects", "{} {}")
        self.rej("two numbers", "1 2")
        self.rej("garbage after array", "[]x")
        self.rej("extra close brace", "{}}")
        self.rej("extra close bracket", "[]]")
        self.rej("trailing comma after top-level", "null,")
        self.rej("two strings", "\"a\"\"b\"")
        self.rej("NUL after value", bytes([0x5b, 0x5d, 0x00]))
        self.rej("comment line", "// c\n[]")
        self.rej("comment block", "/* c */ []")
        self.rej("trailing comment", "[]//x")
        self.rej("NaN", "NaN")
        self.rej("Infinity", "Infinity")
        self.rej("-Infinity", "-Infinity")
        self.rej("undefined", "undefined")
        self.rej("single-quoted string", "'a'")
        self.rej("bare word", "abc")
        self.rej("equals", "{\"a\"=1}")
        self.rej("semicolon", "[1;2]")
    }

    // --- literals --------------------------------------------------------

    fn literals(self) {
        // Section 3: the literals are exactly the lowercase names.
        var d = JsonDoc()
        self.ok(
            "true",
            d.parse("true") && d.kind(d.root) == JsonKind::Bool && d.boolean(d.root),
        )

        self.ok(
            "false",
            d.parse("false") && d.kind(d.root) == JsonKind::Bool && !d.boolean(d.root),
        )

        self.ok(
            "null",
            d.parse("null") && d.kind(d.root) == JsonKind::Null && d.root != JSON_NONE(),
        )

        self.rej("True", "True")
        self.rej("TRUE", "TRUE")
        self.rej("False", "False")
        self.rej("FALSE", "FALSE")
        self.rej("Null", "Null")
        self.rej("NULL", "NULL")
        self.rej("nul", "nul")
        self.rej("tru", "tru")
        self.rej("fals", "fals")
        self.rej("t", "t")
        self.rej("nulll", "nulll")
        self.rej("truee", "truee")
        self.rej("tru in array", "[tru]")
        self.rej("truefalse", "[truefalse]")
        self.rej("nan lowercase", "nan")
        self.rej("nulL", "nulL")
        self.rej("true as a key", "{true:1}")
        self.rej("null followed by letter in array", "[nullx]")
        self.acc("literals in array", "[true,false,null]")
        self.ok(
            "object get_bool",
            d.parse("{\"t\":true,\"f\":false}")
                && d.get_bool(d.root, "t")
                && !d.get_bool(d.root, "f"),
        )
    }

    // --- whitespace (section 2) ---------------------------------------------

    fn whitespace(self) {
        // Insignificant whitespace is exactly space, tab, LF and CR.
        self.acc("space", " []")
        self.acc("tab", "\t[]")
        self.acc("lf", "\n[]")
        self.acc("cr", "\r[]")
        self.acc("trailing ws", "[] \t\r\n")
        self.rej("form feed before", bytes([0x0c, 0x5b, 0x5d]))
        self.rej("form feed after", bytes([0x5b, 0x5d, 0x0c]))
        self.rej("form feed inside", bytes([0x5b, 0x0c, 0x31, 0x5d]))
        self.rej("vertical tab", bytes([0x0b, 0x5b, 0x5d]))
        self.rej("NBSP before", bytes([0xc2, 0xa0, 0x5b, 0x5d]))
        self.rej("NBSP inside", bytes([0x5b, 0xc2, 0xa0, 0x31, 0x5d]))
        self.rej("U+2028", bytes([0xe2, 0x80, 0xa8, 0x5b, 0x5d]))
        self.rej("ideographic space", bytes([0x5b, 0xe3, 0x80, 0x80, 0x5d]))
        self.rej("NUL before", bytes([0x00, 0x5b, 0x5d]))

        // Section 8.1: implementations MUST NOT add a byte order mark and MAY
        // ignore one; the reader does not skip it, so a BOM-prefixed text is
        // refused.
        self.rej("BOM before value", bytes([0xef, 0xbb, 0xbf, 0x5b, 0x5d]))
        self.rej("BOM alone", bytes([0xef, 0xbb, 0xbf]))
    }

    // --- numbers (section 6) --------------------------------------------

    fn numbers(self) {
        // number = [ minus ] int [ frac ] [ exp ]; int = zero / digit1-9 *DIGIT.
        self.num_is("0", "0", 0.0, 0.0)
        self.num_is("-0 value", "-0", 0.0, 0.0)
        self.num_is("1", "1", 1.0, 0.0)
        self.num_is("-1", "-1", -1.0, 0.0)
        self.num_is("123", "123", 123.0, 0.0)
        self.num_is("10", "10", 10.0, 0.0)
        self.num_is("0.5", "0.5", 0.5, 0.0)
        self.num_is("-0.5", "-0.5", -0.5, 0.0)
        self.num_is("0.25", "0.25", 0.25, 0.0)
        self.num_is("1.5e3", "1.5e3", 1500.0, 1e-9)
        self.num_is("1E3", "1E3", 1000.0, 0.0)
        self.num_is("1e+3", "1e+3", 1000.0, 0.0)
        self.num_is("1e-3", "1e-3", 0.001, 1e-12)
        self.num_is("25e-1", "25e-1", 2.5, 1e-12)
        self.num_is("0e0", "0e0", 0.0, 0.0)
        self.num_is("0.0", "0.0", 0.0, 0.0)
        self.num_is("1e0", "1e0", 1.0, 0.0)
        self.num_is("-1.25E2", "-1.25E2", -125.0, 1e-9)
        self.num_is("0.1 within an ulp or two", "0.1", 0.1, 1e-15)
        self.num_is("3.14159", "3.14159", 3.14159, 1e-12)
        self.num_is("1e-5", "1e-5", 0.00001, 1e-15)
        self.num_is("5e+2", "5e+2", 500.0, 0.0)
        self.acc("numbers in array", "[0,-0,1,-1,0.5,1e2,1E+2,1e-2,10]")

        var d = JsonDoc()
        // Integral numbers keep an exact i64.
        self.ok(
            "integer is integral",
            d.parse("42") && d.nodes[d.root as usize].flag,
        )

        self.eq_i("integer value", d.as_int(d.root), 42)
        self.ok(
            "fraction is not integral",
            d.parse("42.0") && !d.nodes[d.root as usize].flag,
        )

        self.ok("fraction parses", d.parse("42.9"))
        self.eq_i("fraction as_int truncates", d.as_int(d.root), 42)
        self.ok(
            "exponent is not integral",
            d.parse("4e1") && !d.nodes[d.root as usize].flag,
        )

        self.eq_i("exponent as_int", d.as_int(d.root), 40)
        self.ok("negative integer", d.parse("-17") && d.as_int(d.root) == -17)
        self.ok("-0 integral zero", d.parse("-0") && d.as_int(d.root) == 0)
        self.ok(
            "i64 max",
            d.parse("9223372036854775807") && d.as_int(d.root) == 9223372036854775807,
        )

        // Section 6: precision beyond a double is the implementation's. The
        // reader holds an exact i64 next to the f64, so 2^53 + 1 is exact in
        // as_int and rounded in num().
        self.ok("2^53+1 parses", d.parse("9007199254740993"))
        self.eq_i("2^53+1 exact as_int", d.as_int(d.root), 9007199254740993)
        var big = d.num(d.root) - 9007199254740992.0
        self.ok(
            "2^53+1 num is the nearest double",
            (big >= -2.0) && (big <= 2.0),
        )

        self.ok(
            "2^53 exact",
            d.parse("9007199254740992") && d.as_int(d.root) == 9007199254740992,
        )

        self.ok(
            "negative 2^53+1",
            d.parse("-9007199254740993") && d.as_int(d.root) == -9007199254740993,
        )

        // Section 6: an implementation may set limits on the range of numbers.
        // 1e400 overflows a double: the reader accepts it and num() is +inf.
        self.ok("1e400 parses", d.parse("1e400"))
        self.ok("1e400 is infinity", d.num(d.root) > 1.0e308)
        self.ok("1e-400 parses", d.parse("1e-400") && d.num(d.root) == 0.0)
        self.ok("1e308 parses", d.parse("1e308") && d.num(d.root) > 9.9e307)
        self.ok("0e999 parses", d.parse("0e999") && d.num(d.root) == 0.0)

        // The grammar: no leading plus, no leading dot, no hex, no digit
        // separators, no word forms.
        self.rej("plus sign", "+1")
        self.rej("plus in array", "[+1]")
        self.rej("leading dot", ".1")
        self.rej("leading dot in array", "[.5]")
        self.rej("hex", "0x10")
        self.rej("hex in array", "[0x1F]")
        self.rej("octal prefix letter", "0o7")
        self.rej("binary prefix", "0b1")
        self.rej("digit separator", "1_000")
        self.rej("double minus", "--1")
        self.rej("minus after digits", "1-")
        self.rej("second dot", "1.2.3")
        self.rej("dot after exponent", "1e5.5")
        self.rej("space inside number", "1 0")
        self.rej("trailing letter", "1a")
        self.rej("trailing letter in array", "[1a]")
        self.rej("minus then letter", "-a")
        self.rej("minus then plus", "-+1")
        self.rej("number then literal", "1true")
        self.rej("lone dot", ".")
        self.rej("exponent with sign first", "e5")
        self.rej("capital exponent only", "E5")
        self.rej("minus infinity word", "[-Infinity]")
        self.rej("NaN in array", "[NaN]")
        self.rej("fullwidth digit", bytes([0xef, 0xbc, 0x91]))
        self.rej("unicode minus", bytes([0xe2, 0x88, 0x92, 0x31]))
    }

    /// Number grammar the reader does not enforce. The RFC grammar requires
    /// digits after `.`, after `e`, a digit after `-`, and no leading zero.
    fn known_number_grammar(self) {
        self.rej("leading zero 01", "01")
        self.rej("leading zero -01", "-01")
        self.rej("leading zero 00", "[00]")
        self.rej("leading zero 012", "[012]")
        self.rej("leading zero with fraction", "[01.5]")
        self.rej("lone minus", "-")
        self.rej("lone minus in array", "[-]")
        self.rej("minus then dot", "[-.123]")
        self.rej("1.", "1.")
        self.rej("-2.", "[-2.]")
        self.rej("0.e1", "[0.e1]")
        self.rej("2.e3", "[2.e3]")
        self.rej("1e", "[1e]")
        self.rej("1E", "[1E]")
        self.rej("1e+", "[1e+]")
        self.rej("1e-", "[1e-]")
        self.rej("0e", "[0e]")
        self.rej("0E+", "[0E+]")
        self.rej("1.0e", "[1.0e]")
        self.rej("0.3e+", "[0.3e+]")
        self.rej("exponent after comma", "[1,5e]")
    }

    // --- strings (section 7) --------------------------------------------

    fn strings(self) {
        self.str_is("empty string", "\"\"", "")
        self.str_is("plain", "\"abc\"", "abc")
        self.str_is("with spaces", "\"a b  c\"", "a b  c")
        self.str_is("escape quote", quoted("\\\""), "\"")
        self.str_is("escape backslash", quoted("\\\\"), "\\")
        self.str_is("escape solidus", quoted("\\/"), "/")
        self.str_is("unescaped solidus", quoted("a/b"), "a/b")
        self.str_is("escape b", quoted("\\b"), bytes([0x08]))
        self.str_is("escape f", quoted("\\f"), bytes([0x0c]))
        self.str_is("escape n", quoted("\\n"), "\n")
        self.str_is("escape r", quoted("\\r"), "\r")
        self.str_is("escape t", quoted("\\t"), "\t")
        self.str_is(
            "backslash then letter n is not an n",
            quoted("\\\\n"),
            "\\n",
        )

        self.str_is(
            "all escapes in a row",
            quoted("\\\"\\\\\\/\\b\\f\\n\\r\\t"),
            bytes([0x22, 0x5c, 0x2f, 0x08, 0x0c, 0x0a, 0x0d, 0x09]),
        )

        // \uXXXX: four hex digits, either case, UTF-8 out.
        self.str_is("u0041", quoted("\\u0041"), "A")
        self.str_is("u0000 is one NUL byte", quoted("\\u0000"), bytes([0x00]))
        self.str_is("u001f", quoted("\\u001f"), bytes([0x1f]))
        self.str_is("u007f DEL", quoted("\\u007f"), bytes([0x7f]))
        self.str_is("u0080 two bytes", quoted("\\u0080"), bytes([0xc2, 0x80]))
        self.str_is(
            "u00e9 lowercase hex",
            quoted("\\u00e9"),
            bytes([0xc3, 0xa9]),
        )

        self.str_is(
            "u00E9 uppercase hex",
            quoted("\\u00E9"),
            bytes([0xc3, 0xa9]),
        )

        self.str_is("u07ff", quoted("\\u07ff"), bytes([0xdf, 0xbf]))
        self.str_is(
            "u0800 three bytes",
            quoted("\\u0800"),
            bytes([0xe0, 0xa0, 0x80]),
        )

        self.str_is("u20AC euro", quoted("\\u20AC"), bytes([0xe2, 0x82, 0xac]))
        self.str_is("uFFFF", quoted("\\uFFFF"), bytes([0xef, 0xbf, 0xbf]))
        self.str_is("uFFFE", quoted("\\uFFFE"), bytes([0xef, 0xbf, 0xbe]))
        self.str_is("u escapes mixed with text", quoted("a\\u0042c"), "aBc")
        self.str_is("u escaped quote", quoted("\\u0022"), "\"")
        self.str_is("u escaped backslash", quoted("\\u005c"), "\\")

        // A surrogate pair of two escapes is ONE code point (section 7).
        self.str_is(
            "pair U+1F600",
            quoted("\\ud83d\\ude00"),
            bytes([0xf0, 0x9f, 0x98, 0x80]),
        )

        self.str_is(
            "pair uppercase",
            quoted("\\uD83D\\uDE00"),
            bytes([0xf0, 0x9f, 0x98, 0x80]),
        )

        self.str_is(
            "pair first astral U+10000",
            quoted("\\uD800\\uDC00"),
            bytes([0xf0, 0x90, 0x80, 0x80]),
        )

        self.str_is(
            "pair last U+10FFFF",
            quoted("\\uDBFF\\uDFFF"),
            bytes([0xf4, 0x8f, 0xbf, 0xbf]),
        )

        self.str_is(
            "pair between text",
            quoted("a\\ud83d\\ude00b"),
            bytes([0x61, 0xf0, 0x9f, 0x98, 0x80, 0x62]),
        )

        self.str_is(
            "two pairs",
            quoted("\\ud83d\\ude00\\ud83d\\ude01"),
            bytes([0xf0, 0x9f, 0x98, 0x80, 0xf0, 0x9f, 0x98, 0x81]),
        )

        // Section 8.2: a lone surrogate escape is grammatical but has no
        // defined meaning. The reader accepts it and writes the surrogate as
        // its own 3-byte sequence (an ill-formed UTF-8 sequence).
        self.acc("lone high surrogate", quoted("\\ud800"))
        self.acc("lone low surrogate", quoted("\\udc00"))
        self.acc("lone high before text", quoted("\\ud800x"))
        self.acc("reversed pair", quoted("\\ude00\\ud83d"))
        self.str_is(
            "lone high surrogate bytes",
            quoted("\\ud800"),
            bytes([0xed, 0xa0, 0x80]),
        )

        self.str_is(
            "lone low surrogate bytes",
            quoted("\\udc00"),
            bytes([0xed, 0xb0, 0x80]),
        )

        // Raw bytes >= 0x20 other than quote and backslash stand for
        // themselves: UTF-8 passes through, DEL included.
        self.str_is(
            "raw UTF-8 two bytes",
            quoted(bytes([0xc3, 0xa9])),
            bytes([0xc3, 0xa9]),
        )

        self.str_is(
            "raw UTF-8 four bytes",
            quoted(bytes([0xf0, 0x9f, 0x98, 0x80])),
            bytes([0xf0, 0x9f, 0x98, 0x80]),
        )

        self.str_is("raw DEL", quoted(bytes([0x7f])), bytes([0x7f]))
        self.str_is(
            "raw U+2028",
            quoted(bytes([0xe2, 0x80, 0xa8])),
            bytes([0xe2, 0x80, 0xa8]),
        )

        self.str_is(
            "raw U+FFFF",
            quoted(bytes([0xef, 0xbf, 0xbf])),
            bytes([0xef, 0xbf, 0xbf]),
        )

        self.str_is(
            "raw U+10FFFF",
            quoted(bytes([0xf4, 0x8f, 0xbf, 0xbf])),
            bytes([0xf4, 0x8f, 0xbf, 0xbf]),
        )

        self.str_is("raw space", quoted(" "), " ")

        // The decoded string is exact: length counts bytes.
        var d = JsonDoc()
        self.ok("long string", d.parse(quoted(repeat('a' as u8, 100000))))
        self.eq_i("long string size", d.str(d.root).size() as i64, 100000)

        // Keys decode like strings.
        self.ok("escaped key", d.parse("{\"a\\nb\":1,\"\\u0041\":2,\"\":3}"))
        self.eq_i("key with newline", d.get_int(d.root, "a\nb"), 1)
        self.eq_i("key with u escape", d.get_int(d.root, "A"), 2)
        self.eq_i("empty key", d.get_int(d.root, ""), 3)

        // Errors: a string ends at an unescaped quote and every escape is
        // complete.
        self.rej("unterminated", "\"abc")
        self.rej("lone quote", "\"")
        self.rej("quote then backslash", "\"\\")
        self.rej("escaped final quote", "\"\\\"")
        self.rej("unterminated in array", "[\"a]")
        self.rej("unterminated key", "{\"a:1}")
        self.rej("u with 0 digits", quoted("\\u"))
        self.rej("u with 1 digit", quoted("\\u1"))
        self.rej("u with 2 digits", quoted("\\u12"))
        self.rej("u with 3 digits", quoted("\\u123"))
        self.rej("u with non-hex", quoted("\\u12G4"))
        self.rej("u with all non-hex", quoted("\\uZZZZ"))
        self.rej("u truncated at end of input", "\"\\u00")
        self.rej("u with minus", quoted("\\u-123"))
        self.rej("u with space", quoted("\\u 123"))
        self.rej("high surrogate then truncated escape", quoted("\\ud83d\\ude"))
        self.rej("high surrogate then bad hex", quoted("\\ud83d\\uZZZZ"))
        self.rej("high surrogate then truncated input", "\"\\ud83d\\u")
        self.rej("string cut after a pair", "\"\\ud83d\\ude00")
        self.rej("single quote delimiters", "'a'")
        self.rej("string followed by garbage", "\"a\"b")
    }

    /// Escape and control-character rules the reader does not enforce.
    fn known_string_rules(self) {
        // Section 7: the escapes are exactly \" \\ \/ \b \f \n \r \t \uXXXX.
        self.rej("escape x", quoted("\\x"))
        self.rej("escape a", quoted("\\a"))
        self.rej("escape v", quoted("\\v"))
        self.rej("escape 0", quoted("\\0"))
        self.rej("escape single quote", quoted("\\'"))
        self.rej("escape capital U", quoted("\\U0041"))
        self.rej("escape capital N", quoted("\\N"))
        self.rej(
            "escaped emoji bytes",
            quoted(bytes([0x5c, 0xf0, 0x9f, 0x98, 0x80])),
        )

        self.rej("escaped NUL byte", quoted(bytes([0x5c, 0x00])))
        self.rej("escaped tab byte", quoted(bytes([0x5c, 0x09])))

        // Section 7: U+0000 through U+001F MUST be escaped inside a string.
        self.rej("raw tab", quoted("\t"))
        self.rej("raw newline", quoted("\n"))
        self.rej("raw CR", quoted("\r"))
        self.rej("raw NUL", quoted(bytes([0x00])))
        self.rej("raw 0x01", quoted(bytes([0x01])))
        self.rej("raw 0x08", quoted(bytes([0x08])))
        self.rej("raw 0x0c", quoted(bytes([0x0c])))
        self.rej("raw 0x1f", quoted(bytes([0x1f])))
        self.rej("raw newline inside text", quoted("a\nb"))
        self.rej("raw tab in key", "{\"a\tb\":1}")
        self.rej("raw newline in key", "{\"a\nb\":1}")
    }

    /// Section 8.1: JSON text MUST be UTF-8. The reader copies bytes between
    /// the quotes unchecked.
    fn known_invalid_utf8(self) {
        self.rej("lone 0xff", quoted(bytes([0xff])))
        self.rej("lone 0xfe", quoted(bytes([0xfe])))
        self.rej("lone continuation 0x80", quoted(bytes([0x80])))
        self.rej("lone continuation 0xbf", quoted(bytes([0xbf])))
        self.rej("overlong slash C0 AF", quoted(bytes([0xc0, 0xaf])))
        self.rej("overlong NUL C0 80", quoted(bytes([0xc0, 0x80])))
        self.rej("overlong E0 80 AF", quoted(bytes([0xe0, 0x80, 0xaf])))
        self.rej(
            "overlong F0 80 80 AF",
            quoted(bytes([0xf0, 0x80, 0x80, 0xaf])),
        )

        self.rej("truncated two-byte", quoted(bytes([0xc3])))
        self.rej("truncated three-byte", quoted(bytes([0xe2, 0x82])))
        self.rej("truncated four-byte", quoted(bytes([0xf0, 0x9f, 0x98])))
        self.rej(
            "encoded surrogate ED A0 80",
            quoted(bytes([0xed, 0xa0, 0x80])),
        )

        self.rej(
            "above U+10FFFF F4 90 80 80",
            quoted(bytes([0xf4, 0x90, 0x80, 0x80])),
        )

        self.rej(
            "five-byte form",
            quoted(bytes([0xf8, 0x88, 0x80, 0x80, 0x80])),
        )

        self.rej("lead byte then ASCII", quoted(bytes([0xc3, 0x28])))
        self.rej("invalid byte in key", "{\"" + bytes([0xff]) + "\":1}")
        self.rej("invalid byte after escape", quoted(bytes([0x5c, 0x6e, 0xff])))
        self.rej("invalid byte outside a string", bytes([0x5b, 0xff, 0x5d]))
    }

    /// A reader asked for a high surrogate escape followed by an escape that
    /// is not a low surrogate must not make up a code point from the pair.
    fn known_surrogate_pairing(self) {
        self.rej("high then non-surrogate escape", quoted("\\ud800\\u0041"))
        self.rej("high then high", quoted("\\ud800\\ud800"))
        self.rej(
            "high then high-low pair tail",
            quoted("\\ud800\\ud800\\udc00"),
        )
    }

    // --- depth ------------------------------------------------------------

    fn depth(self) {
        // The reader bounds recursion: value_ fails when depth > 256, the
        // outermost value is depth 0, so 257 nested containers pass only when
        // the innermost is empty and 256 pass around a scalar. Beyond it the
        // text is refused with "nesting too deep", never a stack overflow.
        self.acc("1 deep", "[]")
        self.acc("100 deep", repeat('[' as u8, 100) + repeat(']' as u8, 100))
        self.acc("257 arrays", repeat('[' as u8, 257) + repeat(']' as u8, 257))
        self.rej("258 arrays", repeat('[' as u8, 258) + repeat(']' as u8, 258))
        self.rej(
            "1000 arrays",
            repeat('[' as u8, 1000) + repeat(']' as u8, 1000),
        )

        self.rej("10000 open brackets", repeat('[' as u8, 10000))
        self.rej(
            "10000 arrays balanced",
            repeat('[' as u8, 10000) + repeat(']' as u8, 10000),
        )

        self.rej("1000000 open brackets", repeat('[' as u8, 1000000))

        var obj256 = string()
        var obj257 = string()
        var obj258 = string()
        var obj10k = string()
        for var i: usize = 0; i < 256; ++i {
            obj256 += "{\"a\":"
        }

        for var i: usize = 0; i < 257; ++i {
            obj257 += "{\"a\":"
        }

        for var i: usize = 0; i < 258; ++i {
            obj258 += "{\"a\":"
        }

        for var i: usize = 0; i < 10000; ++i {
            obj10k += "{\"a\":"
        }

        self.acc(
            "256 objects around a scalar",
            obj256 + "1" + repeat('}' as u8, 256),
        )

        self.rej(
            "257 objects around a scalar",
            obj257 + "1" + repeat('}' as u8, 257),
        )

        self.rej("258 objects", obj258 + "1" + repeat('}' as u8, 258))
        self.acc(
            "scalar at depth 256",
            repeat('[' as u8, 256) + "1" + repeat(']' as u8, 256),
        )

        self.rej(
            "scalar at depth 257",
            repeat('[' as u8, 257) + "1" + repeat(']' as u8, 257),
        )

        self.rej("10000 open objects", obj10k)

        var mixed = string()
        for var i: usize = 0; i < 5000; ++i {
            mixed += "[{\"a\":"
        }

        self.rej("10000 mixed levels open", mixed)

        var d = JsonDoc()
        self.ok("too deep fails", !d.parse(repeat('[' as u8, 400)))
        self.ok("depth message", d.error.starts_with("JSON: nesting too deep"))
        self.ok("a document after a deep failure parses", d.parse("[1]"))

        // Depth counts containers, not siblings: a wide document is fine.
        var wide = string()
        wide += "["
        for var i: usize = 0; i < 20000; ++i {
            if i != 0 {
                wide += ","
            }

            wide += "[]"
        }

        wide += "]"
        self.ok("20000 siblings", d.parse(wide) && d.count(d.root) == 20000)
    }

    // --- truncation (reading a cut-off message must never crash) --------------

    fn truncation(self) {
        var msg = string()
        msg += "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"textDocument/didChange\","
        msg += "\"params\":{\"textDocument\":{\"uri\":\"file:///a/b.k\",\"version\":3},"
        msg += "\"contentChanges\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},"
        msg += "\"end\":{\"line\":0,\"character\":1}},\"text\":\"x\\ny\\u00e9\\ud83d\\ude00\"},"
        msg += "{\"text\":\"\\\\ \\\" \\/\",\"n\":-1.5e-3,\"t\":true,\"f\":false,\"z\":null}]}}"
        self.ok("message is at least 200 bytes", msg.size() >= 200)
        self.acc("the full message parses", msg)

        // Every proper prefix of an object is missing its closing brace.
        for var n: usize = 0; n < msg.size(); ++n {
            var cut = prefix(msg, n)
            var d   = JsonDoc()
            if d.parse(cut) {
                self.fail(f"truncation at {n}", "accepted a proper prefix")
            } else if d.error.is_empty() {
                self.fail(f"truncation at {n}", "no message")
            }

            ++self.cases
        }

        // Every proper prefix of an array of numbers and strings likewise.
        var arr = "[0,-12,3.5e2,\"a\\n\\u00e9\",true,false,null,[],{}]"
        for var n: usize = 0; n < arr.size(); ++n {
            var cut = prefix(arr, n)
            var d   = JsonDoc()
            if d.parse(cut) {
                self.fail(
                    f"array truncation at {n}",
                    "accepted a proper prefix",
                )
            }

            ++self.cases
        }

        // A scalar cut short: the prefixes that are themselves valid are
        // accepted (`12` of `123`), the rest are refused; neither crashes.
        var sc = "-123.5e+10"
        for var n: usize = 0; n <= sc.size(); ++n {
            var d        = JsonDoc()
            var accepted = d.parse(prefix(sc, n))
            ++self.cases
            if n == 0 && accepted {
                self.fail("empty scalar prefix", "accepted")
            }
        }
    }

    // --- the writer -------------------------------------------------------

    fn writer(self) {
        var w = JsonWriter()
        w.begin_object()
        w.field("a", "x")
        w.field_int("b", -5)
        w.field_uint("c", 7)
        w.field_bool("d", true)
        w.key("e")
        w.begin_array()
        w.integer(1)
        w.str("two")
        w.nul()
        w.boolean(false)
        w.begin_object()
        w.end_object()
        w.begin_array()
        w.end_array()
        w.end_array()
        w.field_raw("f", "[1,2]")
        w.key("g")
        w.num(0.5)
        w.end_object()
        self.eq_s(
            "writer layout",
            w.out,
            "{\"a\":\"x\",\"b\":-5,\"c\":7,\"d\":true,\"e\":[1,\"two\",null,false,{},[]],\"f\":[1,2],\"g\":0.5}",
        )

        var d = JsonDoc()
        self.ok("writer output parses", d.parse(w.out))
        self.eq_i("read back b", d.get_int(d.root, "b"), -5)
        self.eq_i(
            "read back array count",
            d.count(d.get(d.root, "e")) as i64,
            6,
        )

        var top = JsonWriter()
        top.str("x")
        self.eq_s("top-level string", top.out, "\"x\"")
        var topn = JsonWriter()
        topn.integer(9223372036854775807)
        self.eq_s("i64 max", topn.out, "9223372036854775807")
        var topm = JsonWriter()
        topm.integer(-9223372036854775807 - 1)
        self.eq_s("i64 min", topm.out, "-9223372036854775808")
        var topu = JsonWriter()
        topu.uint(0)
        self.eq_s("uint zero", topu.out, "0")

        // Escaping: quote, backslash, the short escapes, every other control
        // character as \u00XX, DEL and bytes >= 0x80 raw.
        var e = JsonWriter()
        e.str("\"\\\n\r\t")
        self.eq_s("short escapes", e.out, "\"\\\"\\\\\\n\\r\\t\"")
        var all = string()
        for var c: u32 = 0; c < 32; ++c {
            all.push_back(c as u8)
        }

        var ew = JsonWriter()
        ew.str(all)
        var raw_ctl = false
        for var i: usize = 0; i < ew.out.size(); ++i {
            if ew.out[i] < (' ' as u8) {
                raw_ctl = true
            }
        }

        self.ok("no raw control byte in writer output", !raw_ctl)
        self.eq_s(
            "control escapes",
            ew.out,
            "\"\\u0000\\u0001\\u0002\\u0003\\u0004\\u0005\\u0006\\u0007\\u0008\\t\\n\\u000b\\u000c\\r\\u000e\\u000f\\u0010\\u0011\\u0012\\u0013\\u0014\\u0015\\u0016\\u0017\\u0018\\u0019\\u001a\\u001b\\u001c\\u001d\\u001e\\u001f\"",
        )

        self.ok("controls round-trip", d.parse(ew.out) && d.str(d.root) == all)

        var ed = JsonWriter()
        ed.str(bytes([0x7f]))
        self.eq_s("DEL is written raw", ed.out, quoted(bytes([0x7f])))
        var eu = JsonWriter()
        var utf = bytes(
            [0xc3, 0xa9, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x98, 0x80, 0xf4, 0x8f, 0xbf, 0xbf],
        )

        eu.str(utf)
        self.eq_s("UTF-8 passes through unchanged", eu.out, quoted(utf))
        self.ok("UTF-8 round-trips", d.parse(eu.out) && d.str(d.root) == utf)

        // Writer -> reader for strings with every kind of byte (valid UTF-8
        // content plus all of ASCII).
        var asc = string()
        for var c: u32 = 0; c < 128; ++c {
            asc.push_back(c as u8)
        }

        asc += utf
        var wa = JsonWriter()
        wa.str(asc)
        self.ok(
            "all ASCII round-trips",
            d.parse(wa.out) && d.str(d.root) == asc,
        )

        var wk = JsonWriter()
        wk.begin_object()
        wk.field(asc, asc)
        wk.end_object()
        self.ok(
            "key round-trips",
            d.parse(wk.out) && d.get_str(d.root, asc) == asc,
        )

        // A string quoted by the writer holds exactly one string.
        var wq = JsonWriter()
        wq.str("a\"b,c]d}e")
        self.ok(
            "delimiters in a string stay inside",
            d.parse(wq.out) && d.str(d.root) == "a\"b,c]d}e",
        )

        // raw() splices a value, including as an array element and a key value.
        var wr = JsonWriter()
        wr.begin_array()
        wr.raw("{\"id\":1}")
        wr.raw("\"s\"")
        wr.end_array()
        self.eq_s("raw splices", wr.out, "[{\"id\":1},\"s\"]")
    }

    fn roundtrip(self) {
        var d = JsonDoc()
        var docs: [string] = [
            "null",
            "true",
            "false",
            "0",
            "-17",
            "9223372036854775807",
            "1.5",
            "-0.25",
            "\"\"",
            "\"a\\nb\\\"c\\\\d\"",
            "[]",
            "{}",
            "[1,2,3]",
            "{\"a\":[1,{\"b\":null},\"x\"],\"c\":{\"d\":false}}",
            "[[],[[]],{},{\"\":[]}]",
        ]

        for var i: usize = 0; i < docs.size(); ++i {
            var ok = d.parse(docs[i])
            self.ok(f"dump input {i} parses", ok)
            if ok {
                // Compact input is reproduced exactly by dump().
                self.eq_s(
                    f"dump reproduces compact input {i}",
                    d.dump(d.root),
                    docs[i],
                )
            }
        }

        // Request ids go back as the kind they came.
        self.ok("numeric id", d.parse("{\"id\":42}"))
        self.eq_s("numeric id dump", d.dump(d.get(d.root, "id")), "42")
        self.ok("string id", d.parse("{\"id\":\"abc\"}"))
        self.eq_s("string id dump", d.dump(d.get(d.root, "id")), "\"abc\"")
        self.ok("null id", d.parse("{\"id\":null}"))
        self.eq_s("null id dump", d.dump(d.get(d.root, "id")), "null")
        self.eq_s(
            "missing id dumps as null",
            d.dump(d.get(d.root, "none")),
            "null",
        )

        // Whitespace and exponent forms normalise.
        self.ok("spaced input", d.parse(" { \"a\" : [ 1 , 2 ] } "))
        self.eq_s("normalised", d.dump(d.root), "{\"a\":[1,2]}")

        // Dump -> parse -> dump is stable for a string with escapes and a
        // supplementary-plane character.
        self.ok(
            "escaped string parses",
            d.parse("[\"\\u0001\\ud83d\\ude00\\t\"]"),
        )

        var once = d.dump(d.root)
        self.ok("dump re-parses", d.parse(once))
        self.eq_s("dump is stable", d.dump(d.root), once)

        // Fractions: write then read gives the same value for numbers a
        // double holds exactly.
        var vals: [f64] = [0.5, -0.5, 0.25, 1.5, 100.0, 1024.5, -3.0, 0.0]
        for var i: usize = 0; i < vals.size(); ++i {
            var w = JsonWriter()
            w.num(vals[i])
            var ok = d.parse(w.out)
            self.ok(f"num {i} reparses", ok)
            if ok {
                self.num_is(f"num {i} value", w.out, vals[i], 0.0)
            }
        }
    }

    /// A number the writer emits must be a JSON number, and a double written
    /// then read must come back bit for bit.
    fn known_double_roundtrip(self) {
        var vals: [f64] = [
            0.1,                     0.2,               0.3,                    1.0e-7,
            123456.789,              3.141592653589793, 1.7976931348623157e308, 5.0e-324,
            2.2250738585072014e-308,
        ]

        var d = JsonDoc()
        for var i: usize = 0; i < vals.size(); ++i {
            var w = JsonWriter()
            w.num(vals[i])
            self.ok(f"double {i} parses ({w.out})", d.parse(w.out))
            self.ok(f"double {i} is exact ({w.out})", d.num(d.root) == vals[i])
        }

        // A double that has no JSON spelling must not be written as a bare
        // word the reader refuses.
        var inf = 1.0e308 * 10.0
        var wi  = JsonWriter()
        wi.num(inf)
        self.ok(f"infinity is writable as JSON ({wi.out})", d.parse(wi.out))
        var nan = inf - inf
        var wn  = JsonWriter()
        wn.num(nan)
        self.ok(f"NaN is writable as JSON ({wn.out})", d.parse(wn.out))
    }

    /// Integers outside i64 are numbers (section 6 lets an implementation
    /// limit the range) but must not wrap to a wrong integer.
    fn known_integer_range(self) {
        var d = JsonDoc()
        self.ok("20 digits parses", d.parse("99999999999999999999"))
        self.ok(
            "20 digits is not reported as a wrapped integer",
            d.num(d.root) > 9.9e19
                && (d.as_int(d.root) == 9223372036854775807 || !d.nodes[d.root as usize].flag),
        )

        self.ok("2^63 parses", d.parse("9223372036854775808"))
        self.ok("2^63 is not a negative integer", d.as_int(d.root) >= 0)
        self.ok("-2^63-1 parses", d.parse("-9223372036854775809"))
        self.ok("-2^63-1 is not a positive integer", d.as_int(d.root) <= 0)
        self.ok(
            "i64 min parses",
            d.parse("-9223372036854775808") && d.as_int(d.root) == -9223372036854775807 - 1,
        )

        self.ok(
            "1e400 as_int is defined",
            d.parse("1e400") && d.as_int(d.root) == 9223372036854775807,
        )
    }

    /// The cost of reading a number is bounded by its length. The exponent
    /// loop runs once per unit of the exponent, so a 12-byte text costs
    /// seconds.
    fn known_exponent_cost(self) {
        var d = JsonDoc()
        self.ok("1e2147483647 parses", d.parse("1e2147483647"))
        self.ok("1e-2147483647 parses", d.parse("1e-2147483647"))
        self.ok("1e99999999999 parses", d.parse("1e99999999999"))
    }
}

/// Runs every case. Prints one `FAIL <case>` line per failure; returns 0
/// when all pass.
pub fn Test() -> i32 {
    var t = Checker()
    t.structure()
    t.structure_errors()
    t.literals()
    t.whitespace()
    t.numbers()
    t.strings()
    t.depth()
    t.truncation()
    t.writer()
    t.roundtrip()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    if t.fails != 0 {
        return 1
    }

    return 0
}

/// The Known* groups hold the cases the reader fails today; the bug_*.k
/// tests run one each and are XFAIL. Each returns the number of failures.
pub fn KnownNumberGrammar() -> i32 {
    var t = Checker()
    t.known_number_grammar()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}

pub fn KnownStringRules() -> i32 {
    var t = Checker()
    t.known_string_rules()
    t.known_surrogate_pairing()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}

pub fn KnownInvalidUtf8() -> i32 {
    var t = Checker()
    t.known_invalid_utf8()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}

pub fn KnownDoubleRoundtrip() -> i32 {
    var t = Checker()
    t.known_double_roundtrip()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}

pub fn KnownIntegerRange() -> i32 {
    var t = Checker()
    t.known_integer_range()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}

pub fn KnownExponentCost() -> i32 {
    var t = Checker()
    t.known_exponent_cost()
    io::println(f"json: {t.cases} cases, {t.fails} failed")
    return t.fails
}
