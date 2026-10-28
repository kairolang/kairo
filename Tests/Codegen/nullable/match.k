// G14 (Compiler/Sema/NULLABLE.md 3.6): a `match` on `T?` runs. CoalesceLowering
// answers `case null` first (`if !x? { arm 0 } else { match <x's value> }`)
// and the rest matches the unwrapped `T` with PatternCompilation's tree.
// Covered: integer values and ranges, `case var v` binding the `T`, a
// guard on the value and one refining another nullable, `default` reading
// the narrowed scrutinee, a record scrutinee destructured, an ADT
// payload, `bool?` exhaustive with no `default`, a call scrutinee
// evaluated once, the expression form, a value-form match whose value is
// discarded, and the state after a match whose null arm returns.

import std::io::println

struct Pt { var x: i32; var y: i32 }
enum Shape { Dot, Line { len: i32 } }

var calls = 0
fn find(k: i32) -> i32? { calls += 1; if k > 0 { return k } return null }

fn classify(x: i32?, o: i32?) -> i32 {
    match x {
        case null { return -1 }
        case 0 { return 0 }
        case 1..=3 { return 2 }
        case var v where v > 100 { return v }
        case var v where o? { return o + v }
        default { return x + 1000 }
    }
}

fn point(p: Pt?) -> i32 {
    match p {
        case null { return -1 }
        case Pt(0, var y) { return y }
        case var q { return q.x * 10 + q.y }
    }
}

fn shape(s: Shape?) -> i32 {
    match s {
        case null { return -1 }
        case .Dot { return 0 }
        case .Line(var len) { return len }
    }
}

fn truth(b: bool?) -> i32 {
    match b {
        case null { return 0 }
        case true { return 1 }
        case false { return 2 }
    }
}

fn twice(x: i32?) -> i32 = match x { case null => 0 case var v => v * 2 }

fn after(x: i32?) -> i32 {
    match x {
        case null { return 0 }
        default { }
    }
    return x * 3
}

fn main() -> i32 {
    println(f"int: {classify(null, null)} {classify(0, null)} {classify(2, null)} {classify(500, null)} {classify(7, 5)} {classify(7, null)}")
    println(f"record: {point(null)} {point(Pt{ x: 0, y: 9 })} {point(Pt{ x: 4, y: 2 })}")
    println(f"adt: {shape(null)} {shape(Shape::Dot)} {shape(Shape::Line{ len: 6 })}")
    println(f"bool: {truth(null)} {truth(true)} {truth(false)}")
    calls = 0
    var hit = 0
    match find(3) {
        case null { hit = -1 }
        case var v { hit = v }
    }
    match find(-1) {
        case null { hit += 100 }
        default { hit += 1000 }
    }
    println(f"call: {hit} calls={calls}")
    println(f"expr: {twice(null)} {twice(21)}")
    var seen = 0
    match find(2) { case null => seen = 1 case var v => seen = v }
    println(f"discarded: {seen}")
    println(f"after: {after(null)} {after(5)}")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=CXX
// CXX:      if(x.is_null()) {
// CXX-NEXT:     return(- 1);
// CXX:      signed int __kairo_m0_s = x.__value();

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe > %t.out
// RUN: %FileCheck %s --check-prefix=OUT --match-full-lines < %t.out
// OUT:      int: -1 0 2 500 12 1007
// OUT-NEXT: record: -1 9 42
// OUT-NEXT: adt: -1 0 6
// OUT-NEXT: bool: 0 1 2
// OUT-NEXT: call: 103 calls=2
// OUT-NEXT: expr: 0 42
// OUT-NEXT: discarded: 2
// OUT-NEXT: after: 0 15
