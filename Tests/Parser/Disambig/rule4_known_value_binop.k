// Final rule 4 split for known non-generic names:
//   - fn:  assume generic when the shape fits. `foo<a>(10)` parses as a
//          generic call sema owns the "foo takes no generic arguments"
//          diagnostic, which beats "cannot compare a function".
//          (`foo < limit` with no closing shape still rolls back to a
//          comparison see nongeneric_lt_binop.k.)
//   - var: never assumed generic. `scale<a>(10)` commits to a comparison
//          chain (scale < a) > (10) with no tentative parse. Only a var
//          bound to a generic lambda parses generically (see
//          rule4_local_shadowing.k).

fn foo(i32)

var scale = 3

fn main() -> i32 {
    var a = 1
    var x = foo<a>(10)
    var s = scale<a>(10)
    return 0
}
