// string(c, n) is n copies of the byte c, NUL-terminated past its size; the
// (ptr, len) constructor is still chosen for a pointer first argument.

fn main() -> i32 {
    var a = string('-' as u8, 3)
    if a.size() != 3 { return 1 }
    if a.codepoints() != 3 { return 2 }
    if a[0] != '-' { return 3 }
    if a[2] != '-' { return 4 }
    if unsafe (a.c_str()[3]) != 0 { return 5 }
    var n: usize = 5
    var b = string(' ' as u8, n)
    if b.size() != 5 { return 6 }
    var z = string(0 as u8, 3)
    if z.size() != 3 { return 7 }
    var e = string('x' as u8, 0)
    if e.size() != 0 { return 8 }
    var p = string("abc".data(), 2)
    if p.size() != 2 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s -o %t.exe
// RUN: %t.exe
