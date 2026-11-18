// Imports library c, so `c::` names it here -- for the call to g and for
// the macro alike.
import c

pub fn f() -> bool {
    var q: bool = c::m!()
    var r: bool = c::g()
    return q && r
}
