// A class `eval if` branch's fields are laid out where the branch is written
// (not after every other
// field), so `a; eval if X { b }; c` is laid out a, b, c: Kairo code cannot
// tell, but a C++ host (kcc) or an FFI struct mirror of the class can. Both
// the C++ member order and the offsets are checked.

eval X = true

class C {
    pub var a: i32 = 1
    eval if X {
        pub var b: i32 = 2
    } else {
        pub var nb: i64 = 0
    }
    pub var c: i32 = 3
    eval if !X {
        pub var nd: i32 = 0
    } else {
        pub var d: u8 = 4
    }
}

fn main() -> i32 {
    var o = C()
    unsafe {
        var base = (&o as unsafe *u8) as usize
        var pb   = (&o.b as unsafe *u8) as usize
        var pc   = (&o.c as unsafe *u8) as usize
        var pd   = (&o.d as unsafe *u8) as usize
        if pb - base != 4 { return 1 }
        if pc - base != 8 { return 2 }
        if pd - base != 12 { return 3 }
    }
    return o.a + o.b + o.c + (o.d as i32) - 10
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>/dev/null || true; } | %FileCheck %s --check-prefix=IR
// IR:      public: signed int a = 1;
// IR-NEXT: signed int b = 2;
// IR-NEXT: signed int c = 3;
// IR-NEXT: unsigned char d = 4;
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
