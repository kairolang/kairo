// A `match` arm whose pattern is a record `eval` constant tests the value
// with the record's own `op ==` (the arm was silently dropped and the
// match compiled to its default).

struct P {
    var x: i32
    var y: i32
    fn op ==(const self, other: Self) -> bool { return self.x == other.x; }   // y deliberately ignored
}

eval ONE:   P = P { x: 1, y: 0 };
eval TWO:   P = P { x: 2, y: 0 };
eval THREE: P = P { x: 3, y: 0 };

fn single(p: P) -> i32 {
    match p {
        case ONE { return 12; }
        default  { return 0; }
    }
}

/// Constants, an alternation of them, and struct patterns, in one column:
/// rows keep their order whichever test form each takes.
fn mixed(p: P) -> i32 {
    match p {
        case P(9, 9)               { return 1; }
        case ONE                   { return 2; }
        case TWO, THREE            { return 3; }
        case P(9, var y)           { return 4 + y - y; }
        case var q where q.y == 7  { return 5; }
        default                    { return 6; }
    }
}

/// A constant in a field of a tuple column.
fn pair(t: (P, i32)) -> i32 {
    match t {
        case (ONE, 0)                 { return 1; }
        case (TWO, var n), (THREE, var n) { return 10 + n; }
        default                       { return 0; }
    }
}

fn main() -> i32 {
    if single(P { x: 1, y: 5 }) != 12 { return 1; }        // op == ignores y
    if single(P { x: 2, y: 0 }) != 0  { return 2; }
    if mixed(P { x: 9, y: 9 }) != 1 { return 3; }
    if mixed(P { x: 1, y: 9 }) != 2 { return 4; }
    if mixed(P { x: 2, y: 0 }) != 3 { return 5; }
    if mixed(P { x: 3, y: 0 }) != 3 { return 6; }
    if mixed(P { x: 9, y: 1 }) != 4 { return 7; }
    if mixed(P { x: 4, y: 7 }) != 5 { return 8; }
    if mixed(P { x: 4, y: 0 }) != 6 { return 9; }
    if pair((P { x: 1, y: 0 }, 0)) != 1  { return 10; }
    if pair((P { x: 1, y: 0 }, 1)) != 0  { return 11; }
    if pair((P { x: 2, y: 0 }, 4)) != 14 { return 12; }
    if pair((P { x: 3, y: 0 }, 5)) != 15 { return 13; }
    if pair((P { x: 4, y: 0 }, 5)) != 0  { return 14; }
    return single(P { x: 1, y: 0 });
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: if(__kairo_m0_s.operator ==( ::match_const_pattern_record::ONE)) {
// IR: if(__kairo_m0_s.operator ==( ::match_const_pattern_record::TWO)) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 12
