// cells.k: the Kairo side of null_main.cpp. Each function takes or returns a
// `T?`, which a C++ host spells ::builtin::Null<T>.

pub class Cell {
    pub var v: i32
    pub fn Cell(self, v: i32) { self.v = v }
    @copy fn Cell(self, const other: Self) { self.v = other.v }
}

pub fn some(v: i32) -> i32? { return v }
pub fn none() -> i32? { return null }
pub fn or_zero(x: i32?) -> i32 { return x ?? 0 }
pub fn cell(v: i32) -> Cell? {
    if v < 0 { return null }
    return Cell(v)
}
