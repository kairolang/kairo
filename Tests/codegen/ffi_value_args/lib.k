// Imported by cross_module.k; not a test of its own (lit.local.cfg).
ffi "c++" import "array"

pub eval WIDTH: usize = 3

pub fn total(a: cxx::std::array<i32, WIDTH>) -> i32 {
    var s = 0
    for x in a { s += x }
    return s
}

pub fn make(v: i32) -> cxx::std::array<i32, 3> {
    var a: cxx::std::array<i32, 3>
    a.fill(v)
    return a
}
