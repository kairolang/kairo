// Run: the values computed through narrowed nullables. Each `check` compares
// the result of one case with the value the source says (nullables.mdx,
// Narrowing); a failure prints the case name and the program exits with the
// number of failed cases. Covered: every spelling of the null test, early
// exits, `&&` / `||` / `!` short-circuit, `while` conditions and loop bodies
// that assign the variable, value-form `if`, `match` arms, a field path,
// a nullable pointer and a generic `T?`.
// Cases from Kotlin compiler/testData/diagnostics/tests/smartCasts/
// (varnotnull/, loops/, controlStructures/, elvis/) and
// nullabilityAndSmartCasts/.

import std::io::println

var failures = 0
var hits = 0

fn check(const name: string, got: i32, want: i32) {
    if got != want {
        println(f"FAIL {name}: got {got} want {want}")
        failures += 1
    }
}

fn b2i(b: bool) -> i32 { if b { return 1 } return 0 }
fn find(k: i32) -> i32? { if k > 0 { return k } return null }
fn next(x: i32) -> i32? { if x > 1 { return x - 1 } return null }
fn probe(k: i32) -> i32? { hits += 1; return find(k) }
fn side(k: i32) -> bool { hits += 1; return k > 0 }

class Node { pub var v: i32 = 5; pub var link: (*Node)? = null; pub fn Node(self) { } }
class Cell { pub var n: i32? = null; pub var next: Node? = null; pub fn Cell(self) { } }

fn then_branch(a: i32?) -> i32 { if a != null { return a + 1 } return -1 }
fn question_form(a: i32?) -> i32 { if a? { return a * 2 } return -1 }
fn null_left(a: i32?) -> i32 { if null != a { return a - 1 } return -1 }
fn eq_null_else(a: i32?) -> i32 { if a == null { return -1 } else { return a + 1 } }
fn null_eq_else(a: i32?) -> i32 { if null == a { return -1 } else { return a + 1 } }
fn not_question_else(a: i32?) -> i32 { if !a? { return -1 } else { return a + 1 } }
fn not_group(a: i32?) -> i32 { if !(a == null) { return a + 1 } return -1 }
fn double_not(a: i32?) -> i32 { if !!a? { return a + 1 } return -1 }
fn early_exit(a: i32?) -> i32 { if a == null { return -1 } return a + 100 }
fn early_exit_not(a: i32?) -> i32 { if !a? { return -1 } return a + 100 }
fn early_exit_else(a: i32?) -> i32 { if a? { } else { return -1 } return a + 100 }

fn and_both(a: i32?, b: i32?) -> i32 { if a? && b? { return a + b } return -1 }
fn and_rhs_uses_lhs(a: i32?) -> bool { return a? && a > 2 }
fn or_rhs_uses_negation(a: i32?) -> bool { return !a? || a > 2 }
fn or_early(a: i32?, b: i32?) -> i32 { if !a? || !b? { return -1 } return a * b }
fn not_and_early(a: i32?, b: i32?) -> i32 { if !(a? && b?) { return -1 } return a * b }
fn chain3(a: i32?, b: i32?, c: i32?) -> i32 { if a? && b? && c? { return a + b + c } return -1 }

fn value_if(a: i32?) -> i32 { return if a? => a else => 77 }
fn value_if_null(a: i32?) -> i32 { return if a == null => 77 else => a }

fn match_arms(x: i32?) -> i32 {
    match x {
        case null { return -1 }
        case 0 { return 1000 }
        case var v where v > 10 { return v + 1 }
        default { return x * 2 }
    }
}

fn match_after(x: i32?) -> i32 {
    match x {
        case null { return -1 }
        default { }
    }
    return x + 5
}

fn while_walk(a: i32?) -> i32 {
    var r = 0
    var x? = a
    while x? {
        r += x
        x = next(x)
    }
    return r
}

fn while_until_value() -> i32 {
    var k = 0
    var x: i32? = null
    while x == null {
        k += 1
        x = find(k - 2)
    }
    return x * 10 + k
}

fn loop_break_on_value() -> i32 {
    var x: i32? = null
    var k = 0
    loop {
        k += 1
        x = find(k - 3)
        if x? { break }
    }
    return x + k * 100
}

fn for_sum_skips_null() -> i32 {
    var r = 0
    for k in 0..6 {
        var e? = find(k - 2)
        if !e? { continue }
        r += e
    }
    return r
}

fn assigned_in_body() -> i32 {
    var x? = 1
    var r = 0
    for k in 0..4 {
        r += x
        x = null
        x = k + 10
    }
    return r + x
}

fn field_path(c: Cell) -> i32 {
    if c.n? { return c.n + 1 }
    return -1
}

fn field_path_early(c: Cell) -> i32 {
    if c.next == null { return -1 }
    return c.next.v
}

fn pointer_chain(p: (*Node)?) -> i32 {
    var r = 0
    var *q? = p
    while q? {
        r += q->v
        q = q->link
    }
    return r
}

fn <T> generic_pick(t: T?, d: T) -> T {
    if t? { return t }
    return d
}

fn coalesce_chain(a: i32?, b: i32?) -> i32 { return a ?? b ?? 9 }

fn main() -> i32 {
    check("then_branch present", then_branch(4), 5)
    check("then_branch null", then_branch(null), -1)
    check("question_form present", question_form(4), 8)
    check("question_form null", question_form(null), -1)
    check("null_left present", null_left(4), 3)
    check("null_left null", null_left(null), -1)
    check("eq_null_else present", eq_null_else(4), 5)
    check("eq_null_else null", eq_null_else(null), -1)
    check("null_eq_else present", null_eq_else(4), 5)
    check("null_eq_else null", null_eq_else(null), -1)
    check("not_question_else present", not_question_else(4), 5)
    check("not_question_else null", not_question_else(null), -1)
    check("not_group present", not_group(4), 5)
    check("not_group null", not_group(null), -1)
    check("double_not present", double_not(4), 5)
    check("double_not null", double_not(null), -1)
    check("early_exit present", early_exit(4), 104)
    check("early_exit null", early_exit(null), -1)
    check("early_exit_not present", early_exit_not(4), 104)
    check("early_exit_not null", early_exit_not(null), -1)
    check("early_exit_else present", early_exit_else(4), 104)
    check("early_exit_else null", early_exit_else(null), -1)
    check("zero is a value", then_branch(0), 1)

    check("and_both both", and_both(2, 3), 5)
    check("and_both first null", and_both(null, 3), -1)
    check("and_both second null", and_both(2, null), -1)
    check("and_rhs true", b2i(and_rhs_uses_lhs(3)), 1)
    check("and_rhs false", b2i(and_rhs_uses_lhs(1)), 0)
    check("and_rhs null", b2i(and_rhs_uses_lhs(null)), 0)
    check("or_rhs null", b2i(or_rhs_uses_negation(null)), 1)
    check("or_rhs big", b2i(or_rhs_uses_negation(3)), 1)
    check("or_rhs small", b2i(or_rhs_uses_negation(1)), 0)
    check("or_early both", or_early(2, 5), 10)
    check("or_early null", or_early(2, null), -1)
    check("not_and_early both", not_and_early(3, 5), 15)
    check("not_and_early null", not_and_early(null, 5), -1)
    check("chain3 all", chain3(1, 2, 3), 6)
    check("chain3 last null", chain3(1, 2, null), -1)

    check("value_if present", value_if(5), 5)
    check("value_if null", value_if(null), 77)
    check("value_if_null present", value_if_null(5), 5)
    check("value_if_null null", value_if_null(null), 77)

    check("match null", match_arms(null), -1)
    check("match zero", match_arms(0), 1000)
    check("match guard", match_arms(20), 21)
    check("match default", match_arms(4), 8)
    check("match_after null", match_after(null), -1)
    check("match_after value", match_after(4), 9)

    check("while_walk 4", while_walk(4), 10)
    check("while_walk null", while_walk(null), 0)
    check("while_until_value", while_until_value(), 13)
    check("loop_break_on_value", loop_break_on_value(), 401)
    check("for_sum_skips_null", for_sum_skips_null(), 6)
    check("assigned_in_body", assigned_in_body(), 1 + 10 + 11 + 12 + 13)

    var c = Cell()
    check("field_path null", field_path(c), -1)
    c.n = 6
    check("field_path set", field_path(c), 7)
    check("field_path_early null", field_path_early(c), -1)
    c.next = Node()
    check("field_path_early set", field_path_early(c), 5)

    var n1 = Node()
    var n2 = Node()
    n2.v = 7
    n1.link = &n2
    check("pointer_chain", pointer_chain(&n1), 12)
    check("pointer_chain null", pointer_chain(null), 0)

    check("generic present", generic_pick(find(3), 8), 3)
    check("generic null", generic_pick(find(0), 8), 8)
    check("coalesce first", coalesce_chain(1, 2), 1)
    check("coalesce second", coalesce_chain(null, 2), 2)
    check("coalesce fallback", coalesce_chain(null, null), 9)

    hits = 0
    var z = and_rhs_uses_lhs(null)
    check("and short-circuit", b2i(side(0) && side(1)), 0)
    check("and short-circuit hits", hits, 1)
    hits = 0
    var t = side(1) || side(2)
    check("or short-circuit hits", hits, 1)
    hits = 0
    var once? = probe(5)
    check("probe once", hits, 1)

    if failures != 0 { println(f"{failures} failed") }
    return failures
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not='error [' --implicit-check-not='warning ['

// REQUIRES: clang
// RUN: rm -rf %t.d %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
