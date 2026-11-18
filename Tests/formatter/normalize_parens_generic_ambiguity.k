// RUN: %kfmt --normalize-parens --stdout %s | diff -u %S/expected/normalize_parens_generic_ambiguity.k -
// RUN: %kfmt --normalize-parens --check %S/expected/normalize_parens_generic_ambiguity.k
//
// Under --normalize-parens a pair is kept when removing it would let a `<`
// ... `>` across the expression parse as a generic call: in
// `(xs[k].imp < 0) || f > (g)` the first pair is what keeps `<` a comparison.
// A pair that does not matter still goes.

fn f(xs: [Item], k: usize, g: i32, f: i32) -> bool {
    var r = (xs[k].imp < 0) || f > (g);
    var t = (g * 2) + 1;
    return r;
}
