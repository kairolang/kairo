// A nullable place proven non-null is used as its value by every form that
// takes an operand, and the program runs with the value. Each function
// checks its nullable first (`if !x? { return ... }`) and then uses it in
// one form:
//
//   - ranges: `a..b`, `a..=b`, both bounds narrowed, a range value, a range
//     whose bound is a field path or `*n` of a pointer capture, a range in
//     an `eval` function (type-checked only: an `eval` call taking a `T?`
//     is not yet a constant expression in C++);
//   - slices: of a string (`s[0..x]`, `s[x..]`, `s[..x]`, `s[..=x]`), of a
//     vector and of a fixed array;
//   - subscripts: a vector, a fixed array and a string indexed by the
//     value, a field path or `*n` as the index, a vector store `v[x] = 9`,
//     a map read `m[k]` and store `m[k] = x`;
//   - `x in v` over a vector and a set;
//   - forms that already took the value: an operator, compound
//     assignment, unary `-` and `~`, call arguments (plain, defaulted,
//     variadic, explicit generic), a constructor argument, a method and a
//     member through the narrowed record, `->` and `*` through a narrowed
//     pointer, tuple, array and struct literals, an f-string hole, `if` and
//     `while` conditions, `return`, `yield`, a value `if`, `??`, a closure
//     capturing by copy, a vector element store `v[0] = x`.
//
// Each check prints, so a wrong value shows which one.

import std::io::println

class P {
    pub var a: i32 = 1
    pub fn P(self) { }
    pub fn get(self) -> i32 { return self.a + 10 }
}

class C {
    pub var a: i32 = 0
    pub fn C(self, a: i32) { self.a = a }
}

struct S { pub var x: i32 = 0; pub var y: i32 = 0 }
struct Span { pub var end: usize? = null }

fn take(a: i32) -> i32 { return a }
fn take_def(a: i32, b: i32 = 2) -> i32 { return a + b }
fn take_var(...rest: i32) -> i32 { return rest[0] + rest[1] }
fn <T> same(a: T) -> T { return a }

// ranges

fn r_half_open(x: usize?) -> usize {
    if !x? { return 0 }
    var t: usize = 0
    for i in 0..x { t += i }
    return t
}

fn r_closed(x: usize?) -> usize {
    if x == null { return 0 }
    var t: usize = 0
    for i in x..=x + 2 { t += i }
    return t
}

fn r_both(a: usize?, b: usize?) -> usize {
    if !a? || !b? { return 0 }
    var t: usize = 0
    for i in a..b { t += i }
    return t
}

fn r_value(x: usize?) -> usize {
    if !x? { return 0 }
    var r = 1..x
    var t: usize = 0
    for i in r { t += i }
    return t
}

fn r_field(sp: Span) -> usize {
    if !sp.end? { return 0 }
    var t: usize = 0
    for i in 0..sp.end { t += i }
    return t
}

fn r_capture() -> usize {
    var n: usize? = 4
    var f = fn ()|*n| -> usize {
        if !(*n)? { return 0 }
        var t: usize = 0
        for i in 0..*n { t += i }
        return t
    }
    return f()
}

eval fn r_eval(x: i32?) -> i32 {
    if !x? { return 0 }
    var t = 0
    for i in 0..x { t += i }
    return t + x
}

// slices

fn s_string(const line: string) -> usize {
    var sep? = line.rfind(":")
    if !sep? { return 0 }
    var head = line[0..sep]
    var tail = line[sep + 1..]
    var upto = line[..sep]
    var incl = line[..=sep]
    return head.size() * 1000 + tail.size() * 100 + upto.size() * 10 + incl.size()
}

fn s_vector(n: usize?) -> i32 {
    var v: [i32] = [1, 2, 3, 4, 5]
    if !n? { return 0 }
    var t = 0
    for e in v[1..n] { t += e }
    for e in v[n..] { t += e * 100 }
    return t
}

fn s_array(n: usize?) -> i32 {
    var a: [i32; 4] = [1, 2, 3, 4]
    if !n? { return 0 }
    var t = 0
    for e in a[0..n] { t += e }
    return t
}

// subscripts

fn i_vector(x: usize?) -> i32 {
    var v: [i32] = [1, 2, 3]
    if !x? { return 0 }
    return v[x]
}

fn i_array(x: usize?) -> i32 {
    var v: [i32; 3] = [1, 2, 3]
    if !x? { return 0 }
    return v[x]
}

fn i_string(x: usize?) -> i32 {
    var s = string("abc")
    if !x? { return 0 }
    return s[x] as i32
}

fn i_field(sp: Span) -> i32 {
    var v: [i32] = [1, 2, 3, 4, 5, 6]
    var a: [i32; 6] = [10, 20, 30, 40, 50, 60]
    if !sp.end? { return 0 }
    return v[sp.end] + a[sp.end]
}

fn i_capture() -> i32 {
    var n: usize? = 1
    var v: [i32] = [1, 2, 3]
    var f = fn ()|*n, v| -> i32 {
        if !(*n)? { return 0 }
        return v[*n]
    }
    return f()
}

fn i_store(x: usize?) -> i32 {
    var v: [i32] = [1, 2, 3]
    if !x? { return 0 }
    v[x] = 9
    return v[0] + v[1] + v[2]
}

fn i_map(k: i32?, x: i32?) -> i32 {
    var m: {i32: i32} = {1: 2}
    if !k? || !x? { return 0 }
    var before = m[k]
    m[k] = x
    return before * 100 + m[k]
}

// containment

fn c_vector(x: string?) -> bool {
    var v: [string] = [string("a"), string("b")]
    if !x? { return false }
    return x in v
}

fn c_set(x: i32?) -> bool {
    var s: {i32} = {1, 2}
    if !x? { return false }
    return x in s
}

// forms that already took the value

fn o_ops(x: i32?) -> i32 {
    if !x? { return 0 }
    var a = 1
    a += x
    return a + x * 10 - -x + ~x
}

fn o_calls(x: i32?) -> i32 {
    if !x? { return 0 }
    return take(x) + take_def(x) + take_var(x, x) + same<i32>(x) + C(x).a
}

fn o_record(p: P?, q: unsafe *P?, n: unsafe *i32?) -> i32 {
    if !p? || !q? || !n? { return 0 }
    return p.get() + p.a + q->a + *n
}

fn o_literals(x: i32?) -> i32 {
    if !x? { return 0 }
    var t: (i32, i32) = (x, 1)
    var a: [i32; 2] = [x, 2]
    var v: [i32] = [x, 3]
    var s = S{ x: x, y: 4 }
    return t.0 + a[0] + v[0] + s.x
}

fn o_fstring(x: i32?) -> string {
    if !x? { return string("") }
    return f"<{x}>"
}

fn o_conditions(b: bool?) -> i32 {
    if !b? { return 0 }
    var t = 0
    if b { t += 1 }
    while b { t += 10; break }
    return t
}

fn o_gen(x: i32?) -> yield i32 {
    if !x? { return }
    yield x
}

fn o_value_forms(x: i32?, c: bool) -> i32 {
    if !x? { return 0 }
    var y = if c => x else => 1
    var z = x ?? 3
    var g = fn ()|x| -> i32 { return x }
    var v: [i32] = [0]
    v[0] = x
    return y + z + g() + v[0]
}

fn main() -> i32 {
    println(f"r_half_open {r_half_open(4)}")
    println(f"r_closed {r_closed(3)}")
    println(f"r_both {r_both(2, 5)}")
    println(f"r_value {r_value(4)}")
    var sp = Span()
    sp.end = 5
    println(f"r_field {r_field(sp)}")
    println(f"r_capture {r_capture()}")
    println(f"s_string {s_string(string("ab:cde"))}")
    println(f"s_vector {s_vector(3)}")
    println(f"s_array {s_array(3)}")
    println(f"i_vector {i_vector(2)}")
    println(f"i_array {i_array(1)}")
    println(f"i_string {i_string(1)}")
    println(f"i_field {i_field(sp)}")
    println(f"i_capture {i_capture()}")
    println(f"i_store {i_store(1)}")
    println(f"i_map {i_map(1, 7)}")
    println(f"c_vector {c_vector(string("b"))} {c_vector(string("z"))}")
    println(f"c_set {c_set(2)} {c_set(5)}")
    println(f"o_ops {o_ops(2)}")
    println(f"o_calls {o_calls(3)}")
    var p = P()
    var q = P()
    var n = 5
    println(f"o_record {o_record(p, &q, &n)}")
    println(f"o_literals {o_literals(6)}")
    println(f"o_fstring {o_fstring(8)}")
    println(f"o_conditions {o_conditions(true)}")
    var g = 0
    for e in o_gen(9) { g += e }
    println(f"o_gen {g}")
    println(f"o_value_forms {o_value_forms(2, true)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}
// RUN: rm -f %t.exe
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT: r_half_open 6
// OUT-NEXT: r_closed 12
// OUT-NEXT: r_both 9
// OUT-NEXT: r_value 6
// OUT-NEXT: r_field 10
// OUT-NEXT: r_capture 6
// OUT-NEXT: s_string 2323
// OUT-NEXT: s_vector 905
// OUT-NEXT: s_array 6
// OUT-NEXT: i_vector 3
// OUT-NEXT: i_array 2
// OUT-NEXT: i_string 98
// OUT-NEXT: i_field 66
// OUT-NEXT: i_capture 2
// OUT-NEXT: i_store 13
// OUT-NEXT: i_map 207
// OUT-NEXT: c_vector true false
// OUT-NEXT: c_set true false
// OUT-NEXT: o_ops 22
// OUT-NEXT: o_calls 20
// OUT-NEXT: o_record 18
// OUT-NEXT: o_literals 24
// OUT-NEXT: o_fstring <8>
// OUT-NEXT: o_conditions 11
// OUT-NEXT: o_gen 9
// OUT-NEXT: o_value_forms 8
