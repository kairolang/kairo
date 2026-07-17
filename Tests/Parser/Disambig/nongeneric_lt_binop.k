// Bug 1 regression (the damaging shape): a `<` after a known non-generic
// name with NO closing `>`-continuation must parse as a comparison, never
// as an unclosed generic-arg list. The old num_params-sentinel table
// marked every entry generic and misparsed these.

fn foo(i32)

var scale = 3

fn main() -> i32 {
    var limit = 9
    var x = foo < limit
    var y = scale < 4
    return 0
}
