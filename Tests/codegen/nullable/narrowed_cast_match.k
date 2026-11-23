// A nullable place proven non-null is read as its value by a cast and by a
// match. Each function checks its nullable first (`if !x? { return ... }`)
// and then uses it in one form:
//
//   - casts: to its own `T` (`x as i64` on an `i64?`), to a wider and to
//     a float type, a pointer to `usize`, a field path, a local proven by
//     its initializer;
//   - matches: with no `case null` arm, with a `case null` first arm (never
//     taken: the scrutinee is the value), a binding pattern binding the
//     `T`, the value form with and without `case null`, a `bool?` whose
//     `true` and `false` arms are exhaustive, an enum, a field path, and
//     the state after the match.
//
// Each check prints, so a wrong value shows which one.

import std::io::println

struct Span { pub var end: usize? = null }

enum Color { Red, Green, Blue }

// casts

fn c_same(x: i64?) -> i64 {
    if !x? { return -1 }
    var a = x as i64
    return a
}

fn c_widen(x: i32?) -> i64 {
    if x == null { return -1 }
    var a = x as i64
    return a * 2
}

fn c_float(x: i32?) -> f64 {
    if !x? { return -1.0 }
    return x as f64 / 2.0
}

fn c_ptr(p: (*i32)?) -> bool {
    if !p? { return false }
    return p as usize != 0 as usize
}

fn c_field(sp: Span) -> u32 {
    if !sp.end? { return 0 }
    return sp.end as u32 + 1
}

fn c_local() -> u8 {
    var y: i32? = 300
    return y as u8
}

// matches

fn m_no_null(x: i32?) -> i32 {
    if !x? { return -1 }
    match x {
        case 1 { return 10 }
        case 2..=5 { return 20 }
        default { return 30 }
    }
}

fn m_null_kept(x: i32?) -> i32 {
    if !x? { return -1 }
    match x {
        case null { return 99 }
        case 1 { return 11 }
        default { return 31 }
    }
}

fn m_bind(x: i32?) -> i32 {
    if x == null { return -1 }
    match x {
        case var v where v > 10 { return v * 2 }
        case var v { return v }
    }
}

fn m_expr(x: i32?) -> string {
    if !x? { return "none" }
    return match x {
        case 0 => "zero"
        default => f"some {x}"
    }
}

fn m_expr_null(x: i32?) -> string {
    if !x? { return "none" }
    return match x {
        case null => "null"
        case 0 => "zero"
        default => f"some {x + 1}"
    }
}

fn m_bool(b: bool?) -> i32 {
    if !b? { return -1 }
    match b {
        case true { return 1 }
        case false { return 0 }
    }
}

fn m_enum(c: Color?) -> i32 {
    if !c? { return -1 }
    match c {
        case Color::Red { return 1 }
        case Color::Green { return 2 }
        case Color::Blue { return 3 }
    }
}

fn m_field(sp: Span) -> i32 {
    if !sp.end? { return -1 }
    match sp.end {
        case null { return 99 }
        case 4 { return 40 }
        default { return 0 }
    }
}

fn m_after(x: i32?) -> i32 {
    if !x? { return -1 }
    var r = 0
    match x {
        case null { r = 99 }
        case 3 { r = 30 }
        default { r = 1 }
    }
    return r + x
}

fn main() -> i32 {
    var v: i32 = 5
    var sp = Span{}
    sp.end = 4 as usize
    println(f"c_same {c_same(7)} {c_same(null)}")
    println(f"c_widen {c_widen(21)} {c_widen(null)}")
    println(f"c_float {c_float(5)}")
    println(f"c_ptr {c_ptr(&v)} {c_ptr(null)}")
    println(f"c_field {c_field(sp)} {c_field(Span{})}")
    println(f"c_local {c_local()}")
    println(f"m_no_null {m_no_null(1)} {m_no_null(4)} {m_no_null(9)} {m_no_null(null)}")
    println(f"m_null_kept {m_null_kept(1)} {m_null_kept(0)} {m_null_kept(null)}")
    println(f"m_bind {m_bind(12)} {m_bind(3)}")
    println(f"m_expr {m_expr(0)} {m_expr(6)} {m_expr(null)}")
    println(f"m_expr_null {m_expr_null(0)} {m_expr_null(6)} {m_expr_null(null)}")
    println(f"m_bool {m_bool(true)} {m_bool(false)} {m_bool(null)}")
    println(f"m_enum {m_enum(Color::Green)} {m_enum(Color::Blue)} {m_enum(null)}")
    println(f"m_field {m_field(sp)} {m_field(Span{})}")
    println(f"m_after {m_after(3)} {m_after(8)}")
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
// OUT: c_same 7 -1
// OUT-NEXT: c_widen 42 -1
// OUT-NEXT: c_float 2.5
// OUT-NEXT: c_ptr true false
// OUT-NEXT: c_field 5 0
// OUT-NEXT: c_local 44
// OUT-NEXT: m_no_null 10 20 30 -1
// OUT-NEXT: m_null_kept 11 31 -1
// OUT-NEXT: m_bind 24 3
// OUT-NEXT: m_expr zero some 6 none
// OUT-NEXT: m_expr_null zero some 7 none
// OUT-NEXT: m_bool 1 0 -1
// OUT-NEXT: m_enum 2 3 -1
// OUT-NEXT: m_field 40 -1
// OUT-NEXT: m_after 33 9
