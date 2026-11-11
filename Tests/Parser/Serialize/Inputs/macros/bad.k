// Corpus for Parser/Serialize/macros.k: a syntax error in a nested
// expansion. The parser reports it with the macro backtrace, and leaves
// recovery nodes built from expanded tokens in the tree.
macro inner!() { var x: = ; }
macro outer!() { inner!() }

fn h() -> i32 { outer!() return 0 }
