// Splitting and rewriting: split, rsplit (with a piece limit), lines, fields,
// trim / trim_start / trim_end, replace, repeat, pad_start / pad_end, and the
// ASCII case conversions, on ASCII text and on text with multi-byte chars. The
// split family yields views into the source; replace, repeat, pad and the case
// conversions return new heap strings. Case conversion maps ASCII letters only:
// a non-ASCII char is left as it is. Trim removes Unicode white space.
// Cases from libc++ test/std/strings/basic.string/string.ops/string_substr/
// Cases from Rust library/alloctests/tests/str.rs (split, rsplit, splitn, lines, split_whitespace, trim, replace, repeat)
// Cases from Rust library/coretests/tests/char.rs (is_whitespace set)

import std::io

static CODE: i32 = 0

fn ck(ok: bool, id: i32, const name: string) {
    if !ok {
        io::println(f"FAIL {name}")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn ch(v: u32) -> char {
    var c: char = v
    return c
}

fn is_digit(c: char) -> bool {
    return c >= '0' && c <= '9'
}

fn is_wide(c: char) -> bool {
    return (c as u32) >= 0x80
}

fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

// The pieces joined, each followed by '|', so one comparison checks them all.
fn <P impl Pattern> js(const s: string, const p: P, max: usize) -> string {
    var out = string()
    for *piece in s.split(p, max) {
        out += *piece
        out.push('|')
    }

    return out
}

fn <P impl Pattern> jr(const s: string, const p: P, max: usize) -> string {
    var out = string()
    for *piece in s.rsplit(p, max) {
        out += *piece
        out.push('|')
    }

    return out
}

fn jl(const s: string) -> string {
    var out = string()
    for *piece in s.lines() {
        out += *piece
        out.push('|')
    }

    return out
}

fn jf(const s: string) -> string {
    var out = string()
    for *piece in s.fields() {
        out += *piece
        out.push('|')
    }

    return out
}

fn split_by_string() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        ck(js(mk(k, "a,b,c"), ",", usize::MAX) == "a|b|c|", b + 1, "split")
        ck(js(mk(k, ",a,,b,"), ",", usize::MAX) == "|a||b||", b + 2, "split keeps empty pieces")
        ck(js(mk(k, "abc"), ",", usize::MAX) == "abc|", b + 3, "split without a separator")
        ck(js(mk(k, ""), ",", usize::MAX) == "|", b + 4, "split empty is one empty piece")
        ck(js(mk(k, "a--b--c"), "--", usize::MAX) == "a|b|c|", b + 5, "split on two bytes")
        ck(js(mk(k, "a---b"), "--", usize::MAX) == "a|-b|", b + 6, "split matches do not overlap")
        ck(js(mk(k, ","), ",", usize::MAX) == "||", b + 7, "split only the separator")
        ck(js(mk(k, "é,€,😀"), ",", usize::MAX) == "é|€|😀|", b + 8, "split multi-byte pieces")
        ck(js(mk(k, "a€b€c"), "€", usize::MAX) == "a|b|c|", b + 9, "split on a wide separator")
        ck(js(mk(k, "aé"), "", usize::MAX) == "|a|é||", b + 10, "split on the empty pattern")
        ck(js(mk(k, ""), "", usize::MAX) == "||", b + 11, "split empty on the empty pattern")
        ck(js(mk(k, "abab"), "ab", usize::MAX) == "|||", b + 12, "split on a repeated separator")
    }
}

fn split_limits() {
    ck(js("a,b,c", ",", 2) == "a|b,c|", 20, "split limit 2")
    ck(js("a,b,c", ",", 1) == "a,b,c|", 21, "split limit 1 is the whole text")
    ck(js("a,b,c", ",", 0) == "", 22, "split limit 0 yields nothing")
    ck(js("a,b,c", ",", 3) == "a|b|c|", 23, "split limit equal to the pieces")
    ck(js("a,b,c", ",", 100) == "a|b|c|", 24, "split limit above the pieces")
    ck(js("a,,b", ",", 2) == "a|,b|", 25, "limit keeps the rest verbatim")
    ck(js("", ",", 1) == "|", 26, "limit 1 on empty")
    ck(js("aé", "", 2) == "|aé|", 27, "limit on the empty pattern")
    ck(jr("a,b,c", ",", 2) == "c|a,b|", 28, "rsplit limit 2")
    ck(jr("a,b,c", ",", 1) == "a,b,c|", 29, "rsplit limit 1")
    ck(jr("a,b,c", ",", 0) == "", 30, "rsplit limit 0")
}

fn rsplit_by_string() {
    ck(jr("a,b,c", ",", usize::MAX) == "c|b|a|", 40, "rsplit")
    ck(jr(",a,,b,", ",", usize::MAX) == "|b||a||", 41, "rsplit keeps empty pieces")
    ck(jr("abc", ",", usize::MAX) == "abc|", 42, "rsplit without a separator")
    ck(jr("", ",", usize::MAX) == "|", 43, "rsplit empty")
    ck(jr("aé", "", usize::MAX) == "|é|a||", 44, "rsplit on the empty pattern")
    ck(jr("a--b--c", "--", usize::MAX) == "c|b|a|", 45, "rsplit on two bytes")
    ck(jr("a---b", "--", usize::MAX) == "b|a-|", 46, "rsplit matches from the end")
    ck(jr("é,€,😀", ",", usize::MAX) == "😀|€|é|", 47, "rsplit multi-byte pieces")
}

fn split_by_char_and_predicate() {
    var src   = "k=v1;x=v22"
    var semi  = ';'
    var digit = Pred { f: is_digit }
    ck(js(src, semi, usize::MAX) == "k=v1|x=v22|", 50, "split on a char")
    ck(js(src, digit, usize::MAX) == "k=v|;x=v|||", 51, "split on a predicate")
    ck(jr(src, semi, 2) == "x=v22|k=v1|", 52, "rsplit on a char")
    ck(jr(src, digit, usize::MAX) == "||;x=v|k=v|", 53, "rsplit on a predicate")
    ck(js("a€b€c", ch(0x20ac), usize::MAX) == "a|b|c|", 54, "split on a wide char")
    ck(js("a😀b", ch(0x1f600), usize::MAX) == "a|b|", 55, "split on a 4 byte char")
    ck(js("aéb€c", Pred { f: is_wide }, usize::MAX) == "a|b|c|", 56, "split on wide chars")
    ck(js("xx", 'x', usize::MAX) == "|||", 57, "split on a repeated char")
    // The pieces point into the source.
    var all = true
    var text = "one two three".to_owned()
    var sp   = ' '
    for *p in text.split(sp) {
        if !p->is_view() || p->data() < text.data() || p->data() > text.data() + text.size() {
            all = false
        }
    }

    ck(all, 58, "pieces are views of the source")
}

fn lines_member() {
    ck(jl("one\ntwo\r\n\nfour") == "one|two||four|", 60, "lines")
    ck(jl("a\n") == "a|", 61, "a trailing newline adds no line")
    ck(jl("") == "", 62, "no lines in empty")
    ck(jl("\n") == "|", 63, "one empty line")
    ck(jl("\n\r\n\r") == "||\r|", 64, "a lone CR stays")
    ck(jl("no newline") == "no newline|", 65, "no terminator")
    ck(jl("a\r\nb\r\n") == "a|b|", 66, "CRLF")
    ck(jl("é\n€\r\n😀") == "é|€|😀|", 67, "multi-byte lines")
    ck(jl("a\n\n\nb") == "a|||b|", 68, "blank lines")
    ck(jl("\r\n") == "|", 69, "a bare CRLF")
}

fn fields_member() {
    ck(jf("  alpha\tbeta gamma 　 é\n") == "alpha|beta|gamma|é|", 70, "fields")
    ck(jf(" \t\n") == "", 71, "only space")
    ck(jf("one") == "one|", 72, "one field")
    ck(jf("") == "", 73, "no fields in empty")
    ck(jf("a  b") == "a|b|", 74, "runs of space")
    ck(jf(" a b\u2028c\u0085d") == "a|b|c|d|", 75, "unicode separators")
    ck(jf("a​b") == "a​b|", 76, "zero width space is not space")
    ck(jf("a b") == "a|b|", 77, "no-break space is space")
    ck(jf("€ 😀") == "€|😀|", 78, "multi-byte fields")
}

fn trim_members() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        ck(mk(k, "  abc  ").trim() == "abc", b + 1, "trim")
        ck(mk(k, "  abc  ").trim_start() == "abc  ", b + 2, "trim_start")
        ck(mk(k, "  abc  ").trim_end() == "  abc", b + 3, "trim_end")
        ck(mk(k, "abc").trim() == "abc", b + 4, "trim nothing")
        ck(mk(k, "   ").trim().is_empty(), b + 5, "trim only space")
        ck(mk(k, "").trim().is_empty(), b + 6, "trim empty")
        ck(mk(k, "\t\n\r abc \u000b\u000c").trim() == "abc", b + 7, "trim ascii space kinds")
        ck(mk(k, "  é　\u2028").trim() == "é", b + 8, "trim unicode space")
        ck(mk(k, "​abc").trim() == "​abc", b + 9, "zero width space stays")
        ck(mk(k, "a b").trim() == "a b", b + 10, "inner space stays")
        ck(mk(k, "\u0085x").trim_start() == "x" && mk(k, "x\u0085").trim_end() == "x", b + 11, "NEL")
        ck(mk(k, "   x").trim_start() == "x", b + 12, "more unicode space")
        ck(mk(k, "😀 ").trim_end() == "😀", b + 13, "trim after a 4 byte char")
        ck(mk(k, " €").trim_start() == "€", b + 14, "trim before a 3 byte char")
    }

    var src = "  pad  ".to_owned()
    var t   = src.trim()
    ck(t.is_view() && t.data() == src.data() + 2 && t.size() == 3, 20, "trim returns a view")
}

fn replace_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        ck(mk(k, "a-b-c").replace("-", "+", usize::MAX) == "a+b+c", b + 1, "replace all")
        ck(mk(k, "a-b-c").replace("-", "+", 1) == "a+b-c", b + 2, "replace the first")
        ck(mk(k, "a-b-c").replace("-", "+", 0) == "a-b-c", b + 3, "replace none")
        ck(mk(k, "abc").replace("x", "y", usize::MAX) == "abc", b + 4, "replace absent")
        ck(mk(k, "aaa").replace("a", "bb", usize::MAX) == "bbbbbb", b + 5, "replace with a longer text")
        ck(mk(k, "abcabc").replace("abc", "", usize::MAX).is_empty(), b + 6, "replace with nothing")
        ck(mk(k, "xaxbx").replace("x", "", usize::MAX) == "ab", b + 7, "remove by replacing")
        ck(mk(k, "aaaa").replace("aa", "b", usize::MAX) == "bb", b + 8, "replace does not overlap")
        ck(mk(k, "abc").replace("", "-", usize::MAX) == "-a-b-c-", b + 9, "replace the empty pattern")
        ck(mk(k, "aé").replace("", "-", usize::MAX) == "-a-é-", b + 10, "empty pattern steps by chars")
        ck(mk(k, "").replace("", "x", usize::MAX) == "x", b + 11, "empty by empty")
        ck(mk(k, "").replace("a", "x", usize::MAX).is_empty(), b + 12, "replace in empty")
        ck(mk(k, "é€é").replace(ch(0xe9), "e", usize::MAX) == "e€e", b + 13, "replace a wide char")
        ck(mk(k, "a1b22c").replace(Pred { f: is_digit }, "#", usize::MAX) == "a#b##c", b + 14, "replace by predicate")
        ck(mk(k, "a€b").replace("€", "😀", usize::MAX) == "a😀b", b + 15, "replace 3 bytes by 4")
        ck(mk(k, "😀😀").replace("😀", "a", usize::MAX) == "aa", b + 16, "replace 4 bytes by 1")
        ck(mk(k, "abc").replace("abc", "xyz", usize::MAX) == "xyz", b + 17, "replace the whole text")
        ck(mk(k, "aXbXc").replace('X', "--", 1) == "a--bXc", b + 18, "replace a char with a limit")
        ck(mk(k, "abc").replace("", "-", 2) == "-a-bc", b + 19, "empty pattern with a limit")
    }

    var r = "héllo".replace("l", "L", usize::MAX)
    ck(r == "héLLo" && r.is_owned() && r.codepoints() == 5, 50, "replace result is sound")
    var same = "abc"
    var copy = same.replace("x", "y", usize::MAX)
    ck(copy.is_owned() && copy == same, 51, "replace with no match copies")
}

fn repeat_member() {
    ck("ab".repeat(3) == "ababab", 60, "repeat")
    ck("ab".repeat(0).is_empty(), 61, "repeat 0")
    ck("ab".repeat(1) == "ab", 62, "repeat 1")
    ck("".repeat(1000).is_empty(), 63, "repeat empty")
    ck("é€".repeat(3) == "é€é€é€" && "é€".repeat(3).codepoints() == 6, 64, "repeat multi-byte")
    var big = "xyz".repeat(10000)
    ck(big.size() == 30000 && big[29999] == 'z' && big.is_owned(), 65, "repeat long")
    ck("😀".repeat(2).size() == 8, 66, "repeat 4 byte")
}

fn pad_members() {
    ck("ab".pad_start(5) == "   ab" && "ab".pad_end(5) == "ab   ", 70, "pad with spaces")
    ck("ab".pad_start(5, '0') == "000ab" && "ab".pad_end(5, '.') == "ab...", 71, "pad with a char")
    ck("abcde".pad_start(3) == "abcde" && "abcde".pad_end(5) == "abcde", 72, "no padding when long enough")
    ck("".pad_start(3, 'x') == "xxx" && "".pad_end(2, 'y') == "yy", 73, "pad empty")
    ck("ab".pad_start(0) == "ab", 74, "pad to 0")
    ck("é".pad_start(3, '*') == "**é" && "é".pad_start(3, '*').codepoints() == 3, 75, "width counts chars")
    ck("é".pad_end(3, ch(0x20ac)) == "é€€" && "é".pad_end(3, ch(0x20ac)).size() == 8, 76, "wide fill")
    ck("a".pad_start(3, ch(0x1f600)) == "😀😀a", 77, "4 byte fill")
    var p = "ab".pad_end(2)
    ck(p == "ab" && p.is_owned(), 78, "pad result is owned")
}

fn ascii_case() {
    ck("Hello, World 123".to_ascii_upper() == "HELLO, WORLD 123", 80, "upper")
    ck("Hello, World 123".to_ascii_lower() == "hello, world 123", 81, "lower")
    ck("".to_ascii_upper().is_empty() && "".to_ascii_lower().is_empty(), 82, "case of empty")
    ck("héllo wörld €".to_ascii_upper() == "HéLLO WöRLD €", 83, "upper leaves non-ascii")
    ck("HÉLLO WÖRLD".to_ascii_lower() == "hÉllo wÖrld", 84, "lower leaves non-ascii")
    ck("ABC".to_ascii_upper() == "ABC" && "abc".to_ascii_lower() == "abc", 85, "already converted")
    ck("@[`{".to_ascii_upper() == "@[`{" && "@[`{".to_ascii_lower() == "@[`{", 86, "chars around the letters")
    ck("azAZ".to_ascii_upper() == "AZAZ" && "azAZ".to_ascii_lower() == "azaz", 87, "range ends")
    ck("😀a".to_ascii_upper() == "😀A", 88, "upper after a 4 byte char")
    var u = "aé".to_ascii_upper()
    ck(u.is_owned() && u.codepoints() == 2 && u.size() == 3, 89, "result is sound")
    var src = "mixed".to_owned()
    var up  = src.to_ascii_upper()
    ck(src == "mixed" && up == "MIXED", 90, "the source is untouched")
    ck("Hello".eq_ignore_ascii_case("hELLO") && !"Hello".eq_ignore_ascii_case("hell"), 91, "eq_ignore_ascii_case")
    ck("".eq_ignore_ascii_case("") && !"a".eq_ignore_ascii_case(""), 92, "eq_ignore_ascii_case empty")
    ck("É".eq_ignore_ascii_case("É") && !"É".eq_ignore_ascii_case("é"), 93, "non-ascii compares exactly")
    ck("@".eq_ignore_ascii_case("`") == false && "[".eq_ignore_ascii_case("{") == false, 94, "chars next to the letters differ")
}

fn main() -> i32 {
    split_by_string()
    split_limits()
    rsplit_by_string()
    split_by_char_and_predicate()
    lines_member()
    fields_member()
    trim_members()
    replace_member()
    repeat_member()
    pad_members()
    ascii_case()
    return CODE
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
