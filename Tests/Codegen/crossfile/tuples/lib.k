// A tuple record is minted once per build, not per TU: the `(i32, f64)`
// this module returns is the same canonical the importer names, so the
// call types and the two objects agree on `builtin::Tuple2<int, double>`.
pub fn pair() -> (i32, f64) { return (40, 1.5) }
pub fn sum(p: (i32, i32)) -> i32 { return p.0 + p.1 }
