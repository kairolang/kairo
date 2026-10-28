import numlib::*

// The narrowing twins of ok.k: each is E, so each needs `as` (lattice s3,
// s3.1) whatever module, generic or nesting the value comes through.
fn main() -> i32 {
    var a: i32 = take_i64(1);
    var b = take_i64(give_f64());
    var c: i64 = pass(give_f64());
    var d = take_i64(pass(give_u64()));
    var e = Cell<i32>(give_f64());
    var f = Cell<i64>(1);
    f.put(give_f64());
    return 0;
}

// Corpus for Sema/Conversions/module_generic.k (keep this comment last).
