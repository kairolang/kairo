// A copy of a vector, and a resize that fills, construct each new element
// once from its source. The element here is a COPY type with a constructor
// that counts: it has no move, so a copy that went through a temporary
// would count twice.

static made: i64 = 0
static copied: i64 = 0
static dropped: i64 = 0

class Cp {
    var v: i32
    fn Cp(self) { self.v = 0; made += 1 }
    fn Cp(self, v: i32) { self.v = v; made += 1 }
    @copy fn Cp(self, const other: Self) { self.v = other.v; copied += 1 }
    fn op finally(self) { dropped += 1 }
}

fn main() -> i32 {
    {
        var a: [Cp]
        a.reserve(8)
        var i: i32 = 0
        while i < 8 { a.push(Cp(i)); i += 1 }

        var before = copied
        var b = a.copy()
        if copied - before != 8 { return 1 }
        b[0].v = 100
        if (a[0].v != 0) || (b[7].v != 7) { return 2 }

        // Room for the fill is reserved first, so the count is the fill's.
        var c: [Cp]
        c.reserve(4)
        var x = Cp(7)
        before = copied
        c.resize(4, x)
        if copied - before != 4 { return 3 }
        if (c[0].v != 7) || (c[3].v != 7) { return 4 }

        // An element with copy() and no copy constructor still copies.
        var s: [string]
        s.push("ab".to_owned())
        s.push("cd".to_owned())
        var t = s.copy()
        if (t.size() != 2) || (t[1] != "cd") || (s[1] != "cd") { return 5 }
    }

    // every Cp that came into being was destroyed once
    if made + copied != dropped { return 6 }
    return 0
}

// --- lit wiring -----------------------------------------------------------
// RUN: rm -rf %t.d
// RUN: rm -f %t.exe %t.o2.exe
// RUN: %kairo %s -o %t.exe --cache-dir %t.d
// RUN: %t.exe
// RUN: %kairo %s -O2 -o %t.o2.exe --cache-dir %t.d
// RUN: %t.o2.exe
