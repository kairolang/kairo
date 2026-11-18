// An interface requirement that returns a nullable of an associated type
// (`Self::Item?`) is usable through a generic bound for conformers whose
// `Item` is different types: each instance's nullable is defined before the
// witness that names it.

interface Iter {
    type Item
    fn next(self) -> Self::Item?
}
class Counter impl Iter {
    type Item = i32
    var n: i32 = 0
    fn next(self) -> i32? {
        if self.n >= 4 { return null }
        self.n = self.n + 1
        return self.n
    }
}
class Wide impl Iter {
    type Item = u64
    var n: u64 = 0
    fn next(self) -> u64? {
        if self.n >= 2 { return null }
        self.n = self.n + 1
        return self.n * 10000000000u64
    }
}
fn <T impl Iter> count(it: *T) -> i32 {
    var k = 0
    while true {
        var v = it->next()
        if v == null { break }
        k = k + 1
    }
    return k
}
fn main() -> i32 {
    var c = Counter()
    var w = Wide()
    var d = Counter()
    var first = d.next()
    return count(&c) * 10 + count(&w) + (first ?? 0) * 100   // 40 + 2 + 100
}

// --- lit wiring -----------------------------------------------------------
// REQUIRES: clang
// RUN: rm -rf %t.d %t.e
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 142
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.e
// RUN: %t.o2.exe; test $? -eq 142
