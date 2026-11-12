// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9
// An assignment through a place SequenceLowering binds first (`**pp`,
// `v[i()]`) became `({ auto&& p = (place); (p = value); })`, and a
// statement expression copy-initializes its value from its last expression
// even when nothing reads it: for a move-only record that is a copy it does
// not have (CL001E). As a statement the store ends the block inside a
// block of its own, so the statement expression has no value to copy.

class Tok {
    pub var id: i32 = 0
    fn Tok(self, x: i32) { self.id = x }
    @move fn Tok(self, other: Self) { self.id = other.id; other.id = 0 }
}

var calls: i32 = 0

fn idx() -> usize {
    calls += 1
    return 0
}

fn main() -> i32 {
    var t = Tok(1)
    var p = &t
    var pp = &p
    **pp = Tok(4)

    var v: [Tok]
    v.push(Tok(0))
    v[idx()] = Tok(4)
    return t.id + v[0].id + calls
}
