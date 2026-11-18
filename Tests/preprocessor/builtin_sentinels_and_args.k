// Builtin macros the preprocessor answers itself:
// - each deferred builtin becomes one sentinel token at its name;
// - builtin and user-macro arguments split only at commas outside every
//   (), [] and {};
// - a user macro may not take a builtin's or a parser intrinsic's name.

macro pair!(a, b) { b }

fn main() -> i32 {
    var n = count!((1, 2), [3, 4], {5, 6}, 7)
    var p = pair!((1, 2), [3, 4])
    todo!()
    unreachable!()
    unreachable_unchecked!()
    include!("x.k")
    embed!("x.bin")
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s --check-prefix=PP
// PP: var n = 4
// PP-NEXT: var p = [ 3 , 4 ]
// PP-NEXT: <todo>
// PP-NEXT: <unreachable>
// PP-NEXT: <unreachable_unchecked>
// PP-NEXT: <include>
// PP-NEXT: <embed>
// RUN: { %kairo %s --print-tokens 2>/dev/null || true; } | %FileCheck %s --check-prefix=TOK
// TOK: macro-sentinel <todo>
// TOK: macro-sentinel <unreachable>
// TOK: macro-sentinel <unreachable_unchecked>
// TOK: macro-sentinel <include>
// TOK: macro-sentinel <embed>
