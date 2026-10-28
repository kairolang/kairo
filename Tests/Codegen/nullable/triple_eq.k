// G7 (Compiler/Sema/NULLABLE.md 2.3): `a === b` is `(a? && b?) && a == b`,
// built by CoalesceLowering and run. Covered: two `i32?` (equal, unequal,
// null on either side, both null); a non-nullable side (`a === 5`, only
// `a` is tested) and a literal typed against the other side's `T`
// (`u8? === 7`); a record whose `==` is its own Kairo `op ==` (which
// compares only `x`, so equal records with different `y` are `===`); an
// ADT with no `op ==` (tag compare); nullable POINTERS compared by
// pointee, where `==` compares addresses; a nullable and a plain pointer;
// call operands bound once, left to right, and not skipped by the test;
// `===` narrowing its places in the true branch; a generic `T?` body,
// whose `==` is its bound's (MONO.md D0: an unbounded T has none).
// Each line prints, so a wrong value shows which case broke.

import std::io::println

struct Pt {
    var x: i32
    var y: i32
    fn op ==(self, o: Pt) -> bool { return self.x == o.x }
}

enum Shape { Dot, Line { len: i32 } }

var calls = 0

fn find(k: i32) -> i32? { calls += 1; if k > 0 { return k } return null }
interface Eqable { fn op ==(self, o: Self) -> bool }
fn <T impl Eqable> same(a: T?, b: T?) -> bool { return a === b }

fn main() -> i32 {
    var a: i32? = 4
    var b: i32? = 4
    var c: i32? = 5
    var n: i32? = null
    var m: i32? = null
    println(f"values: {a === b} {a === c} {a === n} {n === a} {n === m}")
    println(f"plain: {a === 4} {4 === a} {a === 5} {n === 4}")
    var s: u8? = 7
    println(f"literal: {s === 7}")

    var p: Pt? = Pt{ x: 1, y: 2 }
    var q: Pt? = Pt{ x: 1, y: 9 }
    var r: Pt? = Pt{ x: 2, y: 2 }
    var z: Pt? = null
    println(f"record: {p === q} {p === r} {p === z} {p === Pt{ x: 1, y: 0 }}")

    var d1: Shape? = Shape::Dot
    var d2: Shape? = Shape::Dot
    var l1: Shape? = Shape::Line{ len: 3 }
    println(f"adt: {d1 === d2} {d1 === l1}")

    var i = 42
    var j = 42
    var k = 7
    var *pi? = &i
    var *pj? = &j
    var *pk? = &k
    var pn: (*i32)? = &null
    println(f"pointer: {pi === pj} {pi == pj} {pi === pk} {pi === pn} {pn === pn}")
    var *raw = &j
    println(f"mixed: {pi === raw} {pk === raw}")

    calls = 0
    println(f"once: {find(3) === find(3)} {find(-1) === find(3)} {find(2) === 2} calls={calls}")

    if a === b { println(f"narrowed: {a + b}") }

    var g: i32? = 4
    println(f"generic: {same(p, q)} {same(p, z)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      return(((!a.is_null()) &&(!b.is_null())) &&({
// CXX:      Eqable_witness<T>::__kairo_op_eq(__kairo_arg0, __kairo_arg1);
// CXX:      (((!a.is_null()) &&(!b.is_null())) &&(a.__value() == b.__value()));
// CXX:      ((!a.is_null()) &&(a.__value() == 4));
// CXX:      ((!s.is_null()) &&(s.__value() == 7));
// CXX:      (((!p.is_null()) &&(!q.is_null())) &&({
// CXX:      .operator ==(
// CXX:      (((!d1.is_null()) &&(!d2.is_null())) &&(d1.__value().__kairo_t.__kairo_tag == d2.__value().__kairo_t.__kairo_tag));
// CXX:      (((!pi.is_null()) &&(!pj.is_null())) &&((* pi.__value()) ==(* pj.__value())));
// CXX:      ((!pi.is_null()) &&((* pi.__value()) ==(* raw)));
// CXX:      (((!__kairo_coal{{[0-9]+}}.is_null()) &&(!__kairo_coal{{[0-9]+}}.is_null())) &&(static_cast<signed int &&>(__kairo_coal{{[0-9]+}}.__value()) == static_cast<signed int &&>(__kairo_coal{{[0-9]+}}.__value())));
// CXX-NOT:  {{[^=]}}==={{[^=]}}

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      values: true false false false false
// OUT-NEXT: plain: true true false false
// OUT-NEXT: literal: true
// OUT-NEXT: record: true false false true
// OUT-NEXT: adt: true false
// OUT-NEXT: pointer: true false false false false
// OUT-NEXT: mixed: true false
// OUT-NEXT: once: true false true calls=5
// OUT-NEXT: narrowed: 8
// OUT-NEXT: generic: true false
