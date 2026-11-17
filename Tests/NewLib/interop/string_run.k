// `string` and the C++ strings. A `string` converts implicitly to
// `std::string_view` in every state (literal, view, heap, empty) with no
// copy: the view points at the string's own bytes and needs no NUL after
// them. `s as std::string` copies the bytes, an embedded NUL included.
// The way back is the `ByteRange` constructor, which validates UTF-8 and
// copies: invalid bytes from C++ trap there, and `string::from_utf8` over
// the same bytes returns null instead. With an argument the program builds
// a string from invalid C++ bytes and traps; with none every check passes.

ffi "c++" import "string"
ffi "c++" import "string_view"

import std::io

var checks:   u64 = 0
var failures: u64 = 0

fn ck(cond: bool, const what: string) {
    checks += 1
    if !cond {
        failures += 1
        io::println(f"FAIL {what}")
    }
}

fn sv_len(v: cxx::std::string_view) -> usize {
    return v.size()
}

fn sv_at(v: cxx::std::string_view) -> usize {
    unsafe {
        return v.data() as unsafe *const u8 as usize
    }
}

fn at(const s: string) -> usize {
    unsafe {
        return s.data() as unsafe *const u8 as usize
    }
}

fn cxx_bytes(const b: [const u8;]) -> cxx::std::string {
    unsafe {
        return cxx::std::string(&b[0] as unsafe *const u8 as unsafe *const __builtin_c_char, b.size())
    }
}

fn views() {
    var lit = "hello"
    ck(sv_len(lit) == 5 && sv_at(lit) == at(lit), "literal: same bytes")
    var v: cxx::std::string_view = lit
    ck(v.size() == 5 && v.compare("hello") == 0, "literal: initialised view")
    var heap = f"a heap string of {lit} and more than fifteen bytes"
    ck(heap.is_owned() && sv_len(heap) == heap.size() && sv_at(heap) == at(heap), "heap: same bytes")
    var mid = heap[2..6]
    ck(mid.is_view() && sv_len(mid) == 4 && sv_at(mid) == at(heap) + 2, "view: same bytes, no NUL")
    var e = string()
    ck(sv_len(e) == 0, "empty")
    var wide = "aé€😀z"
    ck(sv_len(wide) == 11, "non-ASCII: byte length")
}

fn owned() {
    var s = f"copied {42} into a std::string"
    var c = s as cxx::std::string
    unsafe {
        ck(c.size() == s.size() && sv_at(s) != (c.data() as unsafe *const u8 as usize), "as: a copy")
    }

    ck(string(c) == s, "as: same bytes")
    s.push_str("!")
    ck(c.size() + 1 == s.size(), "as: independent of the source")
    var z = string(b"a\x00b")
    var zc = z as cxx::std::string
    ck(zc.size() == 3 && z.size() == 3, "as: embedded NUL kept")
    var e = string() as cxx::std::string
    ck(e.size() == 0, "as: empty")
}

fn back() {
    var c = cxx::std::string("from C++ é")
    var k = string(c)
    ck(k.size() == 11 && k == "from C++ é" && k.codepoints() == 10, "ByteRange: std::string")
    var sv = cxx::std::string_view(c.data(), c.size())
    var kv = string(sv)
    ck(kv == k && kv.is_owned(), "ByteRange: std::string_view, owned")
    var round = string("round trip ✓" as cxx::std::string)
    ck(round == "round trip ✓", "round trip")
    var bad = cxx_bytes(b"ok\xc3(")
    unsafe {
        var bytes = Slice<const u8>(bad.data() as unsafe *const u8, bad.size())
        ck(string::from_utf8(bytes) == null, "from_utf8: invalid C++ bytes give null")
        var good = Slice<const u8>(c.data() as unsafe *const u8, c.size())
        var g = string::from_utf8(good)
        ck(g != null && unwrap!(g) == k, "from_utf8: valid C++ bytes")
    }
}

fn main(argc: i32) -> i32 {
    if argc > 1 {
        var bad = cxx_bytes(b"\xff\xfe")
        var s   = string(bad) // traps: not UTF-8
        return s.size() as i32
    }

    views()
    owned()
    back()
    io::println(f"string interop: checks={checks} failures={failures}")
    return failures as i32
}

// --- lit wiring ---
// REQUIRES: newlib
// RUN: rm -rf %t.d
// RUN: %kairo_new %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s --match-full-lines
// RUN: not --crash %t.exe trap
// RUN: %kairo_new -O2 %s -o %t.o2.exe --cache-dir %t.d2
// RUN: %t.o2.exe | %FileCheck %s --match-full-lines
// RUN: not --crash %t.o2.exe trap
// CHECK: string interop: checks=16 failures=0
