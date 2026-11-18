// `=>` followed by braces is an arm written both ways at once. A single
// expression in the braces keeps the `=>` and loses the braces; statements
// keep the braces and lose the `=>`. Neither leaves a second error behind:
// no set-literal error, no mixed-forms error on the match, no missing-else
// error on the `if`.
fn x() {}
fn y() {}

fn stmts(v: i32) {
    var n = 0
    match v {
        case 10 => { x(); y(); }
        default {}
    }
    if v == 1 => { x(); }
    if v == 2 => {
        x()
        y()
    }
    match v {
        case 3 => { n += 1 }
        default {}
    }
}

fn values(v: i32) -> i32 {
    var a = match v {
        case 1 => { 2 }
        default => 3
    }
    var b = if v == 1 => { 4 } else => { 5 }
    return a + b
}

fn risky() panic(i32) -> i32 { panic 1 }

// Real literals stay literals.
fn literals(v: i32) {
    var s = match v {
        case 1 => { 1, 2 }
        default => { 3, 4 }
    }
    var m = if v == 1 => { 1: 2 } else => { 3: 4 }
    var p = if v == 1 => { 1, } else => { 2, }
}

fn caught() -> i32 {
    return try risky() catch => { 0 }
}

// --- lit wiring ---
// RUN: { %kairo --type-check-only %s 2>&1 || true; } | %FileCheck %s --implicit-check-not=error
// CHECK:      :12:20: error [S073E]: a statement arm takes no '=>': write the block alone
// CHECK-NEXT: fix-it:"{{.*}}":{12:17-12:20}:""
// CHECK-NEXT: note [I900N]: 'if', 'match' and 'try' have a value form, 'case 1 => e', and a statement form, 'case 2 { x(); y(); }', which yields no value
// CHECK:      :15:18: error [S073E]: a statement arm takes no '=>'
// CHECK-NEXT: fix-it:"{{.*}}":{15:15-15:18}:""
// CHECK:      :16:18: error [S073E]: a statement arm takes no '=>'
// CHECK-NEXT: fix-it:"{{.*}}":{16:15-16:18}:""
// CHECK:      :21:19: error [S073E]: a statement arm takes no '=>'
// CHECK-NEXT: fix-it:"{{.*}}":{21:16-21:19}:""
// CHECK:      :28:19: error [S073E]: a value arm takes no braces: write the value after '=>'
// CHECK-NEXT: fix-it:"{{.*}}":{28:19-28:21}:""
// CHECK-NEXT: fix-it:"{{.*}}":{28:22-28:24}:""
// CHECK-NEXT: note [I900N]: 'if', 'match' and 'try' have a value form
// CHECK-NEXT: note [I900N]: a one-element set literal as an arm's value takes a trailing comma: '=> { e, }'
// CHECK:      :31:26: error [S073E]: a value arm takes no braces
// CHECK:      :31:40: error [S073E]: a value arm takes no braces
// CHECK:      :48:33: error [S073E]: a value arm takes no braces
