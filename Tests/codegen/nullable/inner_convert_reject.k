// `T? -> U?` keeps a null a null and converts a present value, including a
// present value that is zero or negative, and a derived pointer that is
// converted to a base pointer with a second base at a nonzero offset keeps
// pointing at the base subobject. Exit code 0 only when every case is right.

fn find(k: i32) -> i32? {
    if k >= 0 { return k }
    return null
}

class A { var a: i32 = 1 }
class B { var b: i32 = 2 }
class C derives A, B { var c: i32 = 3 }

fn main() -> i32 {
    var zero: i64? = find(0)
    var seven: i64? = find(7)
    var none: i64? = find(-1)
    if !zero? { return 1 }
    if zero != 0 { return 2 }
    if seven != 7 { return 3 }
    if none? { return 4 }
    var c = C()
    c.b = 9
    var pc: *C? = &c
    var pb: *B? = pc
    if !pb? { return 5 }
    if pb->b != 9 { return 6 }
    var pn: *C? = &null
    var pbn: *B? = pn
    if pbn? { return 7 }
    var pca: *const B? = pb
    if !pca? { return 8 }
    if pca->b != 9 { return 9 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -f %t.exe %t2.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -O0 -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t2.exe --cache-dir %t.d
// RUN: %t2.exe
