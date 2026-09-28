// f-strings through X, FStringLowering, FmtBuf and clang. Every primitive
// spelling, width/fill/align/sign/#/0, precision, a record through `op as`,
// one through `repr`, one through neither (address form), pointers, `&null`,
// `{x=}`, a nested f-string, and source-order evaluation of the holes.

fn chk(c: bool) -> i32 { if c { return 1 } return 0 }

fn starts_with(const s: string, const p: string) -> bool {
    if s.len < p.len { return false }
    for var i: usize = 0; i < p.len; ++i { if s.data[i] != p.data[i] { return false } }
    return true
}

struct Vec2 {
    var x: f64
    var y: f64
    fn op as(self) -> string { return f"({self.x}, {self.y})" }     // nested f-string
}

struct Id {
    var n: i32
}

extend Id {
    fn repr(self) -> string { return f"Id#{self.n}" }
}

struct Bare { var v: i32 }

fn bump(c: *i32, d: i32) -> i32 { *c = *c * 10 + d; return d }

fn main() -> i32 {
    var x: i32 = 42
    var v  = Vec2{ x: 1.5, y: 2.0 }
    var id = Id{ n: 7 }

    var s = f"x={x:>4} v={v} id={id} h={x:#x} b={x:b} o={x:o} X={255:X}"
    // "x=  42 v=(1.5, 2) id=Id#7 h=0x2a b=101010 o=52 X=FF"      51 bytes

    var t = f"{true} {'a'} {x=} {x:^7} {x:_<5} {x:+} {x:05}"
    // "true a x=42   42    42___ +42 00042"                       35 bytes

    var c: i32 = 0
    var o = f"{bump(&c, 1)}{bump(&c, 2)}"                           // "12", and c == 12

    var u = f"{0.5:.2}|{-3:>4}|{c}"                                 // "0.5|  -3|12"  11 bytes

    var p  = &x
    var ps = f"{p}"                                                 // "i32 @ 0x..."
    var b  = Bare{ v: 1 }
    var bs = f"{b}"                                                 // "Bare @ 0x..."
    var np: *i32 = &null
    var ns = f"{np}"                                                // "&null"

    // 51 + 35 + 2 + 11 + 4 == 103
    // Accumulated: a newline ends a statement, so a `+` leading the next
    // line would start a new, unreachable one.
    var n = (s.len + t.len + o.len + u.len) as i32
    n += chk(c == 12)
    n += chk(starts_with(ps, "i32 @ 0x"))
    n += chk(starts_with(bs, "Bare @ 0x"))
    n += chk((ns.len == 5) && starts_with(ns, "&null"))
    return n
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: error

// The shape: one FmtBuf per f-string, straight-line puts, the holes' locals
// in source order, no f-string left.
// RUN: { %kairo %s --print-lowered 2>&1 || true; } | %FileCheck %s --check-prefix=LOW
// LOW: __kairo_arg0
// LOW: __kairo_fmt
// LOW: put_i32
// LOW: put_str
// LOW: finish
// LOW-NOT: is_format

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.d
// RUN: %clangxx %t.d/*.o %t.d/builtin/*.o %t.d/kairo/*.o -o %t.exe
// RUN: %t.exe; test $? -eq 103
