// A library that stops before typing: `missing` names nothing, a hard stop
// in name resolution. Its `panic` function's set is never solved, so a
// call to it from main.k says nothing about panics -- no unhandled error
// cascades from the one real error here.

pub fn shaky() panic -> i32 {
    return missing
}
