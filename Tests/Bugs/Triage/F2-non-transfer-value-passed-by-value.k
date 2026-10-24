// build: kairo F2-non-transfer-value-passed-by-value.k   (expect a Sema error at take(p), not clang's CL001E)
class Pinned {
    pub var n: i32 = 0
    fn Pinned(self) { }
    @copy
    fn Pinned(self, const other: Self) = delete
    @move
    fn Pinned(self, other: Self) = delete
}

fn take(p: Pinned) -> i32 { return p.n }

fn main() -> i32 {
    var p = Pinned()
    return take(p)          // NON_TRANSFER passed by value: Sema accepts it
}
