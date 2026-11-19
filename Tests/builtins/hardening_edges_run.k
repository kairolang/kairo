// Edges of the library that must not misbehave: a window wider than any
// slice, a view of a finished format buffer, appending into a reserved
// vector, and shrinking or reserving nothing on a string that owns no block.
import std::io
import builtin::fmt::fmt_buf::FmtBuf

fn main() -> i32 {
    var v: [i32] = [1, 2, 3, 4, 5]
    var s: [const i32;] = v

    // `i + n` wraps for these widths; no window may be produced.
    var huge: [usize] = [usize::MAX, usize::MAX - 1, usize::MAX - 4, 6]
    for const *n in huge {
        for w in s.windows(*n) {
            return 1
        }
    }

    var count = 0
    for w in s.windows(5) {
        count += 1
    }

    for w in s.windows(2) {
        count += 1
    }

    if count != 5 {
        return 2
    }

    var b = FmtBuf()
    b.write("abc")
    var done = b.finish()
    if done != "abc" {
        return 3
    }

    if b.view().size() != 0 {
        return 4
    }

    var into: [i32] = []
    into.reserve(100)
    var cap = into.capacity()
    var small: [i32] = [7, 8, 9]
    into.append(small)
    if into.capacity() != cap || into.size() != 3 || into[2] != 9 {
        return 5
    }

    var none: [i32] = []
    var big: [i32]  = [1, 2, 3, 4]
    none.append(big)
    if none.size() != 4 || none[3] != 4 {
        return 6
    }

    var lit: string = "hello"
    lit.truncate(0)
    if lit.size() != 0 || lit.capacity() != 0 {
        return 7
    }

    var lit2: string = "hello"
    lit2.reserve(0)
    if lit2.capacity() != 0 || lit2 != "hello" {
        return 8
    }

    var empty = string()
    empty.reserve(0)
    if empty.capacity() != 0 {
        return 9
    }

    io::println("ok")
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe %t.o2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe | %FileCheck %s
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe | %FileCheck %s
// CHECK: ok
