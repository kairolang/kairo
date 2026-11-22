// Every form a whole local can be transferred in (ownership.mdx, Moved-From
// State): struct, tuple, array and enum construction, a generic class, a
// nullable, assignment to a field, an element or through a pointer, a
// statement expression, an f-string argument, a global, a loop condition.
// R counts live objects: made equals released after each scenario, in both
// modes, with the same destruction order.
import std::io::println

var made: i32 = 0
var released: i32 = 0
var fails: i32 = 0

class R {
    var id: i32 = 0
    fn R(self, id: i32) { self.id = id; made += 1 }
    @move fn R(self, other: Self) { self.id = other.id; other.id = 0 }
    fn op finally(self) {
        if self.id != 0 {
            println(f"~R {self.id}")
            released += 1
            self.id = 0
        }
    }
}

fn chk(name: string) {
    if made != released {
        println(f"FAIL {name}: made {made} released {released}")
        fails += 1
    }
    made = 0
    released = 0
}

fn take(r: R) { println(f"took {r.id}") }
fn yes(r: R) -> bool { println(f"yes {r.id}"); return true }
fn no(r: R) -> bool { println(f"no {r.id}"); return false }
fn pick(c: bool) -> bool { return c }
fn consume(r: R) -> i32 { return r.id }
fn opt_int(c: bool) -> i32? {
    if c { return 1 }
    return null
}
fn may(x: i32) panic -> i32 {
    if x > 0 { panic "boom" }
    return x
}
fn two(r: R, x: i32) { println(f"two {r.id} {x}") }
fn two_r(x: i32, r: R) { println(f"two_r {r.id} {x}") }
fn bump(r: R) -> R { return R(r.id + 100) }
fn pass(r: R) -> R { return r }

struct S { var r: R }
class H { var r: R; var n: i32 = 0; fn H(self, x: i32) { self.r = R(x) } }
enum Slot { Full { r: R }, Empty }
class <T> Box { var v: T; fn Box(self, v: T) { self.v = v } }
fn take_opt(o: R?) { println(f"opt {o?.id ?? -1}") }
fn take_box(b: Box<R>) { println(f"box {b.v.id}") }
fn take_s(s: S) { println(f"s {s.r.id}") }
fn take_slot(s: Slot) {
    match s {
        case .Full(const r) { println(f"full {r.id}") }
        default { println("empty") }
    }
}
fn set_field(h: H, r: R) { h.r = r }

fn c_struct(c: bool) { var a = R(1); if c { var s = S { r: a }; println(f"s {s.r.id}") } }
fn c_struct_arg(c: bool) { var a = R(2); if c { take_s(S { r: a }) } }
fn c_tuple(c: bool) { var a = R(3); var b = R(4); if c { var t = (a, b); println(f"t {t.0.id}") } }
fn c_tuple_ret(c: bool) -> (R, i32) { var a = R(5); if c { return (a, 1) }; return (R(50), 2) }
fn c_box(c: bool) { var a = R(6); if c { var b = Box<R>(a); println(f"b {b.v.id}") } }
fn c_box_arg(c: bool) { var a = R(7); if c { take_box(Box<R>(a)) } }
fn c_arr_lit(c: bool) { var a = R(8); var b = R(9); if c { var xs = [a, b]; println(f"xs {xs.size()}") } }
fn c_vec_push(c: bool) { var a = R(10); var xs: [R] = []; if c { xs.push(a) }; println(f"xs {xs.size()}") }
fn c_vec_push2(n: i32) {
    var xs: [R] = []
    for i in 0..n { var a = R(11 + i); if i % 2 == 0 { xs.push(a) } }
    println(f"xs {xs.size()}")
}
fn c_nullable(c: bool) { var a = R(12); if c { var o: R? = a; println(f"o {o?.id ?? -1}") } }
fn c_nullable_arg(c: bool) { var a = R(13); if c { take_opt(a) } }
fn c_nullable_assign(c: bool) {
    var a = R(14); var o: R? = null
    if c { o = a }
    println(f"o {o?.id ?? -1}")
}
fn c_nullable_ret(c: bool) -> R? { var a = R(15); if c { return a }; return null }
fn c_field_assign(c: bool) {
    var h = H(16); var a = R(160)
    if c { h.r = a }
    println(f"h {h.r.id}")
}
fn c_field_assign_both(c: bool) {
    var h = H(17); var a = R(170)
    if c { h.r = a } else { take(a) }
    println(f"h {h.r.id}")
}
fn c_field_call(c: bool) { var h = H(18); var a = R(180); if c { set_field(h, a) } }
fn c_ptr_assign(c: bool) {
    var a = R(19); var b = R(190)
    var *p = &b
    if c { *p = a }
    println(f"b {b.id}")
}
fn c_index_assign(c: bool) {
    var xs: [R] = []
    xs.push(R(20))
    var a = R(200)
    if c { xs[0] = a }
    println(f"xs {xs[0].id}")
}
fn c_enum(c: bool) { var a = R(21); if c { take_slot(Slot::Full { r: a }) } }
fn c_enum_var(c: bool) { var a = R(22); var s = if (c) => Slot::Full { r: a } else => Slot::Empty; take_slot(s) }
fn c_enum_match(c: bool) {
    var s = Slot::Full { r: R(23) }
    if c {
        match s {
            case .Full(var r) { take(r) }
            default { }
        }
    }
    println("em end")
}
fn c_stmt_expr(c: bool) {
    var a = R(24)
    var n = ({ if c { take(a) }; 5 })
    println(f"n {n}")
}
fn c_stmt_expr_ret(c: bool) -> i32 {
    var a = R(25)
    var n = ({ if c { take(a); return 1 }; 5 })
    return n
}
fn c_global(c: bool) {
    var a = R(26)
    if c { gslot = a }
}
var gslot: R = R(0 + 99)
fn c_closure_move(c: bool) {
    var a = R(27)
    var f = fn ()|a| { take(a) }
    if c { f() }
}
fn c_ctor_forward(c: bool) { var a = R(28); if c { var h = H2(a); println(f"h2 {h.r.id}") } }
class H2 { var r: R; fn H2(self, r: R) { self.r = r } }
fn c_ret_member(c: bool) -> R { var h = H(29); var x = h.r; if c { h.r = R(290) }; return x }
fn c_try_arg(x: i32) { var a = R(30); try { take(a); var v = may(x) } catch { println("c") } }
fn c_sum(x: i32) {
    var a = R(31)
    try { var v = consume(a) + may(x); println(f"v {v}") } catch { println("c") }
}
fn c_sum_rev(x: i32) {
    var a = R(32)
    try { var v = may(x) + consume(a); println(f"v {v}") } catch { println("c") }
}
fn c_fstring(c: bool) { var a = R(33); if c { println(f"v {consume(a)}") } }
fn c_while_cond(n: i32) {
    var a = R(34)
    var i = 0
    while consume(a) < 100 {
        i += 1
        a = R(340 + i)
        if i >= n { a = R(0 + 9999) ; break }
    }
}

fn main() -> i32 {
    made = 0
    for c in [true, false] { c_struct(c); chk("c_struct") }
    for c in [true, false] { c_struct_arg(c); chk("c_struct_arg") }
    for c in [true, false] { c_tuple(c); chk("c_tuple") }
    for c in [true, false] { { var t = c_tuple_ret(c); println(f"t {t.0.id}") }; chk("c_tuple_ret") }
    for c in [true, false] { c_box(c); chk("c_box") }
    for c in [true, false] { c_box_arg(c); chk("c_box_arg") }
    for c in [true, false] { c_arr_lit(c); chk("c_arr_lit") }
    for c in [true, false] { c_vec_push(c); chk("c_vec_push") }
    for n in 0..4 { c_vec_push2(n); chk("c_vec_push2") }
    for c in [true, false] { c_nullable(c); chk("c_nullable") }
    for c in [true, false] { c_nullable_arg(c); chk("c_nullable_arg") }
    for c in [true, false] { c_nullable_assign(c); chk("c_nullable_assign") }
    for c in [true, false] { { var o? = c_nullable_ret(c); println(f"o {o?.id ?? -1}") }; chk("c_nullable_ret") }
    for c in [true, false] { c_field_assign(c); chk("c_field_assign") }
    for c in [true, false] { c_field_assign_both(c); chk("c_field_assign_both") }
    for c in [true, false] { c_field_call(c); chk("c_field_call") }
    for c in [true, false] { c_ptr_assign(c); chk("c_ptr_assign") }
    for c in [true, false] { c_index_assign(c); chk("c_index_assign") }
    for c in [true, false] { c_enum(c); chk("c_enum") }
    for c in [true, false] { c_enum_var(c); chk("c_enum_var") }
    for c in [true, false] { c_enum_match(c); chk("c_enum_match") }
    for c in [true, false] { c_stmt_expr(c); chk("c_stmt_expr") }
    for c in [true, false] { println(f"r {c_stmt_expr_ret(c)}"); chk("c_stmt_expr_ret") }
    for c in [true, false] { c_global(c); chk("c_global") }
    for c in [true, false] { c_closure_move(c); chk("c_closure_move") }
    for c in [true, false] { c_ctor_forward(c); chk("c_ctor_forward") }
    for c in [true, false] { { var x = c_ret_member(c); println(f"x {x.id}") }; chk("c_ret_member") }
    for x in 0..2 { c_try_arg(x); chk("c_try_arg") }
    for x in 0..2 { c_sum(x); chk("c_sum") }
    for x in 0..2 { c_sum_rev(x); chk("c_sum_rev") }
    for c in [true, false] { c_fstring(c); chk("c_fstring") }
    for n in 0..3 { c_while_cond(n); chk("c_while_cond") }
    println(f"fails {fails}")
    return fails
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.off.d
// RUN: rm -f %t.exe %t.off.exe %t.out %t.off.out
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %kairo %s -fno-destructive-moves -o %t.off.exe --cache-dir %t.off.d
// RUN: %t.exe > %t.out
// RUN: %t.off.exe > %t.off.out
// RUN: diff %t.out %t.off.out
// RUN: %FileCheck %s --check-prefix=OUT --input-file=%t.out
// OUT-NOT: FAIL
// OUT: fails 0
