// A generic ADT's variant whose one payload field names no parameter (`A { x:
// u8 }` in `enum <T> Gq`) built from an unsuffixed literal. C++ sees the
// literal as an `int`, an exact match only for the instance's lambda
// constructor (`template <class F> Gq(vt<0>, F&&)`), which then called it
// ("called object type 'int' is not a function"). The field's own type is
// written out, so the field constructor is the exact match.

enum <T> Gq { A { x: u8 }, B, C { y: f32 } }

fn get(g: Gq<i32>) -> i32 = match g {
    case .A(var x) => x as i32
    case .B => 0
    case .C(var y) => y as i32
}

fn main() -> i32 {
    var a: Gq<i32> = Gq<i32>::A { x: 7 }
    var c          = Gq<i32>::C { y: 2 }
    var b          = Gq<i32>::A { x: 7 as u8 }
    return get(a) + get(b) + get(c)
}

// --- lit wiring ---
// RUN: rm -f %t.exe
// RUN: { %kairo %s -o %t.exe 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty --implicit-check-not='error'
// RUN: %t.exe; test $? -eq 16
// DIAG-NOT: CL001E
