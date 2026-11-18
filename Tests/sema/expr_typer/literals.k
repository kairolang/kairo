// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// RUN: { %kairo %s --type-check-only --print-sema 2>/dev/null || true; } | %FileCheck %s --check-prefix=SEMA
//
// Literal typing (ExprTyper / LiteralTyping). Two rules carry the file:
//
//   1. An unsuffixed literal has NO type of its own -- it takes the type it
//      is used at. Only with nothing to take does the default apply: i32 for
//      an integer, f64 for a float.
//   2. A suffix is a declaration, not a hint. `1u8` is a u8 wherever it
//      stands, and a value that does not fit the type it is used at is an
//      error rather than a silent wrap.
//
// String literals are deliberately absent: `string` is a lang item, and a
// test that does not import the prelude would be asserting on the import
// set rather than on the typer.

fn take_u8(x: u8) -> u8 { return x }

fn defaults() {
    var a = 1;         // no context: i32
    var b = 1.5;       // no context: f64
    var c = true;
    var d = 'c';
}

fn suffixes() {
    var a = 1u8;
    var b = 1i64;
    var c = 1.5f32;
}

fn context_wins() {
    var a: u8  = 7;    // the annotation, not i32
    var b: f32 = 1.5;
    var c: i8  = -128; // the negation is part of the literal: i8's floor fits
    var d      = take_u8(10);
}

fn does_not_fit() {
    var a: u8 = 300;
    var b: i8 = 128;
}

// DIAG: error{{.*}}literal '300' does not fit in 'u8'
// DIAG: error{{.*}}literal '128' does not fit in 'i8'
// DIAG-NOT: error{{.*}}does not fit in 'i8': -128

// SEMA: -- inferred decls --
// SEMA:   a : i32
// SEMA-NEXT: b : f64
// SEMA-NEXT: c : bool
// SEMA-NEXT: d : char
// SEMA-NEXT: a : u8
// SEMA-NEXT: b : i64
// SEMA-NEXT: c : f32
// SEMA-NEXT: d : u8
