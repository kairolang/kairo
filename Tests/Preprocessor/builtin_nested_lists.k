// A list builtin's result, nested inside another list builtin, is re-split
// at its top-level commas: the inner result's commas and brackets count as
// the outer builtin's own. A user macro still splits its raw arguments
// before expanding them, so an expanded comma never changes its arity.

macro pair!(a, b) { b }
macro two!() { 1, 2 }
macro fwd!(x) { count!(x) }

var a1 = count!(rest!(1, 2, 3))
var a2 = count!(butlast!(1, 2, 3))
var a3 = count!(rest!(1), 9)
var a4 = count!(rest!(f(1, 2), [3, 4], {5, 6}, 7))
var a5 = count!(rest!(rest!(1, 2, 3, 4)))
var a6 = count!(two!())
var a7 = count!(first!(1, 2), last!(3, 4))
var b1 = first!(rest!(1, 2, 3))
var b2 = first!(butlast!(1, 2, 3))
var b3 = last!(rest!(1, 2, 3))
var b4 = last!(butlast!(1, 2, 3))
var b5 = first!(rest!(f(1, 2), g(3, 4)))
var c1 = [rest!(rest!(1, 2, 3, 4))]
var c2 = [butlast!(rest!(1, 2, 3, 4))]
var c3 = [rest!(butlast!(1, 2, 3, 4))]
var c4 = [butlast!(butlast!(1, 2, 3, 4))]
var d1 = paste!(get_, first!(rest!(alpha, beta, gamma)))
var d2 = pair!(rest!(1, 2, 3), 9)
var d3 = fwd!(rest!(1, 2, 3))
var d4 = stringify!(rest!(1, 2))

// --- lit wiring -----------------------------------------------------------
// RUN: %kairo %s --dump-preprocessed | %FileCheck %s --check-prefix=PP
// PP: var a1 = 2
// PP-NEXT: var a2 = 2
// PP-NEXT: var a3 = 2
// PP-NEXT: var a4 = 3
// PP-NEXT: var a5 = 2
// PP-NEXT: var a6 = 2
// PP-NEXT: var a7 = 2
// PP-NEXT: var b1 = 2
// PP-NEXT: var b2 = 1
// PP-NEXT: var b3 = 3
// PP-NEXT: var b4 = 2
// PP-NEXT: var b5 = g ( 3 , 4 )
// PP-NEXT: var c1 = [ 3 , 4 ]
// PP-NEXT: var c2 = [ 2 , 3 ]
// PP-NEXT: var c3 = [ 2 , 3 ]
// PP-NEXT: var c4 = [ 1 , 2 ]
// PP-NEXT: var d1 = get_beta
// PP-NEXT: var d2 = 9
// PP-NEXT: var d3 = 2
// PP-NEXT: var d4 = "rest!(1, 2)"
// RUN: { %kairo %s --type-check-only 2>&1 || true; } | %FileCheck %s --check-prefix=DIAG
// A name that a nested result carries is reported at the nested
// invocation that produced it: `g` at `rest!(` (column 17).
// DIAG: builtin_nested_lists.k:21:17: error [R020E]: use of undeclared identifier 'g'
// DIAG: builtin_nested_lists.k:26:10: error [R020E]: use of undeclared identifier 'get_beta'
