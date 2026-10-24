// `.Variant` as a parameter's default value takes its enum from the
// parameter's declared type, as an initializer does: `c: Color = .Blue` is
// `Color::Blue`. The default must be what an omitted argument gets, and an
// explicit argument must still win over it -- on a free function, on a
// method, and for an ADT's payload-free variant.

enum Color { Red, Green, Blue }
enum Opt { None, Some { v: i32 } }

fn pick(c: Color = .Blue) -> i32 {
    if c == .Blue { return 1; }
    if c == .Red  { return 2; }
    return 0;
}

fn unwrap_or(o: Opt = .None, d: i32 = 0) -> i32 {
    if o == .None { return d; }
    return 100;
}

class Pen {
    var w: i32 = 1
    fn tint(self, c: Color = .Green) -> i32 {
        if c == .Green { return 4; }
        return 0;
    }
}

fn main() -> i32 {
    var r = 0;
    r = r + pick();                       // 1: the default
    r = r + pick(.Red) * 1;               // 2: an explicit dotted argument wins
    if unwrap_or() == 0 { r = r + 8; }    // the ADT default
    if unwrap_or(.None, 16) == 16 { r = r + 16; }
    var p = Pen();
    r = r + p.tint();                     // 4: a method's default
    return r;   // 31
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 31
