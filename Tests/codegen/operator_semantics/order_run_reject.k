// Left-to-right evaluation over neighbouring shapes: a three-field struct
// literal written in each non-declaration order, a binary `+` and `*`, and
// a call with three arguments. Each side effect appends a letter; the
// program exits 0 only when every letter sequence is the written order, at
// -O0 and -O2.

var log: [u8; 16]
var n: usize = 0

fn note(c: u8, v: i32) -> i32 { log[n] = c; n += 1; return v }
fn h3(a: i32, b: i32, c: i32) -> i32 { return a + b + c }

struct Tri { var a: i32; var b: i32; var c: i32 }

fn is(a: u8, b: u8, c: u8) -> bool {
    var ok = log[0] == a && log[1] == b && log[2] == c
    n = 0
    return ok
}

fn main() -> i32 {
    var t1 = Tri { c: note(99, 3), a: note(97, 1), b: note(98, 2) }
    if !is(99, 97, 98) { return 1 }
    var t2 = Tri { b: note(98, 2), c: note(99, 3), a: note(97, 1) }
    if !is(98, 99, 97) { return 2 }
    var s = note(120, 2) + note(121, 3) * note(122, 4)
    if !is(120, 121, 122) { return 3 }
    var k = h3(note(97, 1), note(98, 2), note(99, 3))
    if !is(97, 98, 99) { return 4 }
    if t1.a + t1.b + t1.c != 6 { return 5 }
    if t2.a != 1 || t2.b != 2 || t2.c != 3 { return 6 }
    if s != 14 || k != 6 { return 7 }
    return 0
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O0 -o %t.exe --cache-dir %t.d0
// RUN: %t.exe
// RUN: rm -f %t.exe
// RUN: %kairo %s -w -O2 -o %t.exe --cache-dir %t.d2
// RUN: %t.exe
