// OperatorSemantics: the C++ each wrap form is spelled as (EmitIR, "the wrap
// forms"). Pure forms cast through an unsigned carrier never narrower than
// `unsigned int`; binding forms are statement expressions.

struct Node { var count: i32 }

fn arith(a: i32, b: i32, c: i32, p: u16, q: u16, flags: u8, v: i64, n: i64) -> i64 {
    var x = a + b * c
    var y: u16 = p * q
    var m = ~flags
    var s = v << n
    var t = v >> n
    var narrow = flags & 3u8
    return s + t + (x as i64) + (y as i64) + (m as i64) + (narrow as i64)
}

fn places(node: *Node, buf: *[i32; 4], delta: i32) -> i32 {
    var total: i32 = 0
    total += delta
    node->count++
    (*buf)[1] += delta
    var i: i32 = 0
    var old = i++
    return total + old
}

fn divs(a: i32, b: i32, ua: u32, ub: u32) -> i32 = (a / b) + ((ua % ub) as i32)

fn loop_iv(n: i32) -> i32 {
    var s: i32 = 0
    for k in 0..n { s += k }
    return s
}

fn main() -> i32 { return 0 }

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX-LABEL: CODEGEN C++: {{.*}}wrap_forms.k
// CXX: signed int x = static_cast<signed int>(static_cast<unsigned int>(a) + static_cast<unsigned int>(static_cast<signed int>(static_cast<unsigned int>(b) * static_cast<unsigned int>(c))));
// CXX: unsigned short y = static_cast<unsigned short>(static_cast<unsigned int>(p) * static_cast<unsigned int>(q));
// CXX: unsigned char m = static_cast<unsigned char>(~static_cast<unsigned int>(flags));
// CXX: s = static_cast<signed long{{( long)?}}>(static_cast<unsigned long{{( long)?}}>(v) <<(static_cast<unsigned long{{( long)?}}>(n) & static_cast<unsigned long{{( long)?}}>(63)));
// CXX: t = static_cast<signed long{{( long)?}}>(static_cast<signed long{{( long)?}}>(v) >>(static_cast<unsigned long{{( long)?}}>(n) & static_cast<unsigned long{{( long)?}}>(63)));
// CXX: unsigned char narrow = static_cast<unsigned char>((flags) &((static_cast<unsigned char>(3))));
//
// A local place binds nothing; any other is bound once, `auto&`, and in
// statement position the form's trailing value is left out.
// CXX: (total = static_cast<signed int>(static_cast<unsigned int>(total) + static_cast<unsigned int>(delta)));
// CXX: auto & __kairo_p0 =(node->count);
// CXX-NEXT: __kairo_p0 = static_cast<signed int>(static_cast<unsigned int>(__kairo_p0) + static_cast<unsigned int>(1));
// CXX-NEXT: }
// CXX: auto & __kairo_p0 =((* buf)[1]);
// CXX-NEXT: __kairo_p0 = static_cast<signed int>(static_cast<unsigned int>(__kairo_p0) + static_cast<unsigned int>(delta));
// CXX: signed int __kairo_o0 = i;
// CXX-NEXT: i = static_cast<signed int>(static_cast<unsigned int>(i) + static_cast<unsigned int>(1));
// CXX-NEXT: __kairo_o0;
//
// Division binds its operands; an unsigned one has no -1 arm.
// CXX: signed int __kairo_a0 =(a);
// CXX-NEXT: signed int __kairo_b0 =(b);
// CXX-NEXT: if(__builtin_expect(__kairo_b0 == 0, 0))::kairo_rt_div_zero();
// CXX-NEXT: (__kairo_b0 == - 1) ? static_cast<signed int>(static_cast<unsigned int>(0) - static_cast<unsigned int>(__kairo_a0)): static_cast<signed int>(__kairo_a0 / __kairo_b0);
// CXX: unsigned int __kairo_a0 =(ua);
// CXX-NEXT: unsigned int __kairo_b0 =(ub);
// CXX-NEXT: if(__builtin_expect(__kairo_b0 == 0, 0))::kairo_rt_div_zero();
// CXX-NEXT: static_cast<unsigned int>(__kairo_a0 % __kairo_b0);
//
// IterLowering's index never passes its bound: C++'s own `++` (no_wrap).
// CXX: signed int loop_iv(signed int n) noexcept {
// CXX: (++ __kairo_i{{[0-9]+}});
