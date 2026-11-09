// A `const` parameter of a generic record's own instance type is a
// reference (Doc: Parameter passing modes), not a by-value copy, so a
// move-only record passes; and it borrows a MOVE argument, which stays live.
// REQUIRES: clang
// RUN: rm -rf %t.d
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe; test $? -eq 9

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

class <T> Qual {
    pub var flags: u16 = 0;
    pub var spans: List<i32>;
    fn Qual(self) { }
    fn Qual(self, f: u16) { self.flags = f; }
    fn op == (const self, const other: Qual<T>) -> bool { return self.flags == other.flags; }
    fn op != (const self, const other: Qual<T>) -> bool { return !(self == other); }
    fn op | (const self, const other: Qual<T>) -> Qual<T> {
        var result = Qual<T>(self.flags | other.flags);
        return result;
    }
}

fn main() -> i32 {
    var a = Qual<i32>(1);
    var b = Qual<i32>(4);
    var c = a | b;
    if !(a != b) { return 1; }
    // `b` was borrowed by `|` and `!=`, so it is still live.
    return (c.flags as i32) + (b.flags as i32);
}
