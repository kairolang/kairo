// A class with no transfer constructor is MOVE when a field is
// (Doc: Classes Lifecycle). Its `op finally` used to cost it C++'s implicit
// move constructor and move assignment, so assigning or returning one fell
// back to the deleted copy.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 2

class Alloc {
    var head: unsafe *i32 = &null;
    fn Alloc(self) { }
    @move fn Alloc(self, other: Self) {
        self.head = other.head;
        other.head = &null;
    }
    fn op finally (self) { self.head = &null; }
}

class <T> List {
    priv var owned: Alloc;
    priv var n: usize = 0;
    fn List(self) { }
    fn op finally (self) { self.n = 0; }
    fn push(self, x: T) { self.n += 1; }
    fn size(const self) -> usize { return self.n; }
}

class Holder { var decls: List<i32>; }

fn rebuild(h: unsafe *Holder) {
    var buf = List<i32>();
    buf.push(1);
    buf.push(2);
    h->decls = buf;
}

fn make() -> List<i32> {
    var l = List<i32>();
    l.push(1);
    return l;
}

fn main() -> i32 {
    var h = Holder();
    rebuild(unsafe &h);
    var m = make();
    return (h.decls.size() as i32) + (m.size() as i32) - 1;
}
