// Mutation: push, push_str, +=, append of numbers, insert, remove_range, pop,
// truncate and clear, from each starting state (literal, view, heap), with
// text that mixes 1, 2, 3 and 4 byte chars; appends that alias the string they
// extend; growth across many reallocations; a view that is modified leaves
// the text it borrowed untouched. After each step the bytes, the size, the
// code point count and the NUL are checked. Offsets that are off a char
// boundary trap (the trap programs are selected by argument count).
// Cases from libc++ test/std/strings/basic.string/string.modifiers/
// Cases from Rust library/alloctests/tests/string.rs (push, push_str, insert, remove, pop, truncate)

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

fn mk(kind: i32, const src: string) -> string {
    if kind == 0 {
        return src.copy()
    }

    if kind == 1 {
        return src.view()
    }

    return src.to_owned()
}

fn kind_name(kind: i32) -> string {
    if kind == 0 {
        return "literal"
    }

    if kind == 1 {
        return "view"
    }

    return "heap"
}

fn naive_cps(const s: string) -> usize {
    var n: usize = 0
    var b        = s.bytes()
    for var i: usize = 0; i < b.size(); i += 1 {
        if (b[i] & 0xc0) != 0x80 {
            n += 1
        }
    }

    return n
}

// `s` holds exactly `want`, counted right, terminated, and owns its bytes.
fn good(const s: string, const want: string) -> bool {
    if !(s == want) || s.size() != want.size() {
        return false
    }

    if s.codepoints() != naive_cps(want) || s.is_ascii() != (naive_cps(want) == want.size()) {
        return false
    }

    if !s.is_owned() {
        return false
    }

    unsafe {
        var unsafe *z = s.data() as unsafe *const u8
        return z[s.size()] == 0
    }
}

fn push_chars() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var s = mk(k, "ab")
        s.push('c')
        ck(good(s, "abc"), b + 1, "push ascii")
        s.push(ch(0xe9))
        ck(good(s, "abcé"), b + 2, "push 2 byte")
        s.push(ch(0x20ac))
        ck(good(s, "abcé€"), b + 3, "push 3 byte")
        s.push(ch(0x1f600))
        ck(good(s, "abcé€😀"), b + 4, "push 4 byte")
        s.push(ch(0))
        ck(s.size() == 13 && s.codepoints() == 7, b + 5, "push NUL char")
        var e = mk(k, "")
        e.push('x')
        ck(good(e, "x"), b + 6, "push onto empty")
        var f = mk(k, "")
        f.push(ch(0x1f600))
        ck(good(f, "😀"), b + 7, "push 4 byte onto empty")
    }
}

fn push_str_and_append_assign() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var t = mk(k, "ab")
        t.push_str("cd")
        ck(good(t, "abcd"), b + 1, "push_str")
        t += "éé"
        ck(good(t, "abcdéé"), b + 2, "+= non-ascii")
        t += ""
        ck(good(t, "abcdéé"), b + 3, "+= empty")
        var piece = "x€😀"
        t.push_str(piece.view())
        ck(good(t, "abcdééx€😀"), b + 4, "push_str of a view")
        var heap_rhs = "!".to_owned()
        t += heap_rhs
        ck(good(t, "abcdééx€😀!"), b + 5, "+= a heap string")
        var e = mk(k, "")
        e += "é"
        ck(good(e, "é"), b + 6, "+= onto empty")
        var u = mk(k, "ab")
        u += ""
        ck(u.is_owned() == (k == 2) && u == "ab", b + 7, "empty append leaves the state")
        var w = mk(k, "q")
        w.push_str("")
        ck(w == "q" && w.is_owned() == (k == 2), b + 8, "empty push_str leaves the state")
    }
}

fn append_numbers() {
    var s = string()
    s.append(0)
    s.append(-17)
    s.append(1234567890123 as u64)
    ck(s == "0-171234567890123", 1, "append integers")
    var t = "n=".to_owned()
    t.append(42 as u8)
    t.append(' ')
    t.append(true)
    ck(t == "n=42 true", 2, "append u8, char and bool")
    var f = string()
    f.append("é")
    f.append(ch(0x20ac))
    ck(f == "é€" && f.codepoints() == 2, 3, "append a string and a char")
    var lit = "x"
    lit.append(7)
    ck(lit == "x7" && lit.is_owned(), 4, "append onto a literal")
}

fn concat_and_operators() {
    var a = "ab"
    var c = a.concat("cd")
    ck(c == "abcd" && c.is_owned() && c.size() == 4, 10, "concat")
    ck("".concat("") == "", 11, "concat of two empties")
    ck("é".concat("€") == "é€" && "é".concat("€").codepoints() == 2, 12, "concat non-ascii")
    var left = "ab".to_owned()
    var r    = left.concat(left)
    ck(r == "abab", 13, "concat with itself")
    ck(left == "ab", 14, "concat leaves its operand")
    var sum = "a" + "b" + "c"
    ck(sum == "abc", 15, "+ chains")
    var big = string()
    for var i = 0; i < 200; i += 1 {
        big = big.concat("xy")
    }

    ck(big.size() == 400 && big[399] == 'y', 16, "concat in a loop")
}

fn aliasing_appends() {
    // The right side lives in the buffer the append may reallocate.
    var s = "abc".to_owned()
    s.push_str(s.view())
    ck(good(s, "abcabc"), 20, "push_str of its own view")
    s += s.view()
    ck(good(s, "abcabcabcabc"), 21, "+= its own view")
    var t = "é€".to_owned()
    t.push_str(t.view()[0..2])
    ck(good(t, "é€é"), 22, "append a prefix of itself")
    t.push_str(t.view()[2..])
    ck(good(t, "é€é€é"), 23, "append a suffix of itself")
    var tail = "xyz".to_owned()
    tail.reserve(3)
    tail.push_str(tail.view()[1..3])
    ck(good(tail, "xyzyz"), 24, "append into spare capacity")
    var grow = "0123456789".to_owned()
    for var i = 0; i < 10; i += 1 {
        grow.push_str(grow.view())
    }

    ck(grow.size() == 10240 && grow[10239] == '9' && grow.codepoints() == 10240, 25, "doubling a string ten times")
    var ins = "abc".to_owned()
    ins.insert(1, ins.view()[1..])
    ck(good(ins, "abcbc"), 26, "insert a slice of itself")
    var ins2 = "ab".to_owned()
    ins2.insert(0, ins2.view())
    ck(good(ins2, "abab"), 27, "insert itself at the front")
    var ins3 = "é€".to_owned()
    ins3.insert(2, ins3.view())
    ck(good(ins3, "éé€€"), 28, "insert itself in the middle")
}

fn growth() {
    var s = string()
    var expect_cps: usize = 0
    for var i = 0; i < 2000; i += 1 {
        var m = i % 4
        if m == 0 {
            s.push('a')
        } else if m == 1 {
            s.push(ch(0xe9))
        } else if m == 2 {
            s.push(ch(0x20ac))
        } else {
            s.push(ch(0x1f600))
        }

        expect_cps += 1
    }

    ck(s.codepoints() == expect_cps && s.size() == 500 * 10, 30, "mixed pushes")
    ck(s.codepoints() == naive_cps(s), 31, "count after mixed pushes")
    var w = string()
    for var i = 0; i < 1000; i += 1 {
        w.push_str("héllo ")
    }

    ck(w.size() == 7000 && w.codepoints() == 6000, 32, "push_str repeatedly")
    var cap = w.capacity()
    ck(cap >= w.size(), 33, "capacity covers size")
}

fn insert_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var mixed = "aé€😀z"
        var i = mk(k, mixed)
        i.insert(0, ">")
        ck(good(i, ">aé€😀z"), b + 1, "insert at the start")
        i.insert(4, "é")
        ck(good(i, ">aéé€😀z"), b + 2, "insert after a char")
        i.insert(i.size(), "<")
        ck(good(i, ">aéé€😀z<"), b + 3, "insert at the end")
        i.insert(1, "")
        ck(good(i, ">aéé€😀z<"), b + 4, "insert nothing")
        var m = mk(k, "ad")
        m.insert(1, "bc")
        ck(good(m, "abcd"), b + 5, "insert in the middle")
        var e = mk(k, "")
        e.insert(0, "é")
        ck(good(e, "é"), b + 6, "insert into empty")
        var n = mk(k, "ab")
        n.insert(2, "😀")
        ck(good(n, "ab😀"), b + 7, "insert a 4 byte char")
        var big = mk(k, "end")
        big.insert(0, "a longer piece of text that forces a reallocation")
        ck(big.size() == 52 && big[51] == 'd', b + 8, "insert that reallocates")
        var o = mk(k, "ab")
        o.insert(1, "x")
        ck(o == "axb" && o.is_owned(), b + 9, "insert makes it owned")
        var same = mk(k, "ab")
        same.insert(1, "")
        ck(same.is_owned() == (k == 2), b + 10, "insert nothing keeps the state")
    }
}

fn remove_range_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var mixed = "aé€😀z"
        var r = mk(k, mixed)
        r.remove_range(1usize..3usize)
        ck(good(r, "a€😀z"), b + 1, "remove a middle char")
        r.remove_range(0usize..1usize)
        ck(good(r, "€😀z"), b + 2, "remove a prefix")
        r.remove_range(3usize..8usize)
        ck(good(r, "€"), b + 3, "remove a suffix")
        r.remove_range(3usize..3usize)
        ck(good(r, "€"), b + 4, "remove nothing at the end")
        r.remove_range(0usize..=2usize)
        ck(good(r, ""), b + 5, "remove everything, inclusive")
        var r2 = mk(k, "aéb")
        r2.remove_range(1usize..3usize)
        ck(good(r2, "ab") && r2.is_ascii(), b + 6, "removing the only wide char leaves ascii")
        var r3 = mk(k, "abc")
        r3.remove_range(2usize..2usize)
        ck(r3 == "abc" && r3.is_owned() == (k == 2), b + 7, "empty removal keeps the state")
        var r4 = mk(k, "abcdef")
        r4.remove_range(0usize..6usize)
        ck(good(r4, ""), b + 8, "remove the whole text")
        var r5 = mk(k, "😀😀😀")
        r5.remove_range(4usize..8usize)
        ck(good(r5, "😀😀"), b + 9, "remove one 4 byte char")
        var r6 = mk(k, "abc")
        r6.remove_range(1usize..=1usize)
        ck(good(r6, "ac"), b + 10, "inclusive single")
    }
}

fn pop_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var p = mk(k, "aé€😀z")
        var c1? = p.pop()
        ck(c1? && c1 == 'z' && good(p, "aé€😀"), b + 1, "pop ascii")
        var c2? = p.pop()
        ck(c2? && c2 == ch(0x1f600) && good(p, "aé€"), b + 2, "pop 4 byte")
        var c3? = p.pop()
        ck(c3? && c3 == ch(0x20ac) && good(p, "aé"), b + 3, "pop 3 byte")
        var c4? = p.pop()
        ck(c4? && c4 == ch(0xe9) && good(p, "a") && p.is_ascii(), b + 4, "pop 2 byte")
        var c5? = p.pop()
        ck(c5? && c5 == 'a' && good(p, ""), b + 5, "pop the last char")
        var c6? = p.pop()
        ck(!c6? && p.is_empty(), b + 6, "pop on empty")
        var e = mk(k, "")
        var c7? = e.pop()
        ck(!c7?, b + 7, "pop on a fresh empty")
    }
}

fn truncate_member() {
    for var k = 0; k < 3; k += 1 {
        var b = 100 * k
        var t = mk(k, "aé€😀z")
        t.truncate(100)
        ck(t == "aé€😀z", b + 1, "truncate past the end changes nothing")
        t.truncate(11)
        ck(t == "aé€😀z" && t.is_owned() == (k == 2), b + 2, "truncate to the size")
        t.truncate(10)
        ck(good(t, "aé€😀"), b + 3, "truncate before the last char")
        t.truncate(6)
        ck(good(t, "aé€"), b + 4, "truncate before the 4 byte char")
        t.truncate(3)
        ck(good(t, "aé"), b + 5, "truncate before the 3 byte char")
        t.truncate(1)
        ck(good(t, "a") && t.is_ascii(), b + 6, "truncate to ascii")
        t.truncate(0)
        ck(t.is_empty() && t.size() == 0, b + 7, "truncate to nothing")
        var u = mk(k, "abcdef")
        u.truncate(3)
        ck(good(u, "abc"), b + 8, "truncate ascii")
    }
}

fn clear_then_reuse() {
    var s = "héllo".to_owned()
    s.clear()
    s.push_str("é€")
    ck(good(s, "é€"), 1, "reuse after clear")
    s.clear()
    ck(s.is_empty() && s.codepoints() == 0 && s.is_ascii(), 2, "clear resets the count")
}

// A view that is modified becomes its own heap string; the text it borrowed
// is unchanged.
fn modified_view_leaves_source() {
    var src = "héllo wörld".to_owned()
    var v   = src[0..7].view()
    v.push('!')
    ck(v == "héllo !" && v.is_owned(), 1, "push on a view")
    ck(src == "héllo wörld" && v.data() != src.data(), 2, "the source is untouched by push")
    var w = src[7..].view()
    w.insert(0, ">")
    ck(w == ">wörld" && src == "héllo wörld", 3, "insert on a view")
    var x = src.view()
    x.remove_range(1usize..3usize)
    ck(x == "hllo wörld" && src == "héllo wörld", 4, "remove_range on a view")
    var y = src.view()
    y.truncate(6)
    ck(y == "héllo" && src == "héllo wörld", 5, "truncate on a view")
    var z = src.view()
    var c? = z.pop()
    ck(c? && c == 'd' && src == "héllo wörld" && z.size() == 12, 6, "pop on a view")
    var l = "literal"
    var lv = l.view()
    lv += " grows"
    ck(lv == "literal grows" && l == "literal", 7, "append to a view of a literal")
    // The owner can move while a copy of its text stays: copies do not alias.
    var owner = "stable".to_owned()
    var copy  = owner.copy()
    owner.push_str(" and longer than before, past the old capacity")
    ck(copy == "stable", 8, "a copy survives the owner growing")
}

fn main(argc: i32) -> i32 {
    var kind = argc - 1
    var text = "aé€😀z" // boundaries at 0 1 3 6 10 11
    var s    = text.to_owned()
    if kind == 0 {
        push_chars()
        push_str_and_append_assign()
        append_numbers()
        concat_and_operators()
        aliasing_appends()
        growth()
        insert_member()
        remove_range_member()
        pop_member()
        truncate_member()
        clear_then_reuse()
        modified_view_leaves_source()
        s.insert(3, "x")
        s.remove_range(3usize..4usize)
        s.truncate(10)
        return CODE
    }

    if kind == 1 { s.insert(2, "x") }                    // inside a char
    if kind == 2 { s.insert(12, "x") }                   // past the end
    if kind == 3 { s.insert(8, "x") }                    // inside a 4 byte char
    if kind == 4 { s.remove_range(1usize..2usize) }      // ends inside a char
    if kind == 5 { s.remove_range(4usize..6usize) }      // starts inside a char
    if kind == 6 { s.remove_range(6usize..12usize) }     // past the end
    if kind == 7 { s.remove_range(6usize..3usize) }      // begin after end
    if kind == 8 { s.remove_range(0usize..=11usize) }    // inclusive end past the length
    if kind == 9 { s.truncate(9) }                       // inside a char
    if kind == 10 { s.truncate(2) }                      // inside the 2 byte char
    if kind == 11 { var v = text.view(); v.truncate(4) } // on a view
    if kind == 12 { var l = "é"; l.insert(1, "x") }      // on a literal
    if kind == 13 { var l = "€"; l.remove_range(1usize..3usize) }
    if kind == 14 { var e = string(); e.insert(1, "x") } // empty, offset 1
    if kind == 15 { var e = string(); e.remove_range(0usize..1usize) }
    return s.size() as i32 & 0
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %kairo_new %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %t.o2.exe
// RUN: not --crash %t.exe 1
// RUN: not --crash %t.exe 1 2
// RUN: not --crash %t.exe 1 2 3
// RUN: not --crash %t.exe 1 2 3 4
// RUN: not --crash %t.exe 1 2 3 4 5
// RUN: not --crash %t.exe 1 2 3 4 5 6
// RUN: not --crash %t.exe 1 2 3 4 5 6 7
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14
// RUN: not --crash %t.exe 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
