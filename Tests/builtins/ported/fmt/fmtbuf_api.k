// The buffer an f-string is built in, used directly: `write`, `view`, `finish`, `clear`, `reserve`, the byte and
// code point counters, the inline capacity of 127 bytes and the spill past it, a buffer created with a capacity, and
// reuse after `finish`. FmtBuf is reached through its module path (the builtin root does not re-export it).
// Rules asserted (website library/core/formatting.mdx, FmtBuf: up to 127 bytes live inside the object, longer text
// spills to the heap; `FmtBuf(cap)` below 128 uses the inline storage, from 128 up the block is allocated now and
// sized once; `len` counts bytes and `cp_len` code points; `finish` hands the buffer over as an owned string and
// empties it; `view` is a borrowed string; `clear` empties the buffer; Lib/builtin/fmt/fmt_buf.k: after `finish()`
// and before anything is written, the view is the empty string).
// Not asserted because the docs do not state them: the capacity after a spill, and `data` after `clear`.
// Cases from Rust library/alloctests/tests/fmt.rs (writing into a String through fmt::Write: write_str, write_fmt)
// Cases from Rust library/coretests/tests/fmt/mod.rs (test_write, test_format_args: appending formatted pieces)
// Cases from the {fmt} library test/format-test.cc (memory_buffer: capacity, append, clear, resize)

import std::io::*
import builtin::fmt::fmt_buf::FmtBuf

var CODE: i32 = 0

fn ck(ok: bool, id: i32, const name: string) {
    if !ok {
        println(f"FAIL {name}")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn eq(const got: string, const want: string, id: i32, const name: string) {
    if !(got == want) {
        println(f"FAIL {name}: got [{got}] want [{want}]")
        if CODE == 0 {
            CODE = id
        }
    }
}

fn empty_buffer() {
    var b = FmtBuf()
    ck(b.len == 0, 1, "len of a new buffer")
    ck(b.cp_len == 0, 1, "cp_len of a new buffer")
    ck(b.cap == 127, 1, "inline capacity")
    eq(b.view(), "", 1, "view of a new buffer")
    var s = b.finish()
    eq(s, "", 1, "finish of a new buffer")
    ck(s.size() == 0, 1, "size of the empty result")
}

fn write_and_view() {
    var b = FmtBuf()
    b.write(f"x = {42}")
    eq(b.view(), "x = 42", 2, "one write")
    ck(b.len == 6 && b.cp_len == 6, 2, "counters after one write")
    b.write(f", y = {-7:>4}")
    eq(b.view(), "x = 42, y =   -7", 2, "second write appends")
    b.write("é☃😀")
    eq(b.view(), "x = 42, y =   -7é☃😀", 2, "a string argument")
    ck(b.len == 16 + 2 + 3 + 4 && b.cp_len == 16 + 3, 2, "bytes and code points differ for multi-byte text")
    var s = f"copy"
    b.write(s)
    eq(b.view(), "x = 42, y =   -7é☃😀copy", 2, "a string variable")
    b.write("")
    eq(b.view(), "x = 42, y =   -7é☃😀copy", 2, "an empty write changes nothing")
}

fn clear_and_reuse() {
    var b = FmtBuf()
    b.write("first")
    b.clear()
    ck(b.len == 0 && b.cp_len == 0, 3, "counters after clear")
    eq(b.view(), "", 3, "view after clear")
    b.write("second")
    eq(b.view(), "second", 3, "write after clear")
    b.clear()
    b.clear()
    ck(b.len == 0, 3, "clear twice")
    for var i = 0; i < 5; i += 1 {
        b.write(f"{i};")
    }

    eq(b.view(), "0;1;2;3;4;", 3, "write in a loop")
}

fn finish_hands_over() {
    var b = FmtBuf()
    b.write("owned text")
    var s = b.finish()
    eq(s, "owned text", 4, "finish returns the text")
    ck(s.size() == 10 && s.codepoints() == 10, 4, "size and code points of the result")
    ck(b.len == 0 && b.cp_len == 0, 4, "the buffer is empty after finish")
    eq(b.view(), "", 4, "view after finish is empty")
    s.push_str("!")
    eq(s, "owned text!", 4, "the result is an owned string")
    b.write("again")
    eq(b.view(), "again", 4, "write after finish")
    var t = b.finish()
    eq(t, "again", 4, "second finish")
    eq(s, "owned text!", 4, "the first result is unchanged")
    var u = b.finish()
    eq(u, "", 4, "finish of an empty buffer after a finish")
    b.write("é☃")
    var m = b.finish()
    ck(m.size() == 5 && m.codepoints() == 2, 4, "counters carry into the result")
}

fn spill() {
    var b = FmtBuf()
    for var i = 0; i < 127; i += 1 {
        b.write("a")
    }

    ck(b.len == 127 && b.cap == 127, 5, "127 bytes fit inline")
    b.write("b")
    ck(b.len == 128 && b.cap >= 128, 5, "the 128th byte spills")
    ck(b.cp_len == 128, 5, "code points after the spill")
    for var i = 0; i < 1000; i += 1 {
        b.write("c")
    }

    ck(b.len == 1128 && b.cap >= 1128, 5, "growth keeps the capacity at least the length")
    var s = b.finish()
    ck(s.size() == 1128, 5, "the result of a spilled buffer")
    ck(s.starts_with("aaaaaaaa") && s.ends_with("ccccc"), 5, "spilled content")
    var inside = true
    var bytes = s.bytes()
    for var i: usize = 0; i < 127; i += 1 {
        inside = inside && bytes[i] == 97
    }

    ck(inside && bytes[127] == 98 && bytes[128] == 99, 5, "bytes either side of the spill")
    b.write("again")
    eq(b.view(), "again", 5, "reuse after a spilled finish")
    b.clear()
    for var i = 0; i < 300; i += 1 {
        b.write("é")
    }

    ck(b.len == 600 && b.cp_len == 300, 5, "multi-byte text across the spill")
    b.clear()
    ck(b.len == 0 && b.cp_len == 0 && b.cap >= 127, 5, "clear keeps the storage")
    b.write("x")
    eq(b.view(), "x", 5, "write after clearing a spilled buffer")
}

fn with_capacity() {
    var small = FmtBuf(16)
    ck(small.cap == 127 && small.len == 0, 6, "a capacity below 128 uses the inline storage")
    small.write("abc")
    eq(small.view(), "abc", 6, "write into a small buffer")
    var exact = FmtBuf(127)
    ck(exact.cap == 127, 6, "capacity 127 is inline")
    var big = FmtBuf(200)
    ck(big.cap == 200 && big.len == 0, 6, "capacity 200 is allocated now and sized once")
    for var i = 0; i < 200; i += 1 {
        big.write("z")
    }

    ck(big.cap == 200 && big.len == 200, 6, "filling it exactly does not grow it")
    big.write("y")
    ck(big.len == 201 && big.cap >= 201, 6, "one byte more grows it")
    var s = big.finish()
    ck(s.size() == 201 && s.ends_with("zy"), 6, "result of a sized buffer")
    var edge = FmtBuf(128)
    ck(edge.cap == 128, 6, "capacity 128 is allocated now")
    var zero = FmtBuf(0)
    zero.write("q")
    eq(zero.view(), "q", 6, "capacity zero still works")
}

fn reserve() {
    var b = FmtBuf()
    b.reserve(500)
    ck(b.cap >= 500 && b.len == 0, 7, "reserve grows the capacity")
    b.write("abc")
    eq(b.view(), "abc", 7, "write after reserve")
    ck(b.len == 3, 7, "reserve adds no bytes")
    b.reserve(0)
    ck(b.len == 3, 7, "reserve zero")
    b.reserve(10)
    ck(b.cap >= 13, 7, "reserve counts from the length")
    eq(b.view(), "abc", 7, "reserve keeps the content")
}

fn main() -> i32 {
    empty_buffer()
    write_and_view()
    clear_and_reuse()
    finish_hands_over()
    spill()
    with_capacity()
    reserve()
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
