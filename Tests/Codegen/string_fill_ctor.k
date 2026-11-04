// string(c, n) is n copies of the byte c; the (ptr, len) constructor is
// still chosen for a pointer first argument.

fn main() -> i32 {
    var a = string('-' as u8, 3)
    if a.length() != 3 { return 1 }
    if a.codepoints() != 3 { return 2 }
    if a[0] != '-' as u8 { return 3 }
    if a[2] != '-' as u8 { return 4 }
    if a[3] != 0 { return 5 }
    var n: usize = 5
    var b = string(' ' as u8, n)
    if b.length() != 5 { return 6 }
    var z = string(0 as u8, 3)
    if z.length() != 3 { return 7 }
    var e = string('x' as u8, 0)
    if e.length() != 0 { return 8 }
    var p = string("abc".as_ptr(), 2)
    if p.length() != 2 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
