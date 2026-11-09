// `match` arms whose pattern is an enum or bool `eval` constant (the
// arm was silently dropped -- the column switched on the variant, and a
// constant is no variant).

enum Color { R, G, B }
eval FAV: Color = Color::G;

/// A plain enum compares with the builtin `==`.
fn color(c: Color) -> i32 {
    match c {
        case FAV { return 7; }
        case .R  { return 1; }
        default  { return 0; }
    }
}

/// An enum with its own `op ==` is tested through it: Blank and Dot are
/// the same cell to it.
enum Cell { Blank, Dot, Full }
extend Cell {
    fn op ==(const self, const other: Cell) -> bool {
        var a = self as u32;
        var b = other as u32;
        if a == 2 || b == 2 { return a == b; }
        return true;
    }
}
eval EMPTY: Cell = Cell::Blank;

fn cell(c: Cell) -> i32 {
    match c {
        case EMPTY { return 3; }
        default    { return 4; }
    }
}

/// A payload enum with its own `op ==`.
enum Shape { Circle { r: i32 }, Square { s: i32 } }
fn key(s: Shape) -> i32 = match s {
    case .Circle(var r) => r
    case .Square(var s) => 100 + s
}
extend Shape {
    fn op ==(const self, const other: Shape) -> bool { return key(self) == key(other); }
}
const UNIT: Shape = Shape::Circle { r: 1 };

fn shape(s: Shape) -> i32 {
    match s {
        case .Square(var s) { return 20 + s; }
        case UNIT           { return 11; }
        case .Circle(_)     { return 12; }
    }
}

eval YES: bool = true;

fn flag(b: bool) -> i32 {
    match b {
        case YES { return 5; }
        default  { return 6; }
    }
}

fn main() -> i32 {
    if color(Color::G) != 7 { return 1; }
    if color(Color::R) != 1 { return 2; }
    if color(Color::B) != 0 { return 3; }
    if cell(Cell::Blank) != 3 { return 4; }
    if cell(Cell::Dot)   != 3 { return 5; }
    if cell(Cell::Full)  != 4 { return 6; }
    if shape(Shape::Circle { r: 1 }) != 11 { return 7; }
    if shape(Shape::Circle { r: 2 }) != 12 { return 8; }
    if shape(Shape::Square { s: 3 }) != 23 { return 9; }
    if flag(true)  != 5 { return 10; }
    if flag(false) != 6 { return 11; }
    return 42;
}

// --- lit wiring -----------------------------------------------------------
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG --allow-empty
// DIAG-NOT: {{error|warning}}

// RUN: { %kairo %s --print-ir 2>&1 || true; } | %FileCheck %s --check-prefix=IR
// IR: if(__kairo_m0_s == ::match_const_pattern_enum::FAV) {
// IR: if( ::match_const_pattern_enum::__kairo_ext_Cell::__kairo_op_eq(__kairo_m0_s, ::match_const_pattern_enum::EMPTY)) {
// IR: if( ::match_const_pattern_enum::__kairo_ext_Shape::__kairo_op_eq(__kairo_m0_s, ::match_const_pattern_enum::UNIT)) {
// IR: if(__kairo_m0_s == ::match_const_pattern_enum::YES) {

// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 42
