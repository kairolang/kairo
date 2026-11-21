// The definitions of Pp::Words. `measure` and `twice` only read their
// Box; `grow` mutates its own copy. Each counts its calls, so none is a
// const function (which keeps every parameter by value anyway).

import Pp::Boxes::Box

static calls: i32 = 0

pub fn measure(b: Box) -> i32 { calls += 1; return b.n }

pub fn twice(b: Box) -> i32 { calls += 1; return measure(b) * 2 }

pub fn grow(b: Box) -> i32 {
    calls += 1
    b.n += 1
    return b.n
}
