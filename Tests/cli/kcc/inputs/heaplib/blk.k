// A block from Kairo's heap, as an address C++ can print.
pub fn make() -> usize {
    var *p = @create i32(5)
    return p as usize
}
