import lib

pub fn mid() -> i32 {
    var p = lib::Point{x: 1, y: 2}
    return lib::sum(p) + lib::scale(p, 2)
}
