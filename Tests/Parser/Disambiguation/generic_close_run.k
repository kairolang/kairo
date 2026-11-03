// P295: seven or more closing `>` written together failed to parse (S049E
// "expected ',' or '>' after type argument"); six worked, and spaced ones
// worked at any depth. Not the type parser's `>>` split: the lexer took any
// run of seven `<`, `=` or `>` for a git conflict marker and dropped the
// rest of the line. Markers are now recognized only at the start of a line,
// the one place git writes them. Odd and even runs, and one of fifteen.
//
// RUN: { %kairo %s --syntax-only 2>&1 || true; } | %FileCheck %s --allow-empty --implicit-check-not=error

fn main() {
    var a: A<A<A<A<A<A<i32>>>>>> = 0
    var b: A<A<A<A<A<A<A<i32>>>>>>> = 0
    var c: A<A<A<A<A<A<A<A<i32>>>>>>>> = 0
    var d: A<A<A<A<A<A<A<A<A<i32>>>>>>>>> = 0
    var e: A<A<A<A<A<A<A<A<A<A<A<A<A<A<A<i32>>>>>>>>>>>>>>> = 0
    var f: A<A<A<A<A<A<A<i32>>>>>>> = b
}
