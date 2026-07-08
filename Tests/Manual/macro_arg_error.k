// regression: parse error on a substituted ARGUMENT token (not a body token)
// must also report at the invocation site with an expansion note, since
// argument tokens are wrapped with the same invoke_range during substitution.
//
// expected: error primary caret on `mk_fn!(...)` below, tagged
// "(in expansion of macro 'mk_fn!')", with the failing token noted.

macro mk_fn!(name) { fn name() {} }

mk_fn!(+)
