import imp

/* imp.k contains:
macro mac! {
    109
}
*/

var y = imp::mac!

macro square!(x) {
    x * x
}

macro quad!(x) {
    square!(square!(x))
}

var z = quad!(3)
// -- edge: recursive cycle detection (should emit error, not crash) -------
macro boom!() {
    boom!()
}

var bad = boom!() | boom!();